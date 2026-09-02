;; A concrete implementation of pox-5's signer-manager-trait, so the trait
;; argument to `stake` / `unstake-sbtc` / `update-signer-manager` can be
;; dispatched. bond-staker only ever reads `contract-of` on it and forwards it,
;; so nothing about this implementation is load-bearing.
(impl-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)

(define-public (validate-stake! (sats uint) (ustx uint))
  (ok true)
)
