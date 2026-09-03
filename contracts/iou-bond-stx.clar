;; Bitcoin Staking Bond receipt: STX.
;;
;; A non-transferable SIP-010 token mirroring a member's STX leg in
;; `bond-staker`: balance = queued + bonded + released ustx. STX is only ever
;; paid out on Stacks, so there is no locked counterpart. Only `bond-staker`
;; mints or burns.

(define-constant ERR_UNAUTHORIZED (err u7000))
(define-constant ERR_NOT_TRANSFERABLE (err u7001))

;; Only caller of `mint` and `burn`.
(define-constant CONTROLLER .bond-staker)

(define-fungible-token bond-stx)

;;; SIP-010

(define-public (transfer
    (amount uint)
    (sender principal)
    (recipient principal)
    (memo (optional (buff 34)))
  )
  ERR_NOT_TRANSFERABLE
)

(define-read-only (get-name)
  (ok "Bond STX")
)

(define-read-only (get-symbol)
  (ok "bondSTX")
)

(define-read-only (get-decimals)
  (ok u6)
)

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance bond-stx who))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply bond-stx))
)

(define-read-only (get-token-uri)
  (ok none)
)

;;; Controller

;; STX leg entered the pool.
(define-public (mint
    (amount uint)
    (recipient principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (ft-mint? bond-stx amount recipient)
  )
)

;; STX leg paid out.
(define-public (burn
    (amount uint)
    (owner principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (ft-burn? bond-stx amount owner)
  )
)
