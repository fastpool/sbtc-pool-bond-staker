;; Bitcoin Staking Bond receipt: sBTC.
;;
;; A non-transferable SIP-010 token mirroring a member's sBTC principal in
;; `bond-staker`: balance = queued + bonded + released sats. A second token,
;; `bond-btc-locked`, mirrors sats the bridge holds in an sBTC withdrawal, so a
;; wallet shows where the sBTC is. Only `bond-staker` moves either.

(define-constant ERR_UNAUTHORIZED (err u500))
(define-constant ERR_NOT_TRANSFERABLE (err u501))

;; Only caller of the mint, burn, lock and unlock functions.
(define-constant CONTROLLER .bond-staker)

;; Principal claim on the pool, in sats.
(define-fungible-token bond-btc)
;; Principal in an sBTC withdrawal request, until the signers rule on it.
(define-fungible-token bond-btc-locked)

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
  (ok "Bond sBTC")
)

(define-read-only (get-symbol)
  (ok "bondBTC")
)

(define-read-only (get-decimals)
  (ok u8)
)

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance bond-btc who))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply bond-btc))
)

(define-read-only (get-token-uri)
  (ok none)
)

;;; Locked view

(define-read-only (get-locked-balance (who principal))
  (ok (ft-get-balance bond-btc-locked who))
)

(define-read-only (get-locked-supply)
  (ok (ft-get-supply bond-btc-locked))
)

;;; Controller

;; Principal entered the pool.
(define-public (mint
    (amount uint)
    (recipient principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (ft-mint? bond-btc amount recipient)
  )
)

;; Principal paid out on Stacks.
(define-public (burn
    (amount uint)
    (owner principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (ft-burn? bond-btc amount owner)
  )
)

;; Released principal moved into an sBTC withdrawal request.
(define-public (lock
    (amount uint)
    (member principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (try! (ft-burn? bond-btc amount member))
    (ft-mint? bond-btc-locked amount member)
  )
)

;; The signers rejected the withdrawal; the principal is released again.
(define-public (unlock
    (amount uint)
    (member principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (try! (ft-burn? bond-btc-locked amount member))
    (ft-mint? bond-btc amount member)
  )
)

;; The signers accepted the withdrawal; the BTC left for L1.
(define-public (burn-locked
    (amount uint)
    (member principal)
  )
  (begin
    (asserts! (is-eq contract-caller CONTROLLER) ERR_UNAUTHORIZED)
    (ft-burn? bond-btc-locked amount member)
  )
)
