;; A verification stand-in for .bond-escrow: it holds sBTC the pool has staked
;; and gives it back on `release`. Modelled with a real transfer for the same
;; reason as the token itself -- the pool's balance invariant is stated against
;; where the sats actually are.

(define-public (release (sats uint) (recipient principal))
  (begin
    (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token" sats))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer sats tx-sender recipient none))
    ))
    (ok sats)
  )
)
