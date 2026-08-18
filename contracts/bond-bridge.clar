;; Bitcoin Staking Bond bridge
;;
;; The pool's L1 on-ramp and off-ramp. A member who holds bitcoin rather than
;; sBTC joins and leaves through here, and never has to handle sBTC at all.
;;
;; Coming in
;;
;; An sBTC deposit is a bare mint: the bridge's signers credit whichever
;; principal the bitcoin transaction named, and call nothing. A deposit
;; addressed to the pool therefore arrives with no record of who sent it, and
;; nothing on chain ties it to a member.
;;
;; So the member ties it themselves, in advance, in two steps -- and the order
;; of the five is the whole security argument:
;;
;;   1. `commit-btc-deposit`  a hash of the transaction, on Stacks
;;   2. `reveal-btc-deposit`  the transaction itself, on Stacks
;;   3. broadcast             the bitcoin transaction, on L1
;;   4. wait                  for the sBTC signers to sweep it
;;   5. `confirm-btc-deposit` credit the member, on Stacks
;;
;; The commit takes the STX leg -- the one Stacks transaction they were always
;; going to have to send -- and holds the pool's room. The reveal names the
;; txid and claims it. Only then is the bitcoin broadcast, addressed to
;; `bond-treasury`.
;;
;; Why both steps. A txid announced in the clear is exposed twice over: once in
;; the Stacks mempool before the announcement confirms, and again in the bitcoin
;; mempool if the transaction is broadcast early. Either window lets an onlooker
;; claim the txid first and be credited for someone else's bitcoin.
;;
;; The commit closes the first: a digest tells an onlooker nothing, and it is
;; salted so the same transaction cannot be recognised by its hash. The reveal
;; closes the second, by happening *before* the broadcast: the txid reaches
;; Stacks, already claimed, before it can reach anyone watching bitcoin. An
;; attacker cannot open a commitment to a txid they never knew, and a commitment
;; made after the reveal is too late -- the txid is taken, first reveal wins.
;;
;; That leaves one rule for the member to follow, and it is the same one as
;; before, moved one step later: do not broadcast until the reveal has confirmed.
;;
;; A commitment is keyed by member as well as digest, so copying someone's
;; digest out of the mempool cannot deny them their own commit.
;;
;; Going out
;;
;; `claim-principal-to-btc` hands a member's released principal to the sBTC
;; signers to pay out on bitcoin. The request is made by `bond-treasury`, not by
;; this contract: the bridge unlocks sBTC back to the *requester* when it
;; rejects a request, and that has to land somewhere the pool counts as
;; principal. `reclaim-btc-withdrawal` then settles the outcome.
;;
;; Where this contract sits
;;
;;   bond-treasury   holds the sBTC principal
;;   bond-staker     the ledger: members, epochs, shares, the bond position
;;   bond-bridge     this contract; calls the two above, and is called by
;;                   neither
;;
;; Deploy it last. It holds nothing but the STX legs of announcements that have
;; not been confirmed yet.

(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_INVALID_AMOUNT (err u301))
(define-constant ERR_UNKNOWN_DEPOSIT (err u302))
(define-constant ERR_DEPOSIT_ALREADY_ANNOUNCED (err u303))
(define-constant ERR_DEPOSIT_NOT_SWEPT (err u304))
(define-constant ERR_DEPOSIT_MISDIRECTED (err u305))
;; Retired: a deposit short of its announcement is credited for what arrived.
;; The number stays reserved so the rest do not shift under existing clients.
;; (define-constant ERR_DEPOSIT_TOO_SMALL (err u306))
(define-constant ERR_DEPOSIT_SWEPT (err u307))
(define-constant ERR_ANNOUNCEMENT_LIVE (err u308))
(define-constant ERR_UNKNOWN_WITHDRAWAL (err u309))
(define-constant ERR_WITHDRAWAL_PENDING (err u310))
(define-constant ERR_NOTHING_RELEASED (err u311))
(define-constant ERR_UNKNOWN_COMMITMENT (err u312))
(define-constant ERR_COMMITMENT_EXISTS (err u313))
(define-constant ERR_REVEAL_TOO_SOON (err u314))

;; How long an announced deposit holds its allocation before anyone may cancel
;; it and hand the STX leg back. A sweep takes hours; a week of slack means a
;; deposit in flight is never cancelled from under its owner, while a deposit
;; that never comes cannot squat on the pool's room forever.
(define-constant ANNOUNCE_TTL u1000)

;; The same, for a commitment that was never revealed -- and much shorter,
;; because a commitment is not a deposit in flight. Nothing has been broadcast,
;; and nothing can have been: the digest commits to the txid, so the transaction
;; was already built before the commit was sent. In the ordinary flow the reveal
;; follows one block later, so six hours is generous against a stalled wallet
;; while leaving a squatter far less room to hold the pool's allocation for.
;;
;; It costs the squatter either way -- the STX leg is locked for as long as the
;; commitment stands -- but a week of that per commit is a lot of leverage for
;; the price.
(define-constant COMMIT_TTL u36)

;; How long a commitment has to sit before it may be revealed. Without it a
;; member could commit and reveal in one block -- and so could an onlooker who
;; saw that reveal in the mempool, pairing their own commit with it and racing
;; for the same txid.
;;
;; Burn blocks rather than Stacks blocks, and not only for consistency with
;; every other deadline here. The delay is the margin the honest reveal has to
;; get mined: an attacker copying it has to fit a commit *and* a reveal around
;; the same wait, so the reveal they are racing only loses if it stays in the
;; mempool longer than the delay. A burn block is ten minutes of that margin; a
;; Stacks block would be a few seconds, which fee competition can eat.
;;
;; The cost is up to one bitcoin block of latency before broadcasting, against a
;; deposit that then waits on bitcoin confirmations anyway.
(define-constant REVEAL_DELAY u1)

(define-map announcements
  {
    txid: (buff 32),
    vout-index: uint,
  }
  {
    member: principal,
    sats: uint,
    ustx: uint,
    announced-at-height: uint,
  }
)

;; Keyed by member as well as digest: a digest is public from the moment the
;; commit is in the mempool, and keying on it alone would let anyone insert it
;; first and lock the member out of committing at all. They still could not
;; reveal it -- that needs the salt -- but the member would be stuck.
(define-map commitments
  {
    member: principal,
    digest: (buff 32),
  }
  {
    sats: uint,
    ustx: uint,
    committed-at-height: uint,
  }
)

(define-map withdrawals
  uint
  {
    member: principal,
    sats: uint,
  }
)

;;; Read-only

;; The address to bridge to. Never `bond-staker`'s: sBTC arriving there is
;; taken for reward and split among the members.
(define-read-only (get-deposit-address)
  .bond-treasury
)

;; What to commit to. The salt is the member's to choose and to keep until the
;; reveal; 32 random bytes. Computing it here rather than off chain means a
;; client cannot disagree with the contract about what it committed to.
(define-read-only (get-deposit-digest
    (txid (buff 32))
    (vout-index uint)
    (salt (buff 32))
  )
  (sha256 (unwrap-panic (to-consensus-buff? {
    txid: txid,
    vout-index: vout-index,
    salt: salt,
  })))
)

(define-read-only (get-commitment
    (member principal)
    (digest (buff 32))
  )
  (map-get? commitments {
    member: member,
    digest: digest,
  })
)

(define-read-only (get-announcement
    (txid (buff 32))
    (vout-index uint)
  )
  (map-get? announcements {
    txid: txid,
    vout-index: vout-index,
  })
)

(define-read-only (get-withdrawal (request-id uint))
  (map-get? withdrawals request-id)
)

;; What the sBTC registry says about a deposit: `none` until the signers have
;; swept it.
(define-read-only (get-swept-deposit
    (txid (buff 32))
    (vout-index uint)
  )
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry
    get-completed-deposit txid vout-index
  )
)

;; The STX a deposit of `sats` has to be accompanied by, for the bond the pool
;; is bound to.
(define-read-only (get-required-ustx (sats uint))
  (contract-call? .bond-staker get-required-ustx sats)
)

;;; Coming in

;; Step 1. Commit to the bitcoin deposit you are about to make, and pay its STX
;; leg. The digest comes from `get-deposit-digest`; keep the salt until step 2.
;;
;; The sats hold allocation room in the pool from here on. Nothing about which
;; transaction this is has left your wallet yet.
(define-public (commit-btc-deposit
    (digest (buff 32))
    (sats uint)
  )
  (let (
      (member tx-sender)
      ;; Reserves the pool's room and tells us what the STX leg comes to.
      ;; Rejects a member on the way out, a bond that has started, and a
      ;; deposit the pool has no room for.
      (ustx (try! (contract-call? .bond-staker reserve-bridged-deposit member sats)))
    )
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    (asserts!
      (map-insert commitments {
        member: member,
        digest: digest,
      } {
        sats: sats,
        ustx: ustx,
        committed-at-height: burn-block-height,
      })
      ERR_COMMITMENT_EXISTS
    )

    ;; The STX leg is paid now and held here until the sats arrive.
    (try! (stx-transfer? ustx member current-contract))

    (let ((result {
        member: member,
        digest: digest,
        sats: sats,
        ustx: ustx,
        revealable-from: (+ burn-block-height REVEAL_DELAY),
        cancellable-from: (+ burn-block-height COMMIT_TTL),
      }))
      (print (merge { topic: "commit-btc-deposit" } result))
      (ok result)
    )
  )
)

;; Step 2. Name the transaction the commitment was for, and claim its txid.
;;
;; Do this *before* broadcasting. The txid becomes public here, already yours:
;; a watcher who sees it has no commitment to open against it, and one made now
;; is behind this reveal, which took the txid first.
;;
;; Broadcast once this has confirmed -- step 3 -- and the bitcoin mempool has
;; nothing left to give away.
(define-public (reveal-btc-deposit
    (txid (buff 32))
    (vout-index uint)
    (salt (buff 32))
  )
  (let (
      (member tx-sender)
      (digest (get-deposit-digest txid vout-index salt))
      (commitment (unwrap!
        (map-get? commitments {
          member: member,
          digest: digest,
        })
        ERR_UNKNOWN_COMMITMENT
      ))
      (sats (get sats commitment))
      (ustx (get ustx commitment))
    )
    (asserts!
      (>= burn-block-height (+ (get committed-at-height commitment) REVEAL_DELAY))
      ERR_REVEAL_TOO_SOON
    )
    ;; The reveal comes before the broadcast, so a transaction already swept is
    ;; not the one this commitment was made for -- and its sats are in the
    ;; treasury unattributed, which this call must not be able to claim.
    (asserts! (is-none (get-swept-deposit txid vout-index)) ERR_DEPOSIT_SWEPT)
    ;; First reveal takes the txid. A second one -- from anyone, including a
    ;; member who committed to the same transaction -- finds it gone.
    (asserts!
      (map-insert announcements {
        txid: txid,
        vout-index: vout-index,
      } {
        member: member,
        sats: sats,
        ustx: ustx,
        announced-at-height: burn-block-height,
      })
      ERR_DEPOSIT_ALREADY_ANNOUNCED
    )
    (map-delete commitments {
      member: member,
      digest: digest,
    })

    (let ((result {
        member: member,
        txid: txid,
        vout-index: vout-index,
        sats: sats,
        ustx: ustx,
        deposit-to: (get-deposit-address),
        cancellable-from: (+ burn-block-height ANNOUNCE_TTL),
      }))
      (print (merge { topic: "reveal-btc-deposit" } result))
      (ok result)
    )
  )
)

;; Give up on a commitment that was never revealed and take its STX leg back.
;; The member may do this whenever; anyone may once COMMIT_TTL burn blocks have
;; passed, so a commitment that goes nowhere cannot hold the pool's room for
;; long. Both arguments are public from the commit onwards.
(define-public (cancel-btc-commitment
    (member principal)
    (digest (buff 32))
  )
  (let (
      (commitment (unwrap!
        (map-get? commitments {
          member: member,
          digest: digest,
        })
        ERR_UNKNOWN_COMMITMENT
      ))
      (ustx (get ustx commitment))
    )
    (asserts!
      (or
        (is-eq tx-sender member)
        (>= burn-block-height
          (+ (get committed-at-height commitment) COMMIT_TTL)
        )
      )
      ERR_ANNOUNCEMENT_LIVE
    )

    (map-delete commitments {
      member: member,
      digest: digest,
    })
    (try! (contract-call? .bond-staker abandon-bridged-deposit (get sats commitment)))
    (try! (as-contract? ((with-stx ustx)) (try! (stx-transfer? ustx tx-sender member))))

    (let ((result {
        member: member,
        digest: digest,
        sats: (get sats commitment),
        ustx: ustx,
      }))
      (print (merge { topic: "cancel-btc-commitment" } result))
      (ok result)
    )
  )
)

;; Queue an announced deposit now that the sBTC signers have swept it.
;; Permissionless: the sats go to whoever announced the transaction, so anyone
;; can finish the job for them.
;;
;; A confirmation that lands after the bond has been staked queues for the bond
;; after it, priced by the STX paid at announcement -- so it may be scaled back
;; by that roll like any other under-funded position.
(define-public (confirm-btc-deposit
    (txid (buff 32))
    (vout-index uint)
  )
  (let (
      (claim (unwrap! (get-announcement txid vout-index) ERR_UNKNOWN_DEPOSIT))
      (swept (unwrap! (get-swept-deposit txid vout-index) ERR_DEPOSIT_NOT_SWEPT))
      (member (get member claim))
      (announced (get sats claim))
      (ustx (get ustx claim))
      ;; What the pool actually received, which is what it can credit.
      (credited (if (< (get amount swept) announced)
        (get amount swept)
        announced
      ))
    )
    ;; The signers minted to whoever the deposit named. Only the treasury will
    ;; do: anywhere else and the pool does not have the sats.
    (asserts! (is-eq (get recipient swept) (get-deposit-address))
      ERR_DEPOSIT_MISDIRECTED
    )
    ;; A deposit is credited for what arrived, not for what was announced.
    ;;
    ;; The two differ in the ordinary case: the sBTC signers take their bitcoin
    ;; fee out of the deposit, so what they mint is a little less than what was
    ;; sent. Refusing the difference would strand the deposit -- the sats are
    ;; already swept, which is exactly the point past which `cancel-btc-deposit`
    ;; will not take an announcement back -- leaving the STX leg here with no
    ;; way out and the sats in the treasury attributed to nobody.
    ;;
    ;; An overpayment is not credited: the excess is in the treasury as
    ;; unattributed principal, the same as any other unannounced sats.
    (asserts! (> (get amount swept) u0) ERR_INVALID_AMOUNT)

    (map-delete announcements {
      txid: txid,
      vout-index: vout-index,
    })
    ;; The shortfall never arrived, so the room it was holding goes back to the
    ;; pool rather than staying reserved against a deposit that is now closed.
    (if (< credited announced)
      (try! (contract-call? .bond-staker abandon-bridged-deposit
        (- announced credited)
      ))
      true
    )
    ;; Hand the STX leg over first, so the ledger holds it before it counts it.
    ;;
    ;; All of it, priced on the announcement rather than re-priced on the
    ;; shortfall: it is the member's own STX either way -- it comes back to them
    ;; as released principal when they leave -- and a leg sized to more sats than
    ;; the position holds can only leave them further from STX-limited, never
    ;; nearer. Re-pricing here would mean reading a bond that may have rolled
    ;; since the announcement.
    (try! (as-contract? ((with-stx ustx))
      (try! (stx-transfer? ustx tx-sender .bond-staker))
    ))
    (try! (contract-call? .bond-staker credit-bridged-deposit member credited ustx))

    (let ((result {
        member: member,
        txid: txid,
        vout-index: vout-index,
        sats: credited,
        announced-sats: announced,
        ustx: ustx,
        swept-sats: (get amount swept),
      }))
      (print (merge { topic: "confirm-btc-deposit" } result))
      (ok result)
    )
  )
)

;; Give up on an announced deposit and take its STX leg back. The member may do
;; this whenever; anyone may once ANNOUNCE_TTL burn blocks have passed, so a
;; deposit that never arrives cannot hold the pool's room for good.
;;
;; If the bitcoin does turn up afterwards it lands in the treasury with nothing
;; tying it to anyone, and only the pool's sweep can move it -- so cancel a
;; deposit you have already broadcast at your own risk.
(define-public (cancel-btc-deposit
    (txid (buff 32))
    (vout-index uint)
  )
  (let (
      (claim (unwrap! (get-announcement txid vout-index) ERR_UNKNOWN_DEPOSIT))
      (member (get member claim))
      (ustx (get ustx claim))
    )
    (asserts!
      (or
        (is-eq tx-sender member)
        (>= burn-block-height (+ (get announced-at-height claim) ANNOUNCE_TTL))
      )
      ERR_ANNOUNCEMENT_LIVE
    )
    ;; Once it is swept it belongs in the pool, not back in a wallet.
    (asserts! (is-none (get-swept-deposit txid vout-index)) ERR_DEPOSIT_SWEPT)

    (map-delete announcements {
      txid: txid,
      vout-index: vout-index,
    })
    (try! (contract-call? .bond-staker abandon-bridged-deposit (get sats claim)))
    (try! (as-contract? ((with-stx ustx)) (try! (stx-transfer? ustx tx-sender member))))

    (let ((result {
        member: member,
        txid: txid,
        vout-index: vout-index,
        sats: (get sats claim),
        ustx: ustx,
      }))
      (print (merge { topic: "cancel-btc-deposit" } result))
      (ok result)
    )
  )
)

;;; Going out

;; Take your released principal out as bitcoin instead of sBTC.
;;
;; `max-fee` is the most of it you will let the sBTC signers spend on the
;; bitcoin transaction; it comes out of the amount, so `released - max-fee` is
;; sent and the rest covers the fee. Anything the signers do not spend stays
;; with the pool as unattributed principal rather than coming back to you --
;; keep `max-fee` tight.
;;
;; Only you can call this: it spends your sats on a fee and picks the address
;; they land at.
;;
;; If the signers reject the request, `reclaim-btc-withdrawal` puts the whole
;; amount back on your claim. The STX leg is untouched -- `bond-staker`'s
;; `claim-principal` still hands that back on Stacks, the only place STX exists.
(define-public (claim-principal-to-btc
    (recipient {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (max-fee uint)
  )
  (let (
      (member tx-sender)
      ;; Moves the member's released sats into the pool's "withdrawing"
      ;; bucket and tells us how much that was.
      (locked (try! (contract-call? .bond-staker debit-released-for-bridge member max-fee)))
    )
    (let ((request-id (try! (contract-call? .bond-treasury request-btc-withdrawal (- locked max-fee)
        recipient max-fee
      ))))
      (map-set withdrawals request-id {
        member: member,
        sats: locked,
      })
      (let ((result {
          member: member,
          request-id: request-id,
          sats: locked,
          amount: (- locked max-fee),
          max-fee: max-fee,
          recipient: recipient,
        }))
        (print (merge { topic: "claim-principal-to-btc" } result))
        (ok result)
      )
    )
  )
)

;; Settle a bitcoin withdrawal the sBTC signers have ruled on. Permissionless,
;; and worth calling either way -- a rejected request has to be put back on the
;; member's claim before they can do anything with it, and an accepted one is
;; still holding a place in the pool's books until this runs.
(define-public (reclaim-btc-withdrawal (request-id uint))
  (let (
      (request (unwrap! (get-withdrawal request-id) ERR_UNKNOWN_WITHDRAWAL))
      (bridged (unwrap!
        (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry
          get-withdrawal-request request-id
        )
        ERR_UNKNOWN_WITHDRAWAL
      ))
      (accepted (unwrap! (get status bridged) ERR_WITHDRAWAL_PENDING))
      (member (get member request))
      (sats (get sats request))
    )
    (map-delete withdrawals request-id)
    ;; Rejected: the sBTC bridge has unlocked the lot back to the treasury, so
    ;; put it back on the member's claim. Accepted: the bitcoin went out, and
    ;; whatever was left of `max-fee` is unattributed principal.
    (try! (contract-call? .bond-staker settle-bridge-withdrawal member sats accepted))

    (let ((result {
        member: member,
        request-id: request-id,
        sats: sats,
        accepted: accepted,
      }))
      (print (merge { topic: "reclaim-btc-withdrawal" } result))
      (ok result)
    )
  )
)
