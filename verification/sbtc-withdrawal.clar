;; A verification stand-in for sbtc-withdrawal, on the same terms as the pox-5
;; stub: the request id it hands back is unconstrained, and whether the call
;; succeeds at all is too, so nothing downstream may assume either.
;;
;; It moves no sBTC. That matches the real contract as bond-treasury uses it --
;; the comment at the call site is explicit that the bridge locks the sats in
;; place rather than moving them out -- and it is the conservative direction
;; regardless: sats that stay put are sats the treasury's own books still have
;; to account for.
(define-map request-ids uint uint)
(define-data-var next-id uint u0)
(define-map refuses uint bool)

(define-public (initiate-withdrawal-request
    (amount uint)
    (recipient {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (max-fee uint)
  )
  (begin
    (asserts! (not (default-to false (map-get? refuses u0))) (err u1))
    (ok (default-to u0 (map-get? request-ids (var-get next-id))))
  )
)
