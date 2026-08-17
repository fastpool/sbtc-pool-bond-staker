;; Bitcoin Staking Bond treasury
;;
;; Holds the sBTC principal of the `bond-staker` pool deployed alongside it.
;; Its sBTC balance *is* the pooled principal: sBTC arrives here straight from
;; the depositor -- or straight from the sBTC bridge, when the depositor came
;; in with L1 BTC -- and leaves only when `bond-staker` sends it to pox-5 for
;; the bond term, hands it back to a depositor, or sends it out over the bridge.
;;
;; This is the address to bridge *to*. Never the pool's: sBTC arriving there is
;; taken for reward and split among the members.
;;
;; The point of the separation is that `bond-staker` never has to tell its own
;; sBTC apart. Principal is here, rewards are there; whatever sBTC the pool
;; holds is reward, with no reserve to net off first.
;;
;; This contract is inert on its own: it moves sBTC only when the `bond-staker`
;; or `bond-bridge` contract deployed by the same address asks it to, and each
;; of them for one purpose only. Deploy this one first -- the other two call it,
;; so it has to exist, while the references below are only principal values and
;; do not need their targets deployed yet.

(define-constant ERR_UNAUTHORIZED (err u200))

;; The ledger, and the only contract that may hand principal back out.
(define-constant CONTROLLER .bond-staker)
;; The L1 on- and off-ramp, and the only contract that may put principal into
;; the sBTC bridge on its way to bitcoin.
(define-constant BRIDGE .bond-bridge)

(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant SBTC_WITHDRAWAL 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-withdrawal)
;; The pooled principal.
(define-public (get-balance)
  (contract-call? SBTC get-balance current-contract)
)

(define-read-only (get-controller)
  CONTROLLER
)

(define-read-only (get-bridge)
  BRIDGE
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
    (try! (as-contract? ((with-ft SBTC "sbtc-token" amount))
      (try! (contract-call? SBTC transfer amount tx-sender recipient none))
    ))
    (print {
      topic: "payout",
      amount: amount,
      recipient: recipient,
    })
    (ok amount)
  )
)

;; Ask the sBTC bridge to send `amount` to a bitcoin address, and return the
;; request id.
;;
;; The treasury is the requester, not `bond-staker`, and deliberately so: the
;; bridge unlocks `amount + max-fee` back to the requester if the signers
;; reject the request, and the unspent part of `max-fee` if they accept it.
;; Landing that in the pool would have it read as reward and split among the
;; members; landing it here keeps it principal, which is what it is.
;;
;; `bond-bridge` tracks the request so the member behind it can reclaim a
;; rejected one.
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
        ;; The bridge locks the sBTC in place rather than moving it out, and
        ;; may unlock it again later; either way nothing leaves this contract
        ;; until the signers sweep it.
        ((with-ft SBTC "sbtc-token" (+ amount max-fee)))
        (try! (contract-call? SBTC_WITHDRAWAL initiate-withdrawal-request amount
          recipient max-fee
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
