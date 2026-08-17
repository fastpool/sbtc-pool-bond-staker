;;; ------------------------------------------------------------------------
;;; Rendezvous harness
;;;
;;; Everything below is appended to a verbatim copy of
;;; contracts/bond-staker.clar by `pnpm run fuzz:build`. It is never part of a
;;; deployment.
;;;
;;; Why a harness is needed: a pox-5 protocol bond can only be created by the
;;; bond admin, an address no simnet wallet holds, so on simnet `bind-bond`,
;;; `stake` and `unstake-sbtc` can never get past their pox-5 calls. The
;;; `harness-*` functions below stand in for pox-5:
;;;
;;;   harness-bind     <- bind-bond     (bond parameters, no pox-5 lookup)
;;;   harness-lock     <- stake         (treasury <-> `bond-escrow` custody)
;;;   harness-release  <- unstake-sbtc  (escrow -> here -> treasury)
;;;
;;; They write exactly the state the real functions write and move the sBTC
;;; exactly as pox-5 would, so every invariant below is a statement about the
;;; production code paths around them: deposit, withdraw, request-exit,
;;; cancel-exit, sync-rewards, claim-rewards, claim-principal and the whole of
;;; the settlement machinery are untouched originals.
;;;
;;; Two timings are shrunk so a run can reach the late states: a bond starts
;;; within 200 burn blocks rather than months out, and its term runs 3000 burn
;;; blocks rather than 12 reward cycles -- short enough to reach the
;;; wind-down, long enough that rolling on is the usual path rather than the
;;; first thing that happens. Epoch *closure* is left alone: it runs on pox-5's
;;; real reward cycles, so the fuzzer sees the same open/closed window the
;;; deployed pool would.
;;; ------------------------------------------------------------------------

(define-map context
  (string-ascii 100)
  { called: uint }
)

(define-private (update-context
    (function-name (string-ascii 100))
    (called uint)
  )
  (ok (map-set context function-name { called: called }))
)

;;; Stand-ins for the pox-5 calls

;; `bind-bond` without the pox-5 lookups. Arguments are folded into sane
;; ranges so a random call produces a usable bond instead of bouncing. The
;; pricing is fixed at the first bind: letting it drift between bonds would
;; mostly produce rolls that bounce on the STX floor, which the unit tests
;; cover directly.
(define-public (harness-bind
    (allocation-sats uint)
    (ratio uint)
    (bips uint)
    (blocks-ahead uint)
  )
  (let ((start (+ burn-block-height u1 (mod blocks-ahead u200))))
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    ;; Same rule as `bind-bond`: a bond whose window has closed unstaked can be
    ;; replaced. rv jumps hundreds of burn blocks between rounds, so without
    ;; this the first missed window would end the run.
    (asserts! (not (can-still-stake)) ERR_BOND_ALREADY_BOUND)
    (if (is-eq (var-get epoch-count) u0)
      (begin
        ;; Any deployed contract will do -- the harness never calls it -- but it
        ;; has to be a contract, since that is what the trust list keys on.
        (map-set operators DEPLOYER true)
        (var-set signer-manager .bond-treasury)
        (map-set trusted-signers
          (unwrap-panic (contract-hash? .bond-treasury)) u0
        )
        (var-set initialized true)
        (var-set pending-stx-value-ratio (+ u1 (mod ratio u1000000)))
        (var-set pending-min-ustx-ratio (+ u1 (mod bips u10000)))
      )
      true
    )
    (var-set pending-bond-index (* (var-get epoch-count) NEXT_BOND_OFFSET))
    (var-set pending-max-sats (+ u1000000 (mod allocation-sats u100000000000)))
    (var-set pending-start-height start)
    (var-set pending-unlock-height (+ start u3000))
    ;; The notice runs from here, same as `bind-bond`.
    (var-set bound-at-height burn-block-height)
    (var-set bond-bound true)
    (ok true)
  )
)

;; `stake` without pox-5: same gates, same state, and the sBTC difference
;; moves between the treasury and the escrow exactly as it would move between
;; the treasury and pox-5.
(define-public (harness-lock)
  (let (
      (preview (get-stake-preview))
      (eligible (get eligible-sats preview))
      (sats (get sats preview))
      (ustx (get ustx preview))
      (custodied (var-get bonded-sats))
      (epoch (var-get epoch-count))
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (> eligible u0) ERR_NOTHING_DEPOSITED)
    (asserts! (> sats u0) ERR_INSUFFICIENT_STX)
    (asserts! (>= burn-block-height (stake-window-start)) ERR_TOO_EARLY)
    (asserts! (< burn-block-height (var-get pending-start-height)) ERR_TOO_LATE)
    (asserts! (>= burn-block-height (+ (var-get bound-at-height) BIND_NOTICE))
      ERR_TOO_EARLY
    )

    (if (> sats custodied)
      (begin
        (try! (contract-call? .bond-treasury payout (- sats custodied)
          current-contract
        ))
        (try! (as-contract?
          ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            "sbtc-token" (- sats custodied)
          ))
          (try!
            (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              transfer (- sats custodied) tx-sender .bond-escrow none
            ))
        ))
      )
      (if (< sats custodied)
        (begin
          (try! (contract-call? .bond-escrow release (- custodied sats)
            current-contract
          ))
          (try! (as-contract?
            ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              "sbtc-token" (- custodied sats)
            ))
            (try!
              (contract-call?
                'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer
                (- custodied sats) tx-sender .bond-treasury none
              ))
          ))
        )
        true
      )
    )

    (map-set epochs epoch {
      bond-index: (var-get pending-bond-index),
      first-reward-cycle: (+ u1
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          current-pox-reward-cycle
        )),
      unlock-burn-height: (var-get pending-unlock-height),
      staked-at-height: burn-block-height,
      eligible-sats: eligible,
      total-shares: sats,
      staked-sats: sats,
      staked-ustx: ustx,
      reward-index: u0,
      credited: u0,
    })
    (var-set epoch-count (+ epoch u1))
    (var-set released-sats
      (+ (var-get released-sats) (+ (var-get exiting-sats) (- eligible sats)))
    )
    (var-set released-ustx (+ (var-get released-ustx) (var-get exiting-ustx)))
    (var-set exiting-sats u0)
    (var-set exiting-ustx u0)
    (var-set queued-sats u0)
    (var-set queued-ustx u0)
    (var-set bonded-sats sats)
    (var-set bonded-ustx ustx)
    (var-set bond-bound false)
    (ok sats)
  )
)

;; `unstake-sbtc` without pox-5.
(define-public (harness-release)
  (let ((sats (var-get bonded-sats)))
    (asserts! (> (var-get epoch-count) u0) ERR_NOT_STAKED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts!
      (>= burn-block-height
        (get unlock-burn-height (unwrap-panic (get-live-epoch)))
      )
      ERR_TOO_EARLY
    )

    (var-set finished true)
    (var-set bond-bound false)
    (var-set released-sats (+ (var-get released-sats) sats))
    (var-set released-ustx (+ (var-get released-ustx) (var-get bonded-ustx)))
    (var-set bonded-sats u0)
    (var-set bonded-ustx u0)
    (var-set exiting-sats u0)
    (var-set exiting-ustx u0)

    (try! (contract-call? .bond-escrow release sats current-contract))
    (try! (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        "sbtc-token" sats
      ))
      (try!
        (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          transfer sats tx-sender .bond-treasury none
        ))
    ))
    (ok sats)
  )
)

;; The real `deposit`, with the amount folded into a range a simnet wallet can
;; actually pay. Fuzzing `deposit` directly is still worthwhile -- it covers
;; the rejection paths -- but a full-range uint never buys anything, so
;; without this the deposit-dependent half of the contract is never reached.
(define-public (harness-deposit (seed uint))
  (let (
      (committing (get-committing-sats))
      (room (if (> (var-get pending-max-sats) committing)
        (- (var-get pending-max-sats) committing)
        u0
      ))
      (ceiling (if (< room u2000000)
        room
        u2000000
      ))
    )
    (deposit (+ u1 (mod seed (+ u1 ceiling))))
  )
)

;; A reward payment landing on the pool, as the signer manager would make it.
(define-public (harness-pay-rewards (amount uint))
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    transfer amount tx-sender current-contract none
  )
)

;;; Invariants: the pool

;; Whatever rewards the pool has credited and not yet paid, it still holds.
;; The principal is the treasury's problem, never netted off this balance.
(define-read-only (invariant-sbtc-covers-unpaid-rewards)
  (>= (get-sbtc-balance) (get-unclaimed-rewards))
)

;; The treasury holds the principal that pox-5 does not: deposits waiting for a
;; bond, positions that have ended and not yet been claimed, and sats locked in
;; the sBTC bridge on their way to L1. It may hold more -- an unspent
;; withdrawal fee, an unannounced bridge deposit -- but never less.
(define-read-only (invariant-treasury-covers-its-books)
  (>= (get-treasury-balance)
    (+ (var-get queued-sats)
      (+ (var-get released-sats) (var-get withdrawing-sats))
    ))
)

;; Anything above the books is unattributed, and that is the only thing the
;; operator's sweep can reach.
(define-read-only (invariant-sweep-cannot-reach-principal)
  (<= (+ (get-unattributed-principal)
      (+ (var-get queued-sats)
        (+ (var-get released-sats) (var-get withdrawing-sats))
      ))
    (get-treasury-balance)
  )
)

;; The STX leg never leaves until it is claimed, so the contract can always
;; cover every member's STX.
(define-read-only (invariant-stx-covers-obligations)
  (let ((account (stx-account current-contract)))
    (>= (+ (get locked account) (get unlocked account))
      (+ (var-get queued-ustx) (+ (var-get bonded-ustx) (var-get released-ustx)))
    )
  )
)

;; The live epoch's shares are the pool's committed sats. Rewards are split by
;; the former and principal is owed on the latter, so the two must not drift.
(define-read-only (invariant-live-epoch-matches-the-pool)
  (match (get-live-epoch)
    live (or
      (var-get finished)
      (is-eq (get total-shares live) (var-get bonded-sats))
    )
    (and (is-eq (var-get bonded-sats) u0) (is-eq (var-get bonded-ustx) u0))
  )
)

;; Only a committed position can be on its way out.
(define-read-only (invariant-exits-fit-the-position)
  (and
    (<= (var-get exiting-sats) (var-get bonded-sats))
    (<= (var-get exiting-ustx) (var-get bonded-ustx))
  )
)

;; Rewards cannot start accruing before there is a bond to earn them.
(define-read-only (invariant-rewards-only-after-staking)
  (or
    (> (var-get epoch-count) u0)
    (and (is-eq (var-get total-credited) u0) (is-eq (var-get total-paid) u0))
  )
)

;; The pool never pays out more reward than it recognised.
(define-read-only (invariant-paid-within-credited)
  (<= (var-get total-paid) (var-get total-credited))
)

;; A wound-down pool holds no position and can never take another one.
(define-read-only (invariant-finished-is-final)
  (or
    (not (var-get finished))
    (and
      (is-eq (var-get bonded-sats) u0)
      (not (var-get bond-bound))
    )
  )
)

;;; Invariants: a member

;; No member holds more weight in their epoch than the epoch itself has.
(define-read-only (invariant-member-shares-fit-the-epoch (member principal))
  (match (get-settled-member member)
    record (match (map-get? epochs (get settled-epoch record))
      current (<= (get shares record) (get total-shares current))
      ;; No epoch under that index yet: the member cannot hold shares in it.
      (is-eq (get shares record) u0)
    )
    true
  )
)

;; No member is owed more reward than the pool has credited and not paid.
(define-read-only (invariant-member-rewards-fit-the-pool (member principal))
  (match (get-settled-member member)
    record (<= (get pending record) (get-unclaimed-rewards))
    true
  )
)

;; A member's principal is always covered by the pool's own books, on both
;; legs and in whichever bucket it currently sits.
(define-read-only (invariant-member-principal-fits-the-pool (member principal))
  (match (get-settled-member member)
    record (and
      (<= (get queued-sats record) (var-get queued-sats))
      (<= (get queued-ustx record) (var-get queued-ustx))
      (<= (get released-sats record) (var-get released-sats))
      (<= (get released-ustx record) (var-get released-ustx))
      (<= (get bonded-sats record)
        (+ (var-get bonded-sats) (var-get released-sats))
      )
      (<= (get bonded-ustx record)
        (+ (var-get bonded-ustx) (var-get released-ustx))
      )
    )
    true
  )
)

;; A member never sits beyond the next epoch the pool could open. A newcomer
;; starts one ahead of the live epoch -- that is how they hold no shares in
;; anything already running -- and nothing may carry them further.
(define-read-only (invariant-member-settled-within-the-pool (member principal))
  (match (get-settled-member member)
    record (<= (get settled-epoch record) (var-get epoch-count))
    true
  )
)

;; Holding shares means sitting in an epoch that has actually opened, so the
;; weight is always measured against a real reward pot. Together with
;; `invariant-member-shares-fit-the-epoch` this is what stops a member being
;; carried past an epoch they still have weight in.
(define-read-only (invariant-member-shares-need-an-epoch (member principal))
  (match (get-settled-member member)
    record (or
      (is-eq (get shares record) u0)
      (< (get settled-epoch record) (var-get epoch-count))
    )
    true
  )
)

;; The pool is always pointed at a contract, never a bare account -- the trust
;; list keys on code hashes, and only a contract has one.
;;
;; Note what is *not* asserted: that the current manager is still trusted.
;; Distrusting takes effect at once and deliberately does not unwind a move
;; already made, so a manager can outlive its entry on the list. That the
;; operator can only ever *move onto* a trusted one is a property of the
;; transition rather than of the state, and is covered by the unit tests.
(define-read-only (invariant-signer-manager-is-a-contract)
  (or
    (is-eq (var-get epoch-count) u0)
    (is-ok (contract-hash? (var-get signer-manager)))
  )
)

;;; Properties

;; The STX the pool charges is never less than the STX pox-5 demands for the
;; same sats -- the whole point of rounding the per-deposit leg up.
;; #[env(simnet)]
(define-private (test-required-ustx-covers-pox-minimum (sats uint))
  (let ((bounded (mod sats u100000000000)))
    (asserts!
      (>= (get-required-ustx bounded)
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          min-ustx-for-sats-amount bounded (var-get pending-stx-value-ratio)
          (var-get pending-min-ustx-ratio)
        ))
      (err u900)
    )
    (ok true)
  )
)

;; `ceil-div` rounds up, and by less than one whole denominator.
;; #[env(simnet)]
(define-private (test-ceil-div-is-tight
    (numerator uint)
    (denominator uint)
  )
  (let (
      (n (mod numerator u1000000000000000000))
      (d (+ u1 (mod denominator u1000000)))
      (q (ceil-div (mod numerator u1000000000000000000)
        (+ u1 (mod denominator u1000000))
      ))
    )
    (asserts! (>= (* q d) n) (err u901))
    (asserts! (or (is-eq q u0) (< (* (- q u1) d) n)) (err u902))
    (ok true)
  )
)

;; Settling never loses rewards a member had already accrued, and never
;; moves their principal.
;; #[env(simnet)]
(define-private (test-settle-preserves-pending-and-principal
    (sats uint)
    (pending uint)
  )
  (let (
      (record {
        shares: (mod sats u100000000),
        bonded-sats: (mod sats u100000000),
        bonded-ustx: u0,
        queued-sats: u0,
        queued-ustx: u0,
        queued-epoch: u0,
        released-sats: u0,
        released-ustx: u0,
        settled-epoch: u0,
        reward-index: u0,
        pending: (mod pending u100000000),
        tail-epoch: none,
        tail-shares: u0,
        tail-index: u0,
        exit-epoch: none,
      })
      (settled (settle record))
    )
    (asserts! (>= (get pending settled) (get pending record)) (err u903))
    ;; principal is only ever moved between buckets, never created or lost
    (asserts!
      (is-eq
        (+ (get bonded-sats settled)
          (+ (get queued-sats settled) (get released-sats settled))
        )
        (+ (get bonded-sats record)
          (+ (get queued-sats record) (get released-sats record))
        ))
      (err u904)
    )
    (ok true)
  )
)
