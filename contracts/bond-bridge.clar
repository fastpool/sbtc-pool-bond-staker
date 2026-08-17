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
;; So the member ties it themselves, in advance. `announce-btc-deposit` records
;; the transaction they are about to broadcast and takes its STX leg -- the one
;; Stacks transaction they were always going to have to send. They address the
;; bitcoin to `bond-treasury`. Once the signers have swept it,
;; `confirm-btc-deposit` reads the sBTC registry, matches the transaction to the
;; announcement, and has `bond-staker` queue the sats.
;;
;; Announcing before broadcasting is what makes this safe: until the transaction
;; is out, nobody else can know its txid to announce it first.
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
(define-constant ERR_DEPOSIT_TOO_SMALL (err u306))
(define-constant ERR_DEPOSIT_SWEPT (err u307))
(define-constant ERR_ANNOUNCEMENT_LIVE (err u308))
(define-constant ERR_UNKNOWN_WITHDRAWAL (err u309))
(define-constant ERR_WITHDRAWAL_PENDING (err u310))
(define-constant ERR_NOTHING_RELEASED (err u311))

(define-constant SBTC_REGISTRY 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry)
;; How long an announced deposit holds its allocation before anyone may cancel
;; it and hand the STX leg back. A sweep takes hours; a week of slack means a
;; deposit in flight is never cancelled from under its owner, while a deposit
;; that never comes cannot squat on the pool's room forever.
(define-constant ANNOUNCE_TTL u1000)

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
(define-private (get-swept-deposit
    (txid (buff 32))
    (vout-index uint)
  )
  (contract-call? SBTC_REGISTRY get-completed-deposit txid vout-index)
)

;; The STX a deposit of `sats` has to be accompanied by, for the bond the pool
;; is bound to.
(define-private (get-required-ustx (sats uint))
  (contract-call? .bond-staker get-required-ustx sats)
)

;;; Coming in

;; Announce a bitcoin deposit you are about to broadcast, and pay its STX leg.
;;
;; Address the bitcoin to `get-deposit-address` and announce it *before*
;; broadcasting, while its txid is still yours alone. The sats hold allocation
;; room in the pool from here on.
(define-public (announce-btc-deposit
    (txid (buff 32))
    (vout-index uint)
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
    ;; Nothing to announce if the bridge has already dealt with it: the sats
    ;; are in the treasury unattributed, and this call cannot claim them.
    (asserts! (is-none (get-swept-deposit txid vout-index)) ERR_DEPOSIT_SWEPT)
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

    ;; The STX leg is paid now and held here until the sats arrive.
    (try! (stx-transfer? ustx member current-contract))

    (let ((result {
        member: member,
        txid: txid,
        vout-index: vout-index,
        sats: sats,
        ustx: ustx,
        deposit-to: (get-deposit-address),
        cancellable-from: (+ burn-block-height ANNOUNCE_TTL),
      }))
      (print (merge { topic: "announce-btc-deposit" } result))
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
      (sats (get sats claim))
      (ustx (get ustx claim))
    )
    ;; The signers minted to whoever the deposit named. Only the treasury will
    ;; do: anywhere else and the pool does not have the sats.
    (asserts! (is-eq (get recipient swept) (get-deposit-address))
      ERR_DEPOSIT_MISDIRECTED
    )
    ;; Short of what was announced -- and paid for in STX. Cancel and announce
    ;; again for the amount that actually arrived.
    (asserts! (>= (get amount swept) sats) ERR_DEPOSIT_TOO_SMALL)

    (map-delete announcements {
      txid: txid,
      vout-index: vout-index,
    })
    ;; Hand the STX leg over first, so the ledger holds it before it counts it.
    (try! (as-contract? ((with-stx ustx))
      (try! (stx-transfer? ustx tx-sender .bond-staker))
    ))
    (try! (contract-call? .bond-staker credit-bridged-deposit member sats ustx))

    (let ((result {
        member: member,
        txid: txid,
        vout-index: vout-index,
        sats: sats,
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
      (bridged (unwrap! (contract-call? SBTC_REGISTRY get-withdrawal-request request-id)
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
