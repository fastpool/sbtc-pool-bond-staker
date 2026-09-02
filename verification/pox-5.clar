;; A verification stand-in for pox-5, for `clairvoyance sym induct`.
;;
;; This is NOT a model of how pox-5 behaves. It is deliberately the weakest
;; contract that still type-checks against bond-staker, so that anything proved
;; against it is proved for *every* pox-5 that could sit behind this interface.
;;
;; Two rules keep it that way:
;;
;; 1. Every value it returns is unconstrained. Reads come from data vars and
;;    maps the engine has no initial value for, so it treats them as fresh
;;    symbols rather than the Clarity initialiser. Nothing here says a height
;;    is positive, or that cycles increase, or that a bond exists -- because
;;    pox-5 saying so is not something bond-staker's invariants may lean on.
;;
;; 2. Anything argument-dependent is keyed by that argument, through a map.
;;    A stub returning one symbol regardless of its arguments would quietly
;;    assert that two different bond indices have the same start height, which
;;    is an assumption, and assumptions are how a vacuous proof happens.
;;
;; The one thing it does model concretely is sBTC custody, because the pool's
;; own balance invariant is stated against it: `register-for-bond` moves the
;; difference between what pox-5 already holds for a staker and what the new
;; bond needs, and `unstake-sbtc` gives it back. A stub that skipped those
;; transfers would leave sats sitting in the pool and make
;; `invariant-sbtc-covers-unpaid-rewards` hold for the wrong reason.


;; bond-staker only ever forwards a manager and reads `contract-of` it, so the
;; shape of this trait is not load-bearing for anything being proved.
(define-trait signer-manager-trait
  ((validate-stake! (uint uint) (response bool uint)))
)

;;; Unconstrained oracles.
;; Each of these reads a slot nothing ever writes, which is what makes the
;; result a free symbol.
(define-map period-burn-height uint uint)
(define-map period-reward-cycle uint uint)
(define-map cycle-burn-height uint uint)
(define-map distribution-burn-height uint uint)
(define-map min-ustx {sats: uint, value-ratio: uint, min-ratio: uint} uint)
(define-map signer-info principal uint)
(define-map protocol-bond uint {stx-value-ratio: uint, min-ustx-ratio: uint})
(define-map bond-allowance {index: uint, who: principal} uint)
(define-data-var prepare-length uint u0)
(define-data-var current-cycle uint u0)

;; What pox-5 holds in sBTC for a given staker.
(define-map custody principal uint)

(define-read-only (get-pox-info)
  (ok {prepare-cycle-length: (var-get prepare-length)})
)

(define-read-only (current-pox-reward-cycle)
  (var-get current-cycle)
)

(define-read-only (bond-period-to-burn-height (index uint))
  (default-to u0 (map-get? period-burn-height index))
)

(define-read-only (bond-period-to-reward-cycle (index uint))
  (default-to u0 (map-get? period-reward-cycle index))
)

(define-read-only (reward-cycle-to-burn-height (cycle uint))
  (default-to u0 (map-get? cycle-burn-height cycle))
)

(define-read-only (distribution-cycle-to-burn-height (cycle uint))
  (default-to u0 (map-get? distribution-burn-height cycle))
)

(define-read-only (min-ustx-for-sats-amount (sats uint) (value-ratio uint) (min-ratio uint))
  (default-to u0
    (map-get? min-ustx {sats: sats, value-ratio: value-ratio, min-ratio: min-ratio})
  )
)

(define-read-only (get-signer-info (manager principal))
  (map-get? signer-info manager)
)

(define-read-only (get-protocol-bond (index uint))
  (map-get? protocol-bond index)
)

(define-read-only (get-bond-allowance (index uint) (who principal))
  (map-get? bond-allowance {index: index, who: who})
)

;; Whether a call succeeds is itself unconstrained: a stub that always
;; succeeded would leave the failure paths unexplored.
(define-map call-fails uint bool)
(define-private (fails (tag uint))
  (default-to false (map-get? call-fails tag))
)

;; Takes custody of the difference, exactly as the real one does. The target is
;; carried in the response argument, on whichever side the caller filled in.
(define-public (register-for-bond
    (index uint)
    (manager <signer-manager-trait>)
    (ustx uint)
    (target (response uint uint))
    (extra (optional uint))
  )
  (let (
      (staker tx-sender)
      (held (default-to u0 (map-get? custody staker)))
      (want (match target ok-sats ok-sats err-sats err-sats))
    )
    (asserts! (not (fails u1)) (err u1))
    (if (> want held)
      ;; The caller wrapped this call in its own allowance, so tx-sender is
      ;; still the staker and the pull needs nothing further.
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer (- want held) staker current-contract none))
      (if (< want held)
        (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token" (- held want)))
          (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer (- held want) tx-sender staker none))
        ))
        true
      )
    )
    (map-set custody staker want)
    ;; The real one hands back a record of the registration, which the pool
    ;; merges into its own print and returns. Nothing reads a field of it, so
    ;; the shape matters only for type-checking; the values are unconstrained.
    (ok {
      bond-index: index,
      locked-ustx: ustx,
      custodied-sats: want,
    })
  )
)

;; Gives sats back to the staker.
(define-public (unstake-sbtc (manager <signer-manager-trait>) (sats uint))
  (let (
      (staker tx-sender)
      (held (default-to u0 (map-get? custody staker)))
    )
    (asserts! (not (fails u2)) (err u2))
    (asserts! (<= sats held) (err u3))
    (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token" sats))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer sats tx-sender staker none))
    ))
    (map-set custody staker (- held sats))
    (ok sats)
  )
)

(define-public (update-bond-registration
    (manager <signer-manager-trait>)
    (old-manager <signer-manager-trait>)
    (extra (optional uint))
  )
  (begin
    (asserts! (not (fails u4)) (err u4))
    ;; Merged into the pool's print, like `register-for-bond`'s result, so it
    ;; has to be a tuple. Nothing reads a field of it.
    (ok {signer: (contract-of manager)})
  )
)
