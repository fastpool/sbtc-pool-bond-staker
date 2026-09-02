;; A verification stand-in for sbtc-token.
;;
;; Unlike the pox-5 stub, this one is a *real* implementation rather than an
;; oracle. `invariant-sbtc-covers-unpaid-rewards` is stated against the pool's
;; own sBTC balance, so a `transfer` that did not actually move the balance
;; would let that invariant hold no matter what the pool did with the money.
;; The token is the one dependency the proof genuinely rests on, so it is
;; modelled rather than approximated.
;;
;; Balances live in a map rather than a `define-fungible-token` because the
;; engine has not implemented the ft-* natives (they are `todo!()`). The two
;; are behaviourally the same for everything being checked here: a balance is
;; a uint per principal, a transfer moves it, and the error codes match the
;; VM's. An account this trace never wrote reads as `(default-to u0 ...)`,
;; which the engine explores both ways -- absent, or present with an
;; unconstrained value -- so no starting balance is being assumed.
(define-map balances principal uint)

(define-read-only (get-balance (who principal))
  (ok (default-to u0 (map-get? balances who)))
)

;; Error codes match `ft-transfer?`: u1 not enough balance, u2 sender is the
;; recipient, u3 amount is zero.
(define-public (transfer
    (amount uint)
    (sender principal)
    (recipient principal)
    (memo (optional (buff 34)))
  )
  (let (
      (from (default-to u0 (map-get? balances sender)))
      (to (default-to u0 (map-get? balances recipient)))
    )
    (asserts! (is-eq tx-sender sender) (err u4))
    (asserts! (> amount u0) (err u3))
    (asserts! (not (is-eq sender recipient)) (err u2))
    (asserts! (<= amount from) (err u1))
    (map-set balances sender (- from amount))
    (map-set balances recipient (+ to amount))
    (ok true)
  )
)

;; Lets a harness put sats somewhere without going through a transfer.
(define-public (mint (amount uint) (recipient principal))
  (begin
    (map-set balances recipient
      (+ (default-to u0 (map-get? balances recipient)) amount)
    )
    (ok true)
  )
)
