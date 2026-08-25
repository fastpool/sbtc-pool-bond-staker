;; VENDORED, DO NOT EDIT BY HAND.
;;
;; The v1 FastPool signer manager, from the sibling `fastpool-pox-5` project at
;; 01bd5c1, where it now lives under the name
;; `contracts/signer-manager-accounting-multi.clar` -- it was renamed when v2
;; took the `signer-manager.clar` name. Its own `;; title:` line below still
;; says what it is.
;;
;; Copied verbatim: it is already written against the simnet pox-5 boot
;; address, so unlike the v2 above it needs no rewriting.
;;
;; It is here as the pool's *alternate* manager. `bond-staker` vets managers by
;; code hash and can be moved between them, so its tests need a second one that
;; is a genuinely different implementation rather than a second copy of the
;; first. Nothing in those tests reaches this contract's fees, payouts or L1
;; addresses; what they ask of it is that it register, validate a stake, and
;; hash differently.
;;
;; Vendored rather than referenced across the working tree so that `pnpm test`
;; needs nothing but this checkout.
;; ----------------------------------------------------------------------
;; title: fastpool-signer-manager
;; Reference implementation for the signer manager trait, to be used with pox-5.
;;
;; This contract allows stakers to set a `pox-addr` that, when present, allows
;; rewards to be automatically withdrawn to BTC via an sBTC withdrawal. Anyone
;; can trigger this withdrawal, which allows for passively receiving L1 rewards.
;;
;; Admins of this contract can set fees. When fees are set, they are automatically
;; deducted from any stakers _newly calculated_ rewards. That means that if a staker
;; has not claimed or crystallized rewards in some amount of time, then a new fee
;; rate is set, the next time that staker claims rewards will have fees taken
;; from reward _even before_ the fee was set.

(impl-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)
(use-trait signer-manager-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)

;; A staker tried to claim rewards, but they had none available
(define-constant ERR_NO_CLAIMABLE_REWARDS (err u1001))
;; Attempted to call an admin function
(define-constant ERR_UNAUTHORIZED_ADMIN (err u1002))
;; the calldata provided when staking was invalid
(define-constant ERR_INVALID_CALLDATA (err u1003))
;; The pox-addr provided as calldata isn't valid
(define-constant ERR_INVALID_POX_ADDR (err u1004))
;; The fees provided when updating fees is invalid
(define-constant ERR_INVALID_FEES_BIPS (err u1005))
;; A pox-5 callback (validate-stake!) was invoked by a
;; principal other than the pox-5 contract.
(define-constant ERR_UNAUTHORIZED_CALLER (err u1006))
;; Attempted to withdraw more fees than have accrued.
(define-constant ERR_INSUFFICIENT_FEES (err u1007))
;; The given withdrawal-request id is not tracked by this contract.
(define-constant ERR_UNKNOWN_WITHDRAWAL_REQUEST (err u1008))
;; The withdrawal request has not been rejected, so its full
;; `amount + max-fee` is not reclaimable for the staker.
(define-constant ERR_WITHDRAWAL_NOT_REJECTED (err u1009))
;; No refunds available to sweep.
(define-constant ERR_NO_REFUNDS (err u1010))
;; The withdrawal request has not been accepted, so it cannot be
;; settled via `settle-accepted-withdrawal`.
(define-constant ERR_WITHDRAWAL_NOT_ACCEPTED (err u1011))
;; The mirrored share total disagrees with pox-5's, so local settlement cannot
;; be trusted for this cycle.
(define-constant ERR_SHARE_MIRROR_MISMATCH (err u1012))
;; This cycle has already been settled through the other path.
(define-constant ERR_CYCLE_MODE_LOCKED (err u1013))

(define-constant MAX_BIPS u10000)

;; Maximum value of an address version as a uint
(define-constant MAX_ADDRESS_VERSION u6)
;; Maximum value of an address version that has a 20-byte hashbytes
;; (0x00, 0x01, 0x02, 0x03, and 0x04 have 20-byte hashbytes)
(define-constant MAX_ADDRESS_VERSION_BUFF_20 u4)

;; default to allowing deployer to register as a pool
(define-map admins
  principal
  bool
)
(map-set admins tx-sender true)

;; Fees taken, in basis points, from rewards
(define-data-var fees-bips uint u0)

;; Amount of earned fees that are held by the contract.
;; When fees are transferred out of the contract, this value
;; must be deducted.
(define-data-var earned-fees uint u0)

(define-map fee-bips-for-cycle
  {
    reward-cycle: uint,
    bond-index: (optional uint),
  }
  uint
)
;; When stakers provide L1 withdrawal info as calldata,
;; that is stored here.
(define-map pox-addrs
  principal
  {
    pox-addr: {
      version: (buff 1),
      hashbytes: (buff 32),
    },
    max-fee: uint,
  }
)

;; Mapping of a given withdrawal request ID to the staker
;; whose rewards created that withdrawal.
(define-map withdrawal-requests
  uint
  principal
)

;; Sum of `amount + max-fee` over every live (un-settled) entry in
;; `withdrawal-requests`. Incremented when a withdrawal is initiated in
;; `claim-staker-rewards` and decremented when the request is settled
;; (`reclaim-failed-withdrawal` for rejected, `settle-accepted-withdrawal` for
;; accepted). This is staker-owed sBTC that has either left the contract balance
;; into the sBTC withdrawal system (pending) or been returned to the balance but
;; not yet paid out (rejected). `sweep-fee-refunds` subtracts it so an admin can
;; never sweep funds owed to a staker -- see the note on that function.
(define-data-var withdrawal-liability uint u0)

;; sBTC pulled into this contract by `claim-rewards` that has not yet been paid
;; out to an individual staker via `claim-staker-rewards`. `claim-rewards` adds
;; the gross `total-rewards` it received; each `claim-staker-rewards` subtracts
;; that staker's `gross` as it is distributed (whether paid as sBTC, sent for
;; an L1 withdrawal, or retained as a signer-manager fee). Like
;; `withdrawal-liability`, this is subtracted in `sweep-fee-refunds` so an
;; admin can never sweep staker rewards.
(define-data-var unclaimed-staker-rewards uint u0)

;;; Local (mirrored) staker accounting
;;
;; Every `contract-call?` into pox-5 is charged pox-5's full ~135KB source as
;; read_length, whatever the function does, so settling N stakers through
;; `claim-staker-rewards-for-signer` costs N * 135KB and caps a distribution at
;; roughly 700 stakers per block. That call moves no money -- `claim-rewards`
;; already delivered the whole pot to this contract -- it only tells us each
;; staker's share of it.
;;
;; So we keep that share ourselves. pox-5 calls `validate-stake!` on every path
;; that *increases* a staker's shares, which is enough to mirror them. It never
;; calls back on `unstake`, so the mirror can go stale -- but only ever by
;; overcounting, since unseen changes are always decreases. That makes a single
;; signer-level total from pox-5 a sufficient integrity check: see
;; `assert-mirror-matches-pox-5`.
;;
;; Covers both STX staking (`bond-index none`) and bonds. The two differ in
;; what pox-5 counts -- ustx against sats -- and in which signer-level total
;; can be trusted as the check; see `assert-mirror-matches-pox-5`.

;; A staker's mirrored shares for a cycle. Mirrors pox-5's
;; `staker-shares-staked-for-cycle`, which is an absolute per-cycle amount.
(define-map mirrored-shares
  {
    staker: principal,
    reward-cycle: uint,
    bond-index: (optional uint),
  }
  uint
)

;; Sum of `mirrored-shares` over all stakers for a cycle. Our side of the
;; integrity check against pox-5.
(define-map mirrored-total-shares
  {
    reward-cycle: uint,
    bond-index: (optional uint),
  }
  uint
)

;; Gross sBTC this contract has pulled in for a cycle via `claim-rewards`.
;; A cycle can be claimed more than once as rewards accrue, so this
;; accumulates.
(define-map cycle-rewards
  {
    reward-cycle: uint,
    bond-index: (optional uint),
  }
  uint
)

;; Gross already accounted to a staker for a cycle, so repeated distributions
;; only pay the difference.
(define-map staker-paid
  {
    staker: principal,
    reward-cycle: uint,
    bond-index: (optional uint),
  }
  uint
)

;; Which settlement path a cycle has used. The two must never mix: paying
;; locally leaves pox-5's per-staker ledger un-zeroed, so a later pox-5-settled
;; claim for the same cycle would pay the same rewards a second time.
(define-constant MODE_POX_5 u1)
(define-constant MODE_LOCAL u2)

(define-map cycle-mode
  {
    reward-cycle: uint,
    bond-index: (optional uint),
  }
  uint
)

;; Offsets used to walk the cycles a stake covers. pox-5 caps a lock at 12
;; cycles (`check-pox-lock-period`) and a bond term is exactly that long.
(define-constant CYCLE_OFFSETS (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11))
(define-constant BOND_LENGTH_CYCLES u12)

;; Record a staker's shares for one cycle, keeping `mirrored-total-shares` in
;; step. pox-5 stores shares as an absolute per-cycle amount, so a re-stake
;; overwrites rather than adds, and the running total moves by the difference.
(define-private (mirror-stake-for-cycle
    (offset uint)
    (acc {
      staker: principal,
      first-reward-cycle: uint,
      bond-index: (optional uint),
      shares: uint,
    })
  )
  (let (
      (reward-cycle (+ (get first-reward-cycle acc) offset))
      (staker (get staker acc))
      (shares (get shares acc))
      (bond-index (get bond-index acc))
      (previous (default-to u0
        (map-get? mirrored-shares {
          staker: staker,
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      ))
      (total (default-to u0
        (map-get? mirrored-total-shares {
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      ))
    )
    (map-set mirrored-shares {
      staker: staker,
      reward-cycle: reward-cycle,
      bond-index: bond-index,
    }
      shares
    )
    ;; `total` always includes `previous`, so this cannot underflow.
    (map-set mirrored-total-shares {
      reward-cycle: reward-cycle,
      bond-index: bond-index,
    }
      (+ (- total previous) shares)
    )
    acc
  )
)

;; Callback function from a `stake` transaction.
;;
;; If `signer-calldata` is provided, then it must be in the form
;; of `{ version, hashbytes }` as a pox-addr. If provided, the pox-addr
;; is saved for the user, and they'll receive rewards through sBTC withdrawals.
(define-public (validate-stake!
    (staker principal)
    (first-index uint)
    (num-indexes uint)
    (amount-ustx uint)
    (amount-sats uint)
    (is-bond bool)
    (signer-calldata (optional (buff 500)))
  )
  (begin
    (try! (authorize-pox-5))
    ;; Mirror the shares this stake grants. For STX staking pox-5 passes the
    ;; first reward cycle and a cycle count directly. For bonds `first-index` is
    ;; a bond index instead: the term is always `BOND_LENGTH_CYCLES` long and
    ;; its first cycle has to be derived, and the shares are denominated in sats.
    (fold mirror-stake-for-cycle
      (unwrap-panic (slice? CYCLE_OFFSETS u0
        (if is-bond
          BOND_LENGTH_CYCLES
          num-indexes
        ))) {
      staker: staker,
      first-reward-cycle: (if is-bond
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          bond-period-to-reward-cycle first-index
        )
        first-index
      ),
      bond-index: (if is-bond
        (some first-index)
        none
      ),
      shares: (if is-bond
        amount-sats
        amount-ustx
      ),
    })
    (ok (match signer-calldata
      calldata
      (let ((pox-addr (unwrap!
          (from-consensus-buff? {
            pox-addr: {
              version: (buff 1),
              hashbytes: (buff 32),
            },
            max-fee: uint,
          }
            calldata
          )
          ERR_INVALID_CALLDATA
        )))
        (try! (check-pox-addr (get pox-addr pox-addr)))
        (map-set pox-addrs staker pox-addr)
        true
      )
      ;; If `signer-calldata` is not provided, delete (if present)
      ;; their entry from `pox-addrs`.
      (map-delete pox-addrs staker)
    ))
  )
)

;; Claim rewards _as the signer manager_ contract. When new rewards are available
;; from pox-5, this function must be called before rewards will be seen as available
;; to stakers of this signer.
;;
;; This function is callable by anyone. Once called, this contract will receive sBTC,
;; and rewards information will be crystallized.
(define-public (claim-rewards
    (bond-periods (list 6 uint))
    (reward-cycle uint)
  )
  (let ((result (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5 claim-rewards
      bond-periods reward-cycle
    ))))
    ;; The sBTC just pulled in is owed to this signer's stakers until each
    ;; claims via `claim-staker-rewards`; reserve it so it is not sweepable.
    (var-set unclaimed-staker-rewards
      (+ (var-get unclaimed-staker-rewards) (get total-rewards result))
    )
    (map-insert fee-bips-for-cycle {
      reward-cycle: reward-cycle,
      bond-index: none,
    }
      (var-get fees-bips)
    )
    ;; Track the STX-staking pot per cycle so a locally-settled distribution
    ;; has something to divide by shares. A cycle can be claimed repeatedly as
    ;; rewards accrue, so this accumulates.
    (map-set cycle-rewards {
      reward-cycle: reward-cycle,
      bond-index: none,
    }
      (+
        (default-to u0
          (map-get? cycle-rewards {
            reward-cycle: reward-cycle,
            bond-index: none,
          })
        )
        (get earned (get stx-rewards result))
      ))
    (fold snapshot-bond-fee (get bond-rewards result) reward-cycle)
    (ok result)
  )
)

;;; Staker rewards

;; Get the total amount of rewards earned since the last
;; rewards snapshot for this staker. Returns a tuple of `{ earned, fees }`.
;; The total portion of rewards the staker has accounted for
;; is `earned + fees`.
(define-read-only (get-earned-staker-rewards
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (let (
      (earned-before-fees (contract-call? 'ST000000000000000000002AMW42H.pox-5
        get-earned-staker-rewards current-contract reward-cycle bond-index
        staker
      ))
      (fees (/ (* earned-before-fees (get-fee-bips-for-cycle reward-cycle bond-index))
        MAX_BIPS
      ))
    )
    {
      earned: (- earned-before-fees fees),
      fees: fees,
    }
  )
)

;; This contract must hold sBTC to be able to pay anyone out. Read once per
;; claim transaction rather than once per staker.
(define-private (has-sbtc-liquidity)
  (>
    (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      get-balance current-contract
    ))
    u0
  )
)

;; Settle and pay out one staker's rewards.
;;
;; The values that are invariant across a batch -- the fee rate for the cycle
;; (`fee-bips`), the remaining `unclaimed-staker-rewards` pool (`unclaimed`) and
;; whether this contract holds any sBTC at all (`has-liquidity`) -- are passed in
;; rather than read here, so that `claim-staker-rewards-many` reads them once
;; instead of once per staker. For the same reason this function does NOT update
;; `earned-fees` or `unclaimed-staker-rewards`; it returns the amounts it
;; accounted for and the caller applies them, once, for the whole batch.
;;
;; Returns `(ok none)` when there is nothing payable for this staker, so a batch
;; is never blocked by one staker. An `err` means the payout itself failed and
;; must abort the transaction.
(define-private (claim-staker-rewards-core
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
    (fee-bips uint)
    (unclaimed uint)
    (has-liquidity bool)
  )
  (let (
      ;; `unwrap-panic` is ok here: there is no `err` type returnable
      (rewards-info (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-5
        claim-staker-rewards-for-signer staker reward-cycle bond-index
      )))
      (gross (get earned rewards-info))
      (fees (/ (* gross fee-bips) MAX_BIPS))
      (earned (- gross fees))
    )
    (if (or
        ;; Nothing earned since the last claim.
        (is-eq earned u0)
        ;; Nothing in the contract to pay anyone out with.
        (not has-liquidity)
        ;; More than the pool has left to distribute.
        (> gross unclaimed)
      )
      (ok none)
      (if (try! (pay-staker staker earned reward-cycle bond-index))
        (ok (some {
          gross: gross,
          fees: fees,
          earned: earned,
        }))
        ;; The staker's L1 fee budget exceeds their reward; nothing paid.
        (ok none)
      )
    )
  )
)

;; Send `earned` to a staker, either as sBTC or -- when they registered a
;; pox-addr as staking calldata -- as an L1 sBTC withdrawal. Shared by both
;; the pox-5-settled and the locally-settled claim paths.
;;
;; Returns `(ok false)` without paying when the staker's L1 withdrawal fee
;; budget exceeds the reward, so a batch skips them instead of failing.
(define-private (pay-staker
    (staker principal)
    (earned uint)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  ;; Only read the staker's L1 info once a payout is actually happening: a
  ;; batch skips most stakers before this without touching the `pox-addrs` map.
  (let ((l1-info (get-pox-addr staker)))
    (if (match l1-info
        info (< earned (get max-fee info))
        false
      )
      (ok false)
      (match l1-info
        info (pay-staker-l1 staker earned reward-cycle bond-index info)
        (begin
          (try! (as-contract?
            ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              "sbtc-token" earned
            ))
            (begin
              (print {
                topic: "claim-staker-rewards",
                amount-sats: earned,
                l1-withdrawal: none,
                staker: staker,
                reward-cycle: reward-cycle,
                bond-index: bond-index,
              })
              (try! (contract-call?
                'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer
                earned tx-sender staker none
              ))
            )))
          (ok true)
        )
      )
    )
  )
)

;; Pay a staker who registered a pox-addr: their reward leaves as an L1 sBTC
;; withdrawal rather than an sBTC transfer, so it cannot be batched with the
;; others. Returns `(ok false)` when the fee budget exceeds the reward.
(define-private (pay-staker-l1
    (staker principal)
    (earned uint)
    (reward-cycle uint)
    (bond-index (optional uint))
    (l1-info {
      pox-addr: {
        version: (buff 1),
        hashbytes: (buff 32),
      },
      max-fee: uint,
    })
  )
  (if (< earned (get max-fee l1-info))
    (ok false)
    (begin
      (try! (as-contract?
        ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          "sbtc-token" earned
        ))
        (let (
            (amount (- earned (get max-fee l1-info)))
            (withdrawal-request (try! (contract-call?
              'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-withdrawal
              initiate-withdrawal-request amount (get pox-addr l1-info)
              (get max-fee l1-info)
            )))
          )
          (print {
            topic: "claim-staker-rewards",
            amount-sats: earned,
            l1-withdrawal: (some (merge l1-info {
              withdrawal-request: withdrawal-request,
              amount: amount,
            })),
            staker: staker,
            reward-cycle: reward-cycle,
            bond-index: bond-index,
          })
          (map-set withdrawal-requests withdrawal-request staker)
          ;; `amount + max-fee` == `earned` left the balance into the
          ;; sBTC withdrawal system; record it as staker liability.
          (var-set withdrawal-liability
            (+ (var-get withdrawal-liability) amount (get max-fee l1-info))
          )
          true
        )))
      (ok true)
    )
  )
)

;; Trigger a claim of rewards for a given staker.
;; Anyone can call this function, and it will transfer rewards to the
;; staker.
;;
;; If the staker provided a `pox-addr` as calldata while staking, then
;; rewards are withdrawn through sBTC to their L1 Bitcoin address. Otherwise,
;; the staker receives sBTC.
(define-public (claim-staker-rewards
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (let (
      (unclaimed-rewards (var-get unclaimed-staker-rewards))
      (claimed (unwrap!
        (try! (begin
          (try! (lock-cycle-mode reward-cycle bond-index MODE_POX_5))
          (claim-staker-rewards-core staker reward-cycle bond-index
            (get-fee-bips-for-cycle reward-cycle bond-index) unclaimed-rewards
            (has-sbtc-liquidity)
          )
        ))
        ERR_NO_CLAIMABLE_REWARDS
      ))
    )
    (map-set cycle-mode {
      reward-cycle: reward-cycle,
      bond-index: bond-index,
    }
      MODE_POX_5
    )
    (var-set earned-fees (+ (var-get earned-fees) (get fees claimed)))
    ;; This staker's share is being distributed now so release it from
    ;; the unclaimed count recorded when `claim-rewards` pulled it in.
    (var-set unclaimed-staker-rewards (- unclaimed-rewards (get gross claimed)))
    (ok (get earned claimed))
  )
)

(define-private (fold-claim-staker-rewards
    (staker principal)
    (acc (response {
      reward-cycle: uint,
      bond-index: (optional uint),
      fee-bips: uint,
      unclaimed: uint,
      has-liquidity: bool,
      total-earned: uint,
      total-fees: uint,
      claimed-count: uint,
    }
      uint
    ))
  )
  (let (
      (state (try! acc))
      (result (try! (claim-staker-rewards-core staker (get reward-cycle state)
        (get bond-index state) (get fee-bips state) (get unclaimed state)
        (get has-liquidity state)
      )))
    )
    (match result
      claimed
      (ok (merge state {
        ;; Carried through the fold so the pool is decremented once, at the end.
        unclaimed: (- (get unclaimed state) (get gross claimed)),
        total-earned: (+ (get total-earned state) (get earned claimed)),
        total-fees: (+ (get total-fees state) (get fees claimed)),
        claimed-count: (+ (get claimed-count state) u1),
      }))
      ;; Nothing payable for this staker: skip it and keep going.
      (ok state)
    )
  )
)

;; Claim rewards for many stakers of the same cycle (and bond) in one
;; transaction.
;;
;; Stakers with nothing to claim are skipped, so the caller can pass a whole
;; roster without knowing who is owed what. A failing payout aborts the whole
;; transaction.
(define-public (claim-staker-rewards-many
    (stakers (list 100 principal))
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (let (
      (unclaimed-rewards (var-get unclaimed-staker-rewards))
      (summary (try! (begin
        (try! (lock-cycle-mode reward-cycle bond-index MODE_POX_5))
        (fold fold-claim-staker-rewards stakers
          (ok {
            reward-cycle: reward-cycle,
            bond-index: bond-index,
            fee-bips: (get-fee-bips-for-cycle reward-cycle bond-index),
            unclaimed: unclaimed-rewards,
            has-liquidity: (has-sbtc-liquidity),
            total-earned: u0,
            total-fees: u0,
            claimed-count: u0,
          })
        )
      )))
    )
    (map-set cycle-mode {
      reward-cycle: reward-cycle,
      bond-index: bond-index,
    }
      MODE_POX_5
    )
    (var-set earned-fees (+ (var-get earned-fees) (get total-fees summary)))
    (var-set unclaimed-staker-rewards (get unclaimed summary))
    (ok {
      claimed: (get claimed-count summary),
      total-earned: (get total-earned summary),
      total-fees: (get total-fees summary),
    })
  )
)

;;; Locally-settled distribution
;;
;; The same payouts as `claim-staker-rewards-many`, but each staker's share is
;; computed from this contract's own mirror instead of from a pox-5 call. That
;; takes the per-staker cost off pox-5's ~135KB-per-call contract load, which is
;; ~99.7% of what a claim costs today.

;; Read-only view of what a staker is owed for a cycle under local settlement.
(define-read-only (get-local-staker-rewards
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (let (
      (total-shares (default-to u0
        (map-get? mirrored-total-shares {
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      ))
      (shares (default-to u0
        (map-get? mirrored-shares {
          staker: staker,
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      ))
      (accrued (default-to u0
        (map-get? cycle-rewards {
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      ))
      (already-paid (default-to u0
        (map-get? staker-paid {
          staker: staker,
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      ))
      ;; Floor division; the remainder stays in the contract and is swept as
      ;; dust, exactly as with pox-5-settled claims.
      (entitled (if (is-eq total-shares u0)
        u0
        (/ (* accrued shares) total-shares)
      ))
    )
    {
      entitled: entitled,
      already-paid: already-paid,
      claimable: (if (> entitled already-paid)
        (- entitled already-paid)
        u0
      ),
    }
  )
)

;; The one pox-5 call a local distribution makes.
;;
;; `signer-pending-staked-ustx-per-cycle` is the sum of this signer's stakers'
;; shares for the cycle: pox-5 moves it by the same amount as
;; `staker-shares-staked-for-cycle` on both the add and the remove path. (Its
;; sibling `signer-shares-staked-for-cycle` is NOT usable here -- pox-5 only
;; maintains that once the signer is over `SIGNER_SET_MIN_USTX`.)
;;
;; Because pox-5 never calls back on unstake, the mirror can only ever be too
;; high, so equality here is enough to prove it is exact.
(define-private (assert-mirror-matches-pox-5
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (ok (asserts!
    (is-eq
      (default-to u0
        (map-get? mirrored-total-shares {
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      )
      (match bond-index
        ;; Bond shares are moved on every add and remove, so the signer-level
        ;; total is the sum of its stakers' and compares directly.
        index
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          get-signer-shares-staked-for-cycle current-contract reward-cycle
          (some index)
        )
        ;; For STX staking that same map is only maintained once the signer is
        ;; over `SIGNER_SET_MIN_USTX`, so below the threshold it is not a sum of
        ;; its stakers. `signer-pending-staked-ustx-per-cycle` always is.
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          get-signer-pending-staked-ustx-per-cycle current-contract
          reward-cycle
        )
      ))
    ERR_SHARE_MIRROR_MISMATCH
  ))
)

;; Lock a cycle to one settlement path, rejecting the other from then on.
(define-private (lock-cycle-mode
    (reward-cycle uint)
    (bond-index (optional uint))
    (mode uint)
  )
  (ok (asserts!
    (is-eq mode
      (default-to mode
        (map-get? cycle-mode {
          reward-cycle: reward-cycle,
          bond-index: bond-index,
        })
      ))
    ERR_CYCLE_MODE_LOCKED
  ))
)

(define-private (fold-distribute-rewards
    (staker principal)
    (acc (response {
      reward-cycle: uint,
      bond-index: (optional uint),
      fee-bips: uint,
      unclaimed: uint,
      has-liquidity: bool,
      total-earned: uint,
      total-fees: uint,
      claimed-count: uint,
      transfers: (list 100
        {
          amount: uint,
          sender: principal,
          to: principal,
          memo: (optional (buff 34)),
        }
      ),
      transfer-total: uint,
    }
      uint
    ))
  )
  (let (
      (state (try! acc))
      (reward-cycle (get reward-cycle state))
      (bond-index (get bond-index state))
      (rewards (get-local-staker-rewards staker reward-cycle bond-index))
      (gross (get claimable rewards))
      (fees (/ (* gross (get fee-bips state)) MAX_BIPS))
      (earned (- gross fees))
    )
    (if (or
        (is-eq earned u0)
        (not (get has-liquidity state))
        (> gross (get unclaimed state))
      )
      (ok state)
      ;; Stakers taking sBTC are queued into a single `transfer-many` at the
      ;; end of the batch; only L1 withdrawals still cost a call each.
      (let ((queued (match (get-pox-addr staker)
          info (if (try! (pay-staker-l1 staker earned reward-cycle bond-index info))
            u1
            ;; L1 fee budget exceeds the reward: skip this staker.
            u0
          )
          (begin
            (print {
              topic: "claim-staker-rewards",
              amount-sats: earned,
              l1-withdrawal: none,
              staker: staker,
              reward-cycle: reward-cycle,
              bond-index: bond-index,
            })
            u2
          )
        )))
        (if (is-eq queued u0)
          (ok state)
          (begin
            ;; Only advance the watermark once the payout is committed.
            (map-set staker-paid {
              staker: staker,
              reward-cycle: reward-cycle,
              bond-index: bond-index,
            }
              (get entitled rewards)
            )
            (ok (merge state {
              unclaimed: (- (get unclaimed state) gross),
              total-earned: (+ (get total-earned state) earned),
              total-fees: (+ (get total-fees state) fees),
              claimed-count: (+ (get claimed-count state) u1),
              transfers: (if (is-eq queued u2)
                (unwrap-panic (as-max-len?
                  (append (get transfers state) {
                    amount: earned,
                    sender: current-contract,
                    to: staker,
                    memo: none,
                  })
                  u100
                ))
                (get transfers state)
              ),
              transfer-total: (if (is-eq queued u2)
                (+ (get transfer-total state) earned)
                (get transfer-total state)
              ),
            }))
          )
        )
      )
    )
  )
)

;; Distribute a cycle's rewards to many stakers without settling any of them
;; through pox-5. Costs one pox-5 call for the whole batch instead of one per
;; staker.
;;
;; STX staking only; bond rewards keep using `claim-staker-rewards-many`.
(define-public (distribute-rewards-many
    (stakers (list 100 principal))
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (let (
      (unclaimed-rewards (var-get unclaimed-staker-rewards))
      (summary (try! (begin
        (try! (lock-cycle-mode reward-cycle bond-index MODE_LOCAL))
        (try! (assert-mirror-matches-pox-5 reward-cycle bond-index))
        (fold fold-distribute-rewards stakers
          (ok {
            reward-cycle: reward-cycle,
            bond-index: bond-index,
            fee-bips: (get-fee-bips-for-cycle reward-cycle bond-index),
            unclaimed: unclaimed-rewards,
            has-liquidity: (has-sbtc-liquidity),
            total-earned: u0,
            total-fees: u0,
            claimed-count: u0,
            transfers: (list),
            transfer-total: u0,
          })
        )
      )))
    )
    ;; One sBTC call for every staker taking sBTC, instead of one each.
    (if (> (get transfer-total summary) u0)
      (try! (as-contract?
        ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          "sbtc-token" (get transfer-total summary)
        ))
        (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          transfer-many (get transfers summary)
        ))
      ))
      u0
    )
    (map-set cycle-mode {
      reward-cycle: reward-cycle,
      bond-index: bond-index,
    }
      MODE_LOCAL
    )
    (var-set earned-fees (+ (var-get earned-fees) (get total-fees summary)))
    (var-set unclaimed-staker-rewards (get unclaimed summary))
    (print {
      topic: "distribute-rewards-many",
      reward-cycle: reward-cycle,
      bond-index: bond-index,
      claimed: (get claimed-count summary),
      total-earned: (get total-earned summary),
      total-fees: (get total-fees summary),
    })
    (ok {
      claimed: (get claimed-count summary),
      total-earned: (get total-earned summary),
      total-fees: (get total-fees summary),
    })
  )
)

(define-trait swapper-trait (
  (swap
    (uint)
    (response uint uint)
  )
))

(define-public (claim-staker-rewards-stx
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
    (swapper <swapper-trait>)
  )
  (let ((claim-result (claim-staker-rewards staker reward-cycle bond-index)))
    (asserts! (is-ok claim-result) claim-result)
    (asserts! (is-eq contract-caller staker) ERR_UNAUTHORIZED_CALLER)
    (contract-call? swapper swap (unwrap-panic claim-result))
  )
)
;; Reclaim a REJECTED L1 withdrawal back to the staker who earned it.
;;
;; `claim-staker-rewards` initiates the sBTC withdrawal inside `as-contract?`,
;; meaning this contract is the withdrawal's requester. Any sBTC the sBTC
;; protocol returns for that request therefore goes to this contract, not the
;; staker whose pox-5 balance was already zeroed. Two cases:
;;   * REJECTED  -> the full `amount + max-fee` is unlocked back to the
;;                  requester. Fully reclaimable for the staker on-chain.
;;   * ACCEPTED  -> only the unused fee budget (`max-fee - actual-fee`) is
;;                  minted back. The actual fee is not exposed by the sBTC
;;                  registry, so this dust cannot be attributed to a single
;;                  staker; it is recovered via `sweep-fee-refunds`.
;;
;; Permissionless, mirroring `claim-staker-rewards`: anyone may trigger it on a
;; staker's behalf. The `withdrawal-requests` entry is deleted so the reclaim
;; cannot be replayed.
(define-public (reclaim-failed-withdrawal (request-id uint))
  (let (
      (staker (unwrap! (map-get? withdrawal-requests request-id)
        ERR_UNKNOWN_WITHDRAWAL_REQUEST
      ))
      (request (unwrap!
        (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry
          get-withdrawal-request request-id
        )
        ERR_UNKNOWN_WITHDRAWAL_REQUEST
      ))
      (refund (+ (get amount request) (get max-fee request)))
    )
    ;; `status` is `none` while pending and `(some true)` once accepted;
    ;; only `(some false)` (rejected) unlocks the full amount back here.
    (asserts! (is-eq (get status request) (some false))
      ERR_WITHDRAWAL_NOT_REJECTED
    )
    (map-delete withdrawal-requests request-id)
    ;; Request is settled: drop it from the outstanding staker liability.
    (var-set withdrawal-liability (- (var-get withdrawal-liability) refund))
    (print {
      topic: "reclaim-failed-withdrawal",
      request-id: request-id,
      staker: staker,
      amount-sats: refund,
    })
    (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        refund
      ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer refund tx-sender staker none
      ))
    )
  )
)

;; Settle an ACCEPTED L1 withdrawal.
;;
;; On acceptance the sBTC protocol pays the staker on L1 and mints only the
;; unused fee budget (`max-fee - actual-fee`) back to this contract as dust. No
;; staker payout is owed here, but the request is still counted in
;; `withdrawal-liability` (at its full `amount + max-fee`), which suppresses the
;; sweepable balance. This permissionless call retires the entry so that:
;;   * its liability is released, and
;;   * the accept-case dust it left behind becomes sweepable via
;;     `sweep-fee-refunds`.
;;
;; Mirrors `reclaim-failed-withdrawal` (permissionless, deletes the entry to
;; prevent replay) but for the accept case, where there is nothing to pay out.
(define-public (settle-accepted-withdrawal (request-id uint))
  (let (
      (staker (unwrap! (map-get? withdrawal-requests request-id)
        ERR_UNKNOWN_WITHDRAWAL_REQUEST
      ))
      (request (unwrap!
        (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry
          get-withdrawal-request request-id
        )
        ERR_UNKNOWN_WITHDRAWAL_REQUEST
      ))
      (liability (+ (get amount request) (get max-fee request)))
    )
    ;; `status` is `none` while pending and `(some false)` if rejected;
    ;; only `(some true)` (accepted) is settleable here. Rejected requests
    ;; must go through `reclaim-failed-withdrawal` so the staker is paid.
    (asserts! (is-eq (get status request) (some true))
      ERR_WITHDRAWAL_NOT_ACCEPTED
    )
    (map-delete withdrawal-requests request-id)
    ;; Request is settled: drop it from the outstanding staker liability.
    ;; The dust already minted to this contract stays in the balance and is
    ;; now sweepable.
    (var-set withdrawal-liability (- (var-get withdrawal-liability) liability))
    (print {
      topic: "settle-accepted-withdrawal",
      request-id: request-id,
      staker: staker,
      liability-released: liability,
    })
    (ok true)
  )
)

;;; Admin functions

;; Update the allowed admin principal, admin can't change own settings
(define-public (update-admin
    (admin principal)
    (enabled bool)
  )
  (begin
    (try! (authorize-admin))
    (asserts! (not (is-eq tx-sender admin)) ERR_UNAUTHORIZED_ADMIN)
    (print {
      topic: "update-admin",
      admin: admin,
      enabled: enabled,
    })
    (map-set admins admin enabled)
    (ok admin)
  )
)

;; Update the fees taken from rewards
(define-public (update-fees (new-fees uint))
  (begin
    (try! (authorize-admin))
    (asserts! (< new-fees MAX_BIPS) ERR_INVALID_FEES_BIPS)
    (print {
      topic: "update-fees",
      old-fees: (var-get fees-bips),
      new-fees: new-fees,
    })
    (var-set fees-bips new-fees)
    (ok true)
  )
)

;; Withdraw accrued admin fees from staker rewards.
(define-public (withdraw-fees
    (amount uint)
    (recipient principal)
  )
  (let ((fees (var-get earned-fees)))
    (try! (authorize-admin))
    (asserts! (<= amount fees) ERR_INSUFFICIENT_FEES)
    (var-set earned-fees (- fees amount))
    (try! (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        amount
      ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer amount tx-sender recipient none
      ))
    ))
    (ok amount)
  )
)

;; Sweep orphaned sBTC fee-refund dust to a recipient.
;;
;; On an ACCEPTED withdrawal the sBTC protocol mints the unused fee budget
;; (`max-fee - actual-fee`) back to this contract. That dust cannot be
;; attributed to a specific staker on-chain (the sBTC registry does not expose
;; the actual fee paid), so it pools here; this admin-gated function sweeps it.
;;
;; The full sweepable amount is taken: the sBTC balance minus the fee
;; accumulator (`earned-fees`), the outstanding `withdrawal-liability`, and the
;; pooled `unclaimed-staker-rewards` that `claim-rewards` pulled in but no staker
;; has claimed yet, so it can NEVER sweep funds owed to a staker. A
;; rejected-but-unreclaimed withdrawal's `amount + max-fee` is present in BOTH
;; the sBTC balance (the protocol returned it here) and in
;; `withdrawal-liability` (the entry is still live), so the two cancel and the
;; refund stays untouchable, whether or not anyone has called
;; `reclaim-failed-withdrawal` yet.
;;
;; The flip side: while a withdrawal is pending, or accepted but not yet retired
;; via `settle-accepted-withdrawal`, its full `amount + max-fee` suppresses the
;; sweepable amount. To recover the accept-case fee dust an admin must first
;; `settle-accepted-withdrawal` the accepted requests (and wait for any pending
;; ones to finalize).
(define-public (sweep-fee-refunds (recipient principal))
  (let (
      (balance (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        get-balance current-contract
      )))
      (reserved (+ (var-get earned-fees) (var-get withdrawal-liability)
        (var-get unclaimed-staker-rewards)
      ))
      (sweepable (if (>= balance reserved)
        (- balance reserved)
        u0
      ))
    )
    (try! (authorize-admin))
    (asserts! (> sweepable u0) ERR_NO_REFUNDS)
    (print {
      topic: "sweep-fee-refunds",
      amount-sats: sweepable,
      recipient: recipient,
    })
    (try! (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        sweepable
      ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer sweepable tx-sender recipient none
      ))
    ))
    (ok sweepable)
  )
)

;; As an admin, register this contract with a specific signer key. The signer key grant
;; must not have been used yet.
(define-public (register-self
    (signer-manager <signer-manager-trait>)
    (signer-key (buff 33))
    (auth-id uint)
    (signer-sig (buff 65))
  )
  (begin
    (try! (authorize-admin))
    (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5 grant-signer-key
      signer-key current-contract auth-id signer-sig
    ))
    (contract-call? 'ST000000000000000000002AMW42H.pox-5 register-signer
      signer-manager signer-key
    )
  )
)

(define-private (authorize-admin)
  (ok (asserts! (and (is-eq contract-caller tx-sender) (is-admin tx-sender))
    ERR_UNAUTHORIZED_ADMIN
  ))
)

;; Ensure that the immediate caller is the pox-5 contract. The trait callbacks
;; (validate-stake!) write per-staker state keyed by the
;; `staker` argument; they must only ever be driven by pox-5, never invoked
;; directly by an external principal.
(define-private (authorize-pox-5)
  (ok (asserts! (is-eq contract-caller 'ST000000000000000000002AMW42H.pox-5)
    ERR_UNAUTHORIZED_CALLER
  ))
)

(define-read-only (is-admin (caller principal))
  (default-to false (map-get? admins caller))
)

(define-private (snapshot-bond-fee
    (bond-info {
      bond-index: uint,
      earned: uint,
      rewards-per-token: uint,
    })
    (reward-cycle uint)
  )
  (begin
    (map-insert fee-bips-for-cycle {
      reward-cycle: reward-cycle,
      bond-index: (some (get bond-index bond-info)),
    }
      (var-get fees-bips)
    )
    ;; Same per-cycle pot tracking as STX staking, but per bond.
    (map-set cycle-rewards {
      reward-cycle: reward-cycle,
      bond-index: (some (get bond-index bond-info)),
    }
      (+
        (default-to u0
          (map-get? cycle-rewards {
            reward-cycle: reward-cycle,
            bond-index: (some (get bond-index bond-info)),
          })
        )
        (get earned bond-info)
      ))
    reward-cycle
  )
)

(define-read-only (get-fee-bips-for-cycle
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (default-to u0
    (map-get? fee-bips-for-cycle {
      reward-cycle: reward-cycle,
      bond-index: bond-index,
    })
  )
)

(define-read-only (get-earned-fees)
  (var-get earned-fees)
)

(define-read-only (get-withdrawal-liability)
  (var-get withdrawal-liability)
)

(define-read-only (get-unclaimed-staker-rewards)
  (var-get unclaimed-staker-rewards)
)

(define-read-only (get-pox-addr (staker principal))
  (map-get? pox-addrs staker)
)

(define-read-only (get-withdrawal-request-staker (withdrawal-request uint))
  (map-get? withdrawal-requests withdrawal-request)
)

(define-read-only (check-pox-addr (pox-addr {
  version: (buff 1),
  hashbytes: (buff 32),
}))
  (let (
      (version (buff-to-uint-be (get version pox-addr)))
      (expected-len (if (<= version MAX_ADDRESS_VERSION_BUFF_20)
        u20
        u32
      ))
    )
    (ok (asserts!
      (and
        (<= version MAX_ADDRESS_VERSION)
        (is-eq (len (get hashbytes pox-addr)) expected-len)
        (is-eq (len (get version pox-addr)) u1)
      )
      ERR_INVALID_POX_ADDR
    ))
  )
)
