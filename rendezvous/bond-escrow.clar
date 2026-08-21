;; Fuzzing-only stand-in for pox-5's sBTC custody.
;;
;; Simnet cannot create a pox-5 protocol bond -- `setup-bond` is gated on the
;; bond admin, an address no simnet wallet holds -- so the fuzz harness cannot
;; drive the real `stake` / `unstake` path. This contract plays the part of
;; pox-5 for the one thing that matters to the pool's accounting: it holds the
;; pooled sBTC while the position is "staked" and hands it back on release.
;;
;; Deliberately unguarded. It is never deployed outside the fuzzing manifest.

(define-public (release
    (amount uint)
    (recipient principal)
  )
  (as-contract?
    ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
      amount
    ))
    (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      transfer amount tx-sender recipient none
    ))
  )
)

(define-read-only (get-balance)
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance current-contract
  )
)
