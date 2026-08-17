;; Bitcoin Staking Bond treasury
;;
;; Holds the sBTC principal of the `bond-staker` pool deployed alongside it.
;; Its sBTC balance *is* the pooled principal: sBTC arrives here straight from
;; the depositor and leaves only when `bond-staker` sends it to pox-5 for the
;; bond term or hands it back to a depositor.
;;
;; The point of the separation is that `bond-staker` never has to tell its own
;; sBTC apart. Principal is here, rewards are there; whatever sBTC the pool
;; holds is reward, with no reserve to net off first.
;;
;; This contract is inert on its own: it moves sBTC only when the
;; `bond-staker` contract deployed by the same address asks it to. Deploy the
;; two together, treasury first -- `bond-staker` calls this contract, so it
;; must already exist, while the `CONTROLLER` reference below is only a
;; principal value and does not need its target to be deployed yet.

(define-constant ERR_UNAUTHORIZED (err u200))

;; The only contract that may move funds out of here.
(define-constant CONTROLLER .bond-staker)

;; The pooled principal.
(define-read-only (get-balance)
  (unwrap-panic
    (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      get-balance current-contract
    ))
)

(define-read-only (get-controller)
  CONTROLLER
)

;; Send `amount` of the principal to `recipient`. `bond-staker` only calls
;; this to fund the bond, to refund a withdrawal, or to return a depositor's
;; principal once the bond is over.
(define-public (payout
    (amount uint)
    (recipient principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (try! (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        "sbtc-token" amount
      ))
      (try!
        (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
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
