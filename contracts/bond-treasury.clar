;; Bitcoin Staking Bond treasury
;;
;; Holds `bond-staker`'s sBTC principal; its balance is the pooled principal.
;; Any sBTC held by `bond-staker` itself is reward. Bridge L1 deposits to this
;; address, never to the pool. Moves sBTC only for `bond-staker` (payout) and
;; `bond-bridge` (withdrawal request). Deploy before both.

(define-constant ERR_UNAUTHORIZED (err u3000))

;; Only caller of `payout`.
(define-constant CONTROLLER .bond-staker)
;; Only caller of `request-btc-withdrawal`.
(define-constant BRIDGE .bond-bridge)

;; The pooled principal.
(define-read-only (get-balance)
  (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance current-contract
  ))
)

(define-read-only (get-controller)
  CONTROLLER
)

(define-read-only (get-bridge)
  BRIDGE
)

;; Send `amount` sats of principal to `recipient`. CONTROLLER only.
(define-public (payout
    (amount uint)
    (recipient principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (try! (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        amount
      ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer amount tx-sender recipient none
      ))
    ))
    (print {
      topic: "payout",
      amount: amount,
      recipient: recipient,
    })
    (ok amount)
  )
)

;; Open an sBTC withdrawal of `amount` sats to `recipient`; returns request id.
;; BRIDGE only. The treasury requests, so rejected/unspent sats return here.
(define-public (request-btc-withdrawal
    (amount uint)
    (recipient {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (max-fee uint)
  )
  (begin
    (asserts! (is-eq contract-caller BRIDGE) ERR_UNAUTHORIZED)
    (let ((request-id (try! (as-contract?
        ;; `amount + max-fee` is locked in place until the signers sweep.
        ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          "sbtc-token" (+ amount max-fee)
        ))
        (try! (contract-call?
          'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-withdrawal
          initiate-withdrawal-request amount recipient max-fee
        ))
      ))))
      (print {
        topic: "request-btc-withdrawal",
        request-id: request-id,
        amount: amount,
        max-fee: max-fee,
        recipient: recipient,
      })
      (ok request-id)
    )
  )
)
