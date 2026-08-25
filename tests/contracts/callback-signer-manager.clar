;; A signer manager that calls back into the pool, for tests only.
;;
;; pox-5 hands control to the configured signer manager in the middle of
;; `register-for-bond`: it calls `validate-stake!` *before* it takes the
;; staker's sBTC. Nothing in the trait says a manager may not use that moment
;; to call the staker back, and pox-5's own reentrancy guard protects pox-5's
;; entry points, not `bond-staker`'s state.
;;
;; So this is the manager that does. `validate-stake!` calls the pool's public,
;; permissionless `sync-rewards` and then returns success, which is the shape
;; reported in fastpool/sbtc-pool-bond-staker#1: at that instant a growing roll
;; has the net principal sitting in the staker, and a pool that mistook it for
;; reward would credit it, return success, and be left owing rewards it does
;; not hold.
;;
;; `set-propagate` chooses what it does with the answer:
;;
;;   false   ignore it and return `(ok true)`, so the roll carries on and the
;;           test can look at what the pool believes afterwards
;;   true    `try!` it, so a refusal takes the whole roll down with it and the
;;           test can check that everything rolled back
;;
;; Registering as a pox-5 signer needs a signer-key grant, so `register-self`
;; is the same call the real managers expose and the fixture drives it the same
;; way.

(impl-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)
(use-trait signer-manager-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)

(define-constant ERR_UNAUTHORIZED_ADMIN (err u1002))
(define-constant ERR_UNAUTHORIZED_CALLER (err u1006))

(define-constant ADMIN tx-sender)

;; Whether a refusal from the pool is passed on or swallowed.
(define-data-var propagate bool false)

;; What the last `validate-stake!` got back, so a test can assert on the
;; rejection itself and not only on its consequences.
(define-data-var last-sync-response (response bool uint) (ok false))

;; And what the pool called its unrecognised rewards at that instant. This is
;; the number the whole issue is about: mid-roll it is the one moment the
;; staker's sBTC balance is not all reward, and the only way to read it from
;; inside that moment is to be the manager.
(define-data-var last-unrecognized uint u0)

(define-read-only (get-last-sync-response)
  (var-get last-sync-response)
)

(define-read-only (get-last-unrecognized)
  (var-get last-unrecognized)
)

(define-public (set-propagate (on bool))
  (begin
    (asserts! (is-eq tx-sender ADMIN) ERR_UNAUTHORIZED_ADMIN)
    (ok (var-set propagate on))
  )
)

;; As an admin, register this contract with a specific signer key. The signer
;; key grant must not have been used yet.
(define-public (register-self
    (signer-manager <signer-manager-trait>)
    (signer-key (buff 33))
    (auth-id uint)
    (signer-sig (buff 65))
  )
  (begin
    (asserts! (is-eq tx-sender ADMIN) ERR_UNAUTHORIZED_ADMIN)
    (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5 grant-signer-key
      signer-key current-contract auth-id signer-sig
    ))
    (contract-call? 'ST000000000000000000002AMW42H.pox-5 register-signer
      signer-manager signer-key
    )
  )
)

(define-public (validate-stake!
    ;; #[allow(unused_binding)]
    (staker principal)
    ;; #[allow(unused_binding)]
    (first-index uint)
    ;; #[allow(unused_binding)]
    (num-indexes uint)
    ;; #[allow(unused_binding)]
    (amount-ustx uint)
    ;; #[allow(unused_binding)]
    (amount-sats uint)
    ;; #[allow(unused_binding)]
    (is-bond bool)
    ;; #[allow(unused_binding)]
    (signer-calldata (optional (buff 500)))
  )
  (begin
    (asserts! (is-eq contract-caller 'ST000000000000000000002AMW42H.pox-5)
      ERR_UNAUTHORIZED_CALLER
    )
    (var-set last-unrecognized
      (contract-call? .bond-staker get-unrecognized-rewards)
    )
    (let ((response (contract-call? .bond-staker sync-rewards)))
      (var-set last-sync-response (match response
        synced (ok true)
        error (err error)
      ))
      (if (var-get propagate)
        (begin
          (try! response)
          (ok true)
        )
        (ok true)
      )
    )
  )
)
