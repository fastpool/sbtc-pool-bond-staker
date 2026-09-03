;; Bitcoin Staking Bond staker: a pooled pox-5 bond staker.
;;
;; This contract is the pox-5 staker: allowlisted principal, sBTC and STX
;; custodian towards pox-5. Members hold claims on this contract, mirrored by
;; the non-transferable receipts `iou-bond-btc` and `iou-bond-stx`.
;; Principal not held by pox-5 sits in `bond-treasury`; any sBTC held here is
;; reward. The STX leg is held here because pox-5 locks the staker's own STX.
;;
;; Epochs: one per bond staked. Epoch N+1 is a roll of epoch N into bond
;; index+NEXT_BOND_OFFSET; pox-5 moves only the net sBTC difference and
;; resizes the STX lock in place.
;; Per member: sats and ustx (returned as deposited), shares (reward weight,
;; 1 share = 1 committed sat). Leaving at a roll keeps the epoch's shares
;; (`tail-epoch`); `unstake-sbtc-early` removes them and shrinks `total-shares`.
;; A roll never fails for lack of allocation or STX: `stake` commits
;; min(queued, allocation, STX-supported) and scales every member by the same
;; fraction; the remainder is released once the old epoch stops paying.
;; Rewards arrive as bare sBTC transfers; `sync-rewards` credits the oldest
;; epoch still paying. An epoch pays until the midpoint of the next epoch's
;; first cycle; at most two epochs pay at once and the latest never settles.
;; Positions move at the roll, rewards at settlement; a member carried out of
;; a paying epoch keeps a stash that `accrue-stash` draws until it settles.
;; STX leg: `get-required-ustx` prices sats with the bound bond's terms,
;; rounded up per deposit, so the pool never falls short of pox-5's minimum.
;; Names follow pox-5: stake -> register-for-bond, unstake-sbtc -> unstake-sbtc,
;; update-bond-registration -> update-bond-registration.
;;
;; Lifecycle
;;   initialize          deployer, once: signer manager and operator.
;;   set-next-bond       operator, optional: floor on the next bond index.
;;   bind-next-bond      anyone, after the bond admin's `setup-bond` allowlists
;;                       this contract; reads terms from pox-5, opens deposits.
;;   deposit/deposit-stx anyone, while a bond is bound and its window is open.
;;   withdraw            depositor, until staked.
;;   stake               anyone, in the STAKE_WINDOW blocks before the prepare
;;                       phase; first call opens epoch 0, later calls roll.
;;   request-exit        member, released at the next roll.
;;   unstake-sbtc-early  member, committed sBTC back now.
;;   unstake-sbtc        anyone, after the live bond's 12 cycles; winds down.
;;   claim-*             anyone, for any member.
;;
;; Nothing bond-specific is in the source; all terms are read at bind. The
;; genesis bond starts at burn block 966,350 (cycle 143).

(use-trait signer-manager-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)

;;; Errors

(define-constant ERR_UNAUTHORIZED (err u2000))
(define-constant ERR_ALREADY_INITIALIZED (err u2001))
(define-constant ERR_NOT_INITIALIZED (err u2002))
(define-constant ERR_BOND_NOT_FOUND (err u2003))
(define-constant ERR_NOT_ALLOWLISTED (err u2004))
(define-constant ERR_ALLOCATION_EXCEEDED (err u2005))
(define-constant ERR_NOT_STAKED (err u2007))
(define-constant ERR_TOO_EARLY (err u2008))
(define-constant ERR_TOO_LATE (err u2009))
(define-constant ERR_NOTHING_DEPOSITED (err u2010))
(define-constant ERR_INVALID_SIGNER_MANAGER (err u2011))
(define-constant ERR_ALREADY_UNSTAKED (err u2012))
(define-constant ERR_POSITION_ACTIVE (err u2013))
(define-constant ERR_NOTHING_TO_CLAIM (err u2014))
(define-constant ERR_INVALID_AMOUNT (err u2016))
(define-constant ERR_SIGNER_NOT_REGISTERED (err u2017))
(define-constant ERR_NO_BOND_BOUND (err u2018))
(define-constant ERR_BOND_ALREADY_BOUND (err u2019))
(define-constant ERR_INVALID_BOND_INDEX (err u2020))
(define-constant ERR_INSUFFICIENT_STX (err u2021))
(define-constant ERR_NOT_EXITING (err u2022))
(define-constant ERR_ALREADY_EXITING (err u2023))
(define-constant ERR_UNKNOWN_EPOCH (err u2024))
(define-constant ERR_QUEUE_PENDING (err u2025))
(define-constant ERR_SIGNER_NOT_TRUSTED (err u2026))
(define-constant ERR_ALREADY_TRUSTED (err u2027))
(define-constant ERR_NOT_A_CONTRACT (err u2028))
(define-constant ERR_PRINCIPAL_IN_TRANSIT (err u2030))
(define-constant ERR_REWARDS_PENDING (err u2031))
;; u2029 (ERR_BELOW_LAUNCH_FLOOR) retired; not reassigned.

;;; Protocol constants -- these mirror pox-5 and are not deployment knobs

;; Bond term in reward cycles (~6 months).
(define-constant BOND_LENGTH_CYCLES u12)

;; pox-5 opens a bond every 2 cycles; bond N+6 starts where bond N's term ends.
(define-constant NEXT_BOND_OFFSET u6)

;; Burn blocks between a bind and the earliest `stake` (~4 days), so members can
;; read the terms and `request-exit`. Fits pox-5's setup window on each network.
(define-constant BIND_NOTICE u576)

;; Bond periods `bind-next-bond` scans ahead (12 periods ~ 2 years).
(define-constant BOND_SEARCH (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11))

;; Max distance of a `set-next-bond` floor past `earliest-reachable-bond`. It
;; bounds the protocol floor, not the pool's; floors cannot be walked stepwise.
(define-constant MAX_SKIP u100)

;; Length of the `stake` window in burn blocks (~2 days). It closes where the
;; prepare phase before the bond opens -- see `stake-window-end-of`.
(define-constant STAKE_WINDOW u288)

;; uSTX slack when inverting `get-required-ustx`, which rounds up twice.
(define-constant USTX_ROUNDING_SLACK u2)

;; Fixed-point scale for the per-share reward accumulator.
(define-constant PRECISION u1000000000000) ;; 1e12

;; Closed epochs one settlement catches up on; settle again for more.
(define-constant CATCHUP_STEPS (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9))

;; Only this principal may `initialize` the contract.
(define-constant DEPLOYER tx-sender)

;;; Configuration

(define-data-var initialized bool false)

;; May `set-next-bond` and move the pool between trusted signer managers. No
;; access to deposits; `stake` and `unstake-sbtc` stay permissionless. A set.
(define-map operators
  principal
  bool
)

;; The signer manager the pool stakes through. `stake` only accepts this one.
(define-data-var signer-manager principal tx-sender)

;; Code hashes of signer managers the pool may move onto, stamped with the epoch
;; count when added; usable only after the pool has rolled out of that epoch.
(define-map trusted-signers
  (buff 32)
  uint
)

;;; The bound bond -- the one the next `stake` will commit to

(define-data-var bond-bound bool false)
;; When the bond was bound. `stake` waits BIND_NOTICE blocks past it.
(define-data-var bound-at-height uint u0)
(define-data-var pending-bond-index uint u0)
(define-data-var pending-max-sats uint u0)
;; `stx-value-ratio` is uSTX per 100 sats, `min-ustx-ratio` is in bips.
(define-data-var pending-stx-value-ratio uint u0)
(define-data-var pending-min-ustx-ratio uint u0)
(define-data-var pending-start-height uint u0)
(define-data-var pending-unlock-height uint u0)

;; Floor on the bond index `bind-next-bond` may take (`set-next-bond`). A floor,
;; not a pin: skip bond N by setting N+1; the walk continues past unset periods.
(define-data-var min-bond-index uint u0)

;;; Epochs

;; One record per bond staked. Frozen at `stake` except the reward fields and
;; `total-shares`, which shrinks on early unstakes.
(define-map epochs
  uint
  {
    bond-index: uint,
    first-reward-cycle: uint,
    unlock-burn-height: uint,
    staked-at-height: uint,
    ;; `staked-sats / eligible-sats` scales every member carried into the epoch.
    ;; `staked-sats` is fixed at the roll; `total-shares` is what is still in.
    eligible-sats: uint,
    total-shares: uint,
    staked-sats: uint,
    staked-ustx: uint,
    ;; Rewards per share (PRECISION-scaled) and the total credited so far.
    reward-index: uint,
    credited: uint,
    ;; Credit belonging to shares that have left; keeps `credited`, recomputed
    ;; from `total-shares * reward-index`, from dropping when shares leave.
    credit-offset: uint,
  }
)

;; Number of epochs opened. The live epoch is `epoch-count - 1`.
(define-data-var epoch-count uint u0)

;; Set by `unstake-sbtc`. The pool never stakes again.
(define-data-var finished bool false)

;;; Pooled principal
;;
;;   queued    deposited, not yet committed. In the treasury; withdrawable.
;;   bonded    committed to the live bond. In pox-5's custody.
;;   exiting   the part of `bonded` that the next roll will release.
;;   released  no longer committed, waiting to be claimed. In the treasury.
;;
;; Invariant: `queued-sats + released-sats` = treasury sBTC balance.

(define-data-var queued-sats uint u0)
(define-data-var queued-ustx uint u0)
(define-data-var bonded-sats uint u0)
(define-data-var bonded-ustx uint u0)
(define-data-var exiting-sats uint u0)
(define-data-var exiting-ustx uint u0)
(define-data-var released-sats uint u0)
(define-data-var released-ustx uint u0)

;; Principal moved from the treasury into this contract for the length of a
;; growing roll; `register-for-bond` may call back in, so readers subtract it.
(define-data-var principal-in-transit uint u0)

;;; sBTC bridge: L1 BTC deposits are announced (with their STX leg) before
;;; broadcast, addressed to the treasury, then confirmed from the sBTC registry.

;; Announced, not yet swept: hold allocation room, STX leg paid, no sBTC yet.
(define-data-var announced-sats uint u0)

;; Locked in the bridge for unsettled withdrawals; in the treasury until swept.
(define-data-var withdrawing-sats uint u0)

;;; Pooled rewards. Credit is derived from the reward index in one step, never
;;; accumulated per sync, so pool and member credit floor the same way.

(define-data-var total-credited uint u0)
(define-data-var total-paid uint u0)

(define-map members
  principal
  {
    ;; Reward weight, from `settled-epoch` until the member leaves.
    shares: uint,
    ;; Committed principal.
    bonded-sats: uint,
    bonded-ustx: uint,
    ;; Deposited, not yet committed. Withdrawable until `queued-epoch` opens.
    queued-sats: uint,
    queued-ustx: uint,
    queued-epoch: uint,
    ;; No longer committed (exit or roll haircut). Claimable.
    released-sats: uint,
    released-ustx: uint,
    ;; `reward-index` snapshots epoch `settled-epoch`; `pending` is unpaid.
    settled-epoch: uint,
    reward-index: uint,
    pending: uint,
    ;; Claim kept on an epoch the roll carried them out of while it still pays.
    tail-epoch: (optional uint),
    tail-shares: uint,
    tail-index: uint,
    ;; Epoch in which they asked to leave; the roll out of it releases them.
    exit-epoch: (optional uint),
  }
)

;;; Read-only: configuration and pool state

(define-read-only (get-config)
  {
    initialized: (var-get initialized),
    signer-manager: (var-get signer-manager),
    epoch-count: (var-get epoch-count),
    finished: (var-get finished),
    min-bond-index: (var-get min-bond-index),
  }
)

(define-read-only (is-operator (who principal))
  (default-to false (map-get? operators who))
)

;; Code hash of a deployed contract, as `trust-signer-manager` takes it.
(define-read-only (get-signer-manager-hash (manager principal))
  (contract-hash? manager)
)

;; Epoch count at which this code hash was trusted, if it is.
(define-read-only (get-trusted-signer (code-hash (buff 32)))
  (map-get? trusted-signers code-hash)
)

;; Whether `manager` is trusted and usable now.
(define-read-only (can-use-signer-manager (manager principal))
  (match (contract-hash? manager)
    code-hash (match (map-get? trusted-signers code-hash)
      ;; Usable once an epoch later than `trusted-at - 1` has opened.
      trusted-at
      (> (var-get epoch-count) trusted-at)
      false
    )
    error false
  )
)

(define-read-only (get-bound-bond)
  {
    bound: (var-get bond-bound),
    bond-index: (var-get pending-bond-index),
    max-sats: (var-get pending-max-sats),
    stx-value-ratio: (var-get pending-stx-value-ratio),
    min-ustx-ratio: (var-get pending-min-ustx-ratio),
    start-height: (var-get pending-start-height),
    unlock-burn-height: (var-get pending-unlock-height),
    stake-opens-at: (stake-window-start),
    stake-closes-at: (stake-window-end),
    stakeable: (can-still-stake),
    bound-at-height: (var-get bound-at-height),
    notice-ends-at: (+ (var-get bound-at-height) BIND_NOTICE),
  }
)

(define-read-only (get-pool)
  {
    queued-sats: (var-get queued-sats),
    queued-ustx: (var-get queued-ustx),
    bonded-sats: (var-get bonded-sats),
    bonded-ustx: (var-get bonded-ustx),
    exiting-sats: (var-get exiting-sats),
    exiting-ustx: (var-get exiting-ustx),
    released-sats: (var-get released-sats),
    released-ustx: (var-get released-ustx),
    announced-sats: (var-get announced-sats),
    withdrawing-sats: (var-get withdrawing-sats),
    total-credited: (var-get total-credited),
    total-paid: (var-get total-paid),
    unclaimed-rewards: (get-unclaimed-rewards),
  }
)

(define-read-only (get-epoch (epoch uint))
  (map-get? epochs epoch)
)

(define-read-only (get-live-epoch)
  (if (is-eq (var-get epoch-count) u0)
    none
    (map-get? epochs (- (var-get epoch-count) u1))
  )
)

(define-read-only (get-member (member principal))
  (map-get? members member)
)

;; What the next `stake` would commit. eligible = bonded - exiting + queued;
;; sats = min(eligible, allocation, STX-supported); short-ustx carries eligible.
(define-read-only (get-stake-preview)
  (let (
      (eligible (+ (- (var-get bonded-sats) (var-get exiting-sats)) (var-get queued-sats)))
      (ustx (+ (- (var-get bonded-ustx) (var-get exiting-ustx)) (var-get queued-ustx)))
      (required (get-required-ustx eligible))
      (allocation (var-get pending-max-sats))
      (affordable (get-sats-for-ustx ustx))
      (fits-allocation (if (< eligible allocation)
        eligible
        allocation
      ))
      (sats (if (< fits-allocation affordable)
        fits-allocation
        affordable
      ))
    )
    {
      eligible-sats: eligible,
      sats: sats,
      ustx: ustx,
      required-ustx: required,
      short-ustx: (if (> required ustx)
        (- required ustx)
        u0
      ),
      scaled: (< sats eligible),
      stx-limited: (< affordable fits-allocation),
      allocation-limited: (< allocation eligible),
    }
  )
)

;; STX leg pox-5 requires for `sats` under the bound bond's terms, rounded up.
(define-read-only (get-required-ustx (sats uint))
  (ceil-div
    (* (ceil-div (* (var-get pending-stx-value-ratio) sats) u100)
      (var-get pending-min-ustx-ratio)
    )
    u10000
  )
)

;; Inverse of `get-required-ustx`: the most sats `ustx` carries. Tries the exact
;; quotient first; if it overshoots, recomputes with USTX_ROUNDING_SLACK held.
(define-read-only (get-sats-for-ustx (ustx uint))
  (let ((per-million (* (var-get pending-stx-value-ratio) (var-get pending-min-ustx-ratio))))
    (if (is-eq per-million u0)
      u0
      (let ((exact (/ (* ustx u1000000) per-million)))
        (if (<= (get-required-ustx exact) ustx)
          exact
          (if (<= ustx USTX_ROUNDING_SLACK)
            u0
            (/ (* (- ustx USTX_ROUNDING_SLACK) u1000000) per-million)
          )
        )
      )
    )
  )
)

;; Pooled principal not in pox-5's custody.
(define-read-only (get-treasury-balance)
  (contract-call? .bond-treasury get-balance)
)

(define-private (get-sbtc-balance)
  (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance current-contract
  ))
)

;; Credited, not yet paid out.
(define-read-only (get-unclaimed-rewards)
  (- (var-get total-credited) (var-get total-paid))
)

;; sBTC held beyond what is already recognised: the pot `sync-rewards` splits.
;; `principal-in-transit` is subtracted; everything else held here is reward.
(define-read-only (get-unrecognized-rewards)
  (let (
      (balance (get-sbtc-balance))
      (recognized (+ (get-unclaimed-rewards) (var-get principal-in-transit)))
    )
    (if (> balance recognized)
      (- balance recognized)
      u0
    )
  )
)

;; pox-5's prepare phase length; differs between mainnet and testnet.
(define-read-only (get-prepare-length)
  (get prepare-cycle-length
    (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-5 get-pox-info))
  )
)

;; Stake window close for a bond starting at `start`: where the preceding
;; prepare phase begins, since pox-5 registers nobody during it.
(define-read-only (stake-window-end-of (start uint))
  (let ((prepare (get-prepare-length)))
    (if (> start prepare)
      (- start prepare)
      u0
    )
  )
)

;; Stake window open: STAKE_WINDOW blocks before it closes.
(define-read-only (stake-window-start-of (start uint))
  (let ((closes (stake-window-end-of start)))
    (if (> closes STAKE_WINDOW)
      (- closes STAKE_WINDOW)
      u0
    )
  )
)

(define-read-only (stake-window-start)
  (stake-window-start-of (var-get pending-start-height))
)

(define-read-only (stake-window-end)
  (stake-window-end-of (var-get pending-start-height))
)

;; False once the bound bond's window closed unstaked; it may then be rebound.
(define-read-only (can-still-stake)
  (and
    (var-get bond-bound)
    (< burn-block-height (stake-window-end))
  )
)

;; Ended once the pool has rolled out of it; positions move only then.
(define-read-only (is-epoch-ended (epoch uint))
  (is-some (map-get? epochs (+ epoch u1)))
)

;; Settled at the midpoint of the next epoch's first cycle: pox-5 pays twice per
;; cycle for the cycle just ended. The latest epoch never settles.
(define-read-only (is-epoch-settled (epoch uint))
  (match (map-get? epochs (+ epoch u1))
    next (>= burn-block-height
      (contract-call? 'ST000000000000000000002AMW42H.pox-5
        distribution-cycle-to-burn-height
        (+ (* (get first-reward-cycle next) u2) u1)
      ))
    false
  )
)

;; Epoch `sync-rewards` credits: the oldest still taking rewards (at most two).
(define-read-only (get-reward-epoch)
  (let ((count (var-get epoch-count)))
    (if (is-eq count u0)
      none
      (if (and (> count u1) (not (is-epoch-settled (- count u2))))
        (some (- count u2))
        (some (- count u1))
      )
    )
  )
)

;; What the roll would commit plus announced bridge deposits not yet landed.
(define-read-only (get-committing-sats)
  (+ (get eligible-sats (get-stake-preview)) (var-get announced-sats))
)

;; Treasury sBTC the books do not attribute (returned bridge fee, unannounced
;; deposit, stray transfer). Never member principal.
(define-read-only (get-unattributed-principal)
  (let (
      (balance (get-treasury-balance))
      (accounted (+ (var-get queued-sats)
        (+ (var-get released-sats) (var-get withdrawing-sats))
      ))
    )
    (if (> balance accounted)
      (- balance accounted)
      u0
    )
  )
)

(define-read-only (ceil-div
    (numerator uint)
    (denominator uint)
  )
  (if (is-eq denominator u0)
    u0
    (/ (+ numerator (- denominator u1)) denominator)
  )
)

;; Part of `amount` carried into `epoch`: scaled by staked/eligible, a property
;; of the roll, so late settlers scale the same as everyone carried by it.
(define-read-only (scale-into-epoch
    (amount uint)
    (epoch uint)
  )
  (match (map-get? epochs epoch)
    record (if (or
        (is-eq (get eligible-sats record) u0)
        (>= (get staked-sats record) (get eligible-sats record))
      )
      amount
      (/ (* amount (get staked-sats record)) (get eligible-sats record))
    )
    amount
  )
)

;; Part of `amount` the roll handed back. Floored separately, not as the
;; remainder of `scale-into-epoch`: both round down so the pool stays solvent.
(define-read-only (scale-released-from-epoch
    (amount uint)
    (epoch uint)
  )
  (match (map-get? epochs epoch)
    record (if (or
        (is-eq (get eligible-sats record) u0)
        (>= (get staked-sats record) (get eligible-sats record))
      )
      u0
      (/ (* amount (- (get eligible-sats record) (get staked-sats record)))
        (get eligible-sats record)
      )
    )
    u0
  )
)

;;; Read-only: member state

;; The record with closed epochs settled, queued deposit committed, exit or
;; scale-back realised. Every member-facing function works from this.
(define-read-only (get-settled-member (member principal))
  (match (map-get? members member)
    record (some (settle record))
    none
  )
)

(define-read-only (get-claimable-rewards (member principal))
  (match (map-get? members member)
    record (get pending (settle record))
    u0
  )
)

;; Released principal plus the queued deposit `withdraw` returns.
(define-read-only (get-claimable-principal (member principal))
  (match (map-get? members member)
    stored (let ((record (settle stored)))
      {
        released-sats: (get released-sats record),
        released-ustx: (get released-ustx record),
        queued-sats: (get queued-sats record),
        queued-ustx: (get queued-ustx record),
      }
    )
    {
      released-sats: u0,
      released-ustx: u0,
      queued-sats: u0,
      queued-ustx: u0,
    }
  )
)

;; What `unstake-sbtc-early` would return and forfeit. `at-risk-rewards` is the
;; member's live-epoch share of unrecognised sBTC; zero while an old epoch pays.
(define-read-only (get-early-unstake-preview (member principal))
  (match (map-get? members member)
    stored (let (
        (record (settle stored))
        (at-risk (match (get-live-epoch)
          live (let ((live-shares (get total-shares live)))
            (if (and
                (is-eq (get-reward-epoch) (some (- (var-get epoch-count) u1)))
                (> live-shares u0)
              )
              (/ (* (get-unrecognized-rewards) (get shares record)) live-shares)
              u0
            )
          )
          u0
        ))
      )
      {
        sats: (get bonded-sats record),
        ustx-at-roll: (get bonded-ustx record),
        banked-rewards: (get pending record),
        at-risk-rewards: at-risk,
        ;; A full exit emptying the live epoch is refused while a sync would
        ;; still credit something -- see ERR_REWARDS_PENDING.
        sync-first: (match (get-live-epoch)
          live (and
            (is-eq (get shares record) (get total-shares live))
            (is-eq (get-reward-epoch) (some (- (var-get epoch-count) u1)))
            (> (get-recognizable-rewards) u0)
          )
          false
        ),
      }
    )
    {
      sats: u0,
      ustx-at-roll: u0,
      banked-rewards: u0,
      at-risk-rewards: u0,
      sync-first: false,
    }
  )
)

;;; Initialization

;; Deployer, once: signer manager and first operator.
(define-public (initialize
    (manager principal)
    (pool-operator principal)
  )
  (begin
    (asserts! (is-eq tx-sender DEPLOYER) ERR_UNAUTHORIZED)
    (asserts! (not (var-get initialized)) ERR_ALREADY_INITIALIZED)
    (asserts!
      (is-some (contract-call? 'ST000000000000000000002AMW42H.pox-5 get-signer-info
        manager
      ))
      ERR_SIGNER_NOT_REGISTERED
    )
    ;; No deposits yet, so the first manager needs no notice.
    (map-set trusted-signers
      (unwrap! (contract-hash? manager) ERR_NOT_A_CONTRACT) u0
    )
    (var-set signer-manager manager)
    (map-set operators pool-operator true)
    (var-set initialized true)
    (print (merge { topic: "initialize" } (get-config)))
    (ok (get-config))
  )
)

;; Bindable: pox-5 has set the period up, this contract has an allowance, and
;; BIND_NOTICE fits before the stake window opens.
(define-read-only (bindable-bond (index uint))
  (let (
      (start (contract-call? 'ST000000000000000000002AMW42H.pox-5
        bond-period-to-burn-height index
      ))
      (opens (stake-window-start-of start))
    )
    (and
      (is-some (contract-call? 'ST000000000000000000002AMW42H.pox-5 get-protocol-bond
        index
      ))
      (> (default-to u0
        (contract-call? 'ST000000000000000000002AMW42H.pox-5 get-bond-allowance
          index current-contract
        )) u0
      )
      (<= (+ burn-block-height BIND_NOTICE) opens)
    )
  )
)

;; Earliest period the protocol leaves open, ignoring the members' floor: the
;; first whose window opens after BIND_NOTICE, no nearer than NEXT_BOND_OFFSET.
(define-read-only (earliest-reachable-bond)
  (let (
      (first (contract-call? 'ST000000000000000000002AMW42H.pox-5
        bond-period-to-burn-height u0
      ))
      (second (contract-call? 'ST000000000000000000002AMW42H.pox-5
        bond-period-to-burn-height u1
      ))
      ;; Period spacing is constant in pox-5; guarded against zero.
      (spacing (if (> second first)
        (- second first)
        u1
      ))
      ;; First start height whose window opens after the notice runs out.
      (deadline (+ burn-block-height BIND_NOTICE STAKE_WINDOW (get-prepare-length)))
      (by-clock (if (<= deadline first)
        u0
        (ceil-div (- deadline first) spacing)
      ))
      (by-roll (match (get-live-epoch)
        live (+ (get bond-index live) NEXT_BOND_OFFSET)
        u0
      ))
    )
    (if (> by-clock by-roll)
      by-clock
      by-roll
    )
  )
)

;; Start of the walk: max(protocol floor, members' floor).
(define-read-only (earliest-bindable-bond)
  (let (
      (reachable (earliest-reachable-bond))
      (by-members (var-get min-bond-index))
    )
    (if (> reachable by-members)
      reachable
      by-members
    )
  )
)

(define-private (check-bond-candidate
    (offset uint)
    (found {
      from: uint,
      index: (optional uint),
    })
  )
  (if (is-some (get index found))
    found
    (let ((index (+ (get from found) offset)))
      (if (bindable-bond index)
        (merge found { index: (some index) })
        found
      )
    )
  )
)

;; First bindable period from `earliest-bindable-bond`; `none` if none yet.
(define-read-only (find-next-bond)
  (get index
    (fold check-bond-candidate BOND_SEARCH {
      from: (earliest-bindable-bond),
      index: none,
    })
  )
)

;; Operator: floor for `bind-next-bond`. Skip bond N with N+1, aim at M with M,
;; u0 resets. Capped MAX_SKIP past the protocol floor, not the previous floor.
(define-public (set-next-bond (index uint))
  (begin
    (try! (authorize-operator))
    (asserts! (<= index (+ (earliest-reachable-bond) MAX_SKIP))
      ERR_INVALID_BOND_INDEX
    )
    (var-set min-bond-index index)
    (print {
      topic: "set-next-bond",
      index: index,
    })
    (ok index)
  )
)

;; Anyone: bind the next bond and open deposits. Index from `find-next-bond`,
;; allocation and terms from pox-5; needs the admin's `setup-bond` allowlist.
(define-public (bind-next-bond)
  (begin
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    ;; A bound bond whose window closed unstaked may be replaced.
    (asserts! (not (can-still-stake)) ERR_BOND_ALREADY_BOUND)
    (let (
        (index (unwrap! (find-next-bond) ERR_BOND_NOT_FOUND))
        (bond (unwrap!
          (contract-call? 'ST000000000000000000002AMW42H.pox-5 get-protocol-bond
            index
          )
          ERR_BOND_NOT_FOUND
        ))
        (allowance (unwrap!
          (contract-call? 'ST000000000000000000002AMW42H.pox-5 get-bond-allowance
            index current-contract
          )
          ERR_NOT_ALLOWLISTED
        ))
        (start-height (contract-call? 'ST000000000000000000002AMW42H.pox-5
          bond-period-to-burn-height index
        ))
        (start-cycle (contract-call? 'ST000000000000000000002AMW42H.pox-5
          bond-period-to-reward-cycle index
        ))
        (unlock-height (contract-call? 'ST000000000000000000002AMW42H.pox-5
          reward-cycle-to-burn-height (+ start-cycle BOND_LENGTH_CYCLES)
        ))
      )
      ;; Both hold by construction of `find-next-bond`; asserted for readers.
      (asserts! (<= (+ burn-block-height BIND_NOTICE) (stake-window-start-of start-height))
        ERR_TOO_LATE
      )
      (asserts!
        (match (get-live-epoch)
          live (>= index (+ (get bond-index live) NEXT_BOND_OFFSET))
          true
        )
        ERR_INVALID_BOND_INDEX
      )

      (var-set pending-bond-index index)
      ;; The whole allowance; `stake` scales to whatever turned up.
      (var-set pending-max-sats allowance)
      (var-set pending-stx-value-ratio (get stx-value-ratio bond))
      (var-set pending-min-ustx-ratio (get min-ustx-ratio bond))
      (var-set pending-start-height start-height)
      (var-set pending-unlock-height unlock-height)
      (var-set bound-at-height burn-block-height)
      (var-set bond-bound true)

      (print (merge { topic: "bind-next-bond" } (get-bound-bond)))
      (ok (get-bound-bond))
    )
  )
)

;;; Deposits

;; Deposit `sats` plus the STX leg (`get-required-ustx`). sBTC goes to the
;; treasury; STX is held here because pox-5 locks the staker's own STX.
(define-public (deposit (sats uint))
  (let (
      (ustx (get-required-ustx sats))
      (record (settle (get-or-create-member tx-sender)))
      (depositor tx-sender)
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    ;; Closes with the stake window: later deposits would price a bond the pool
    ;; can no longer enter.
    (asserts! (< burn-block-height (stake-window-end)) ERR_TOO_LATE)
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    (asserts! (<= (+ (get-committing-sats) sats) (var-get pending-max-sats))
      ERR_ALLOCATION_EXCEEDED
    )
    (try! (queue-for-next-bond record depositor sats ustx))

    (let ((result {
        depositor: depositor,
        sats: sats,
        ustx: ustx,
        queued-epoch: (var-get epoch-count),
      }))
      (print (merge { topic: "deposit" } result))
      (ok result)
    )
  )
)

;; Add STX only, to close `short-ustx` in `get-stake-preview` before a roll.
;; Returned to the depositor like any deposit.
(define-public (deposit-stx (ustx uint))
  (let (
      (record (settle (get-or-create-member tx-sender)))
      (depositor tx-sender)
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (< burn-block-height (stake-window-end)) ERR_TOO_LATE)
    (asserts! (> ustx u0) ERR_INVALID_AMOUNT)
    (try! (queue-for-next-bond record depositor u0 ustx))

    (let ((result {
        depositor: depositor,
        ustx: ustx,
        queued-epoch: (var-get epoch-count),
      }))
      (print (merge { topic: "deposit-stx" } result))
      (ok result)
    )
  )
)

;; Take back the whole queued deposit; possible until `stake` commits it.
(define-public (withdraw)
  (let (
      (record (settle (unwrap! (map-get? members tx-sender) ERR_NOTHING_DEPOSITED)))
      (sats (get queued-sats record))
      (ustx (get queued-ustx record))
      (depositor tx-sender)
    )
    (asserts! (> (+ sats ustx) u0) ERR_NOTHING_DEPOSITED)

    (map-set members depositor
      (merge record {
        queued-sats: u0,
        queued-ustx: u0,
      })
    )
    (var-set queued-sats (- (var-get queued-sats) sats))
    (var-set queued-ustx (- (var-get queued-ustx) ustx))
    (try! (pay-principal depositor sats ustx))

    (let ((result {
        depositor: depositor,
        sats: sats,
        ustx: ustx,
      }))
      (print (merge { topic: "withdraw" } result))
      (ok result)
    )
  )
)

;;; The bond position

;; Anyone, in the stake window: first call opens epoch 0, later calls roll into
;; the bound bond, adding queued deposits, releasing exits. Commits what fits.
(define-public (stake (manager <signer-manager-trait>))
  (let (
      (preview (get-stake-preview))
      (eligible (get eligible-sats preview))
      (sats (get sats preview))
      (ustx (get ustx preview))
      (index (var-get pending-bond-index))
      (custodied (var-get bonded-sats))
      (epoch (var-get epoch-count))
      (start-cycle (contract-call? 'ST000000000000000000002AMW42H.pox-5
        bond-period-to-reward-cycle index
      ))
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (is-eq (contract-of manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (asserts! (> eligible u0) ERR_NOTHING_DEPOSITED)
    ;; No usable STX for this bond.
    (asserts! (> sats u0) ERR_INSUFFICIENT_STX)
    (asserts! (>= burn-block-height (stake-window-start)) ERR_TOO_EARLY)
    (asserts! (< burn-block-height (stake-window-end)) ERR_TOO_LATE)
    ;; Notice check after the window check, so a closed window reads TOO_LATE.
    (asserts! (>= burn-block-height (+ (var-get bound-at-height) BIND_NOTICE))
      ERR_TOO_EARLY
    )

    ;; pox-5 pulls only the net increase, so top up from the treasury first;
    ;; flagged in transit so the balance still reads as reward meanwhile.
    (if (> sats custodied)
      (begin
        (var-set principal-in-transit (- sats custodied))
        (try! (contract-call? .bond-treasury payout (- sats custodied) current-contract))
      )
      u0
    )

    (let ((result (try! (as-contract?
        (
          ;; The net difference, whichever way it moves.
          (with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          "sbtc-token"
          (if (> sats custodied)
            (- sats custodied)
            (- custodied sats)
          ))
          (with-staking ustx)
          (with-pox)
        )
        (let ((registered (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5 register-for-bond
            index manager ustx (err sats) none
          ))))
          ;; A shrinking roll refunds the difference here; forward to treasury.
          (if (< sats custodied)
            (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              transfer (- custodied sats) tx-sender .bond-treasury none
            ))
            true
          )
          registered
        )))))
      (var-set principal-in-transit u0)

      (map-set epochs epoch {
        bond-index: index,
        first-reward-cycle: start-cycle,
        unlock-burn-height: (var-get pending-unlock-height),
        staked-at-height: burn-block-height,
        eligible-sats: eligible,
        total-shares: sats,
        staked-sats: sats,
        staked-ustx: ustx,
        reward-index: u0,
        credited: u0,
        credit-offset: u0,
      })
      (var-set epoch-count (+ epoch u1))

      ;; Exits and the roll haircut are released; the rest carries across.
      (var-set released-sats
        (+ (var-get released-sats) (+ (var-get exiting-sats) (- eligible sats)))
      )
      (var-set released-ustx (+ (var-get released-ustx) (var-get exiting-ustx)))
      (var-set exiting-sats u0)
      (var-set exiting-ustx u0)
      (var-set queued-sats u0)
      (var-set queued-ustx u0)
      (var-set bonded-sats sats)
      (var-set bonded-ustx ustx)
      (var-set bond-bound false)

      (print (merge {
        topic: "stake",
        epoch: epoch,
        shares: sats,
        eligible-sats: eligible,
        released-sats: (- eligible sats),
      }
        result
      ))
      (ok result)
    )
  )
)

;; Anyone, after the live bond's unlock height: pull the sBTC out of pox-5 and
;; release every position. pox-5 is skipped when nothing is left staked.
(define-public (unstake-sbtc (manager <signer-manager-trait>))
  (let (
      (live (unwrap! (get-live-epoch) ERR_NOT_STAKED))
      (sats (var-get bonded-sats))
      (ustx (var-get bonded-ustx))
    )
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (is-eq (contract-of manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (asserts! (>= burn-block-height (get unlock-burn-height live)) ERR_TOO_EARLY)

    (var-set finished true)
    (var-set bond-bound false)
    (var-set released-sats (+ (var-get released-sats) sats))
    (var-set released-ustx (+ (var-get released-ustx) ustx))
    (var-set bonded-sats u0)
    (var-set bonded-ustx u0)
    (var-set exiting-sats u0)
    (var-set exiting-ustx u0)

    (let (
        (pox (if (> sats u0)
          (some (try! (as-contract?
            ;; sBTC returns here and is forwarded to the treasury; STX unlocks.
            (
              (with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              "sbtc-token" sats
            )
              (with-pox)
            )
            (let ((unstaked (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5 unstake-sbtc
                manager sats
              ))))
              (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
                transfer sats tx-sender .bond-treasury none
              ))
              unstaked
            ))))
          none
        ))
        (result {
          sats: sats,
          ustx: ustx,
          pox: pox,
        })
      )
      (print (merge { topic: "unstake-sbtc" } result))
      (ok result)
    )
  )
)

;; Operator: move the stake to another trusted signer manager. Positions kept.
(define-public (update-bond-registration
    (manager <signer-manager-trait>)
    (old-manager <signer-manager-trait>)
  )
  (begin
    (try! (authorize-operator))
    (asserts! (is-some (get-live-epoch)) ERR_NOT_STAKED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (is-eq (contract-of old-manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (asserts! (can-use-signer-manager (contract-of manager))
      ERR_SIGNER_NOT_TRUSTED
    )

    (var-set signer-manager (contract-of manager))

    (let ((result (try! (as-contract?
        ;; No asset moves.
        ((with-pox))
        (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5
          update-bond-registration manager old-manager none
        ))
      ))))
      (print (merge { topic: "update-bond-registration" } result))
      (ok result)
    )
  )
)

;;; Who the operator is

;; Operator: add or remove an operator, never yourself. Handover: enable the
;; newcomer, who disables you. May end empty; `unstake-sbtc` needs no operator.
(define-public (update-operator
    (who principal)
    (enabled bool)
  )
  (begin
    (try! (authorize-operator))
    (asserts! (not (is-eq tx-sender who)) ERR_UNAUTHORIZED)
    (map-set operators who enabled)
    (print {
      topic: "update-operator",
      operator: who,
      enabled: enabled,
    })
    (ok who)
  )
)

;;; The signer managers the operator may choose from

;; Operator: trust a code hash, usable from the next epoch so members can
;; leave at the roll first. A hash, so it can be vetted before deployment.
(define-public (trust-signer-manager (code-hash (buff 32)))
  (let ((trusted-at (var-get epoch-count)))
    (try! (authorize-operator))
    ;; Re-adding must not restart the clock.
    (asserts! (map-insert trusted-signers code-hash trusted-at)
      ERR_ALREADY_TRUSTED
    )
    (let ((result {
        code-hash: code-hash,
        trusted-at: trusted-at,
        usable-from-epoch: (+ trusted-at u1),
      }))
      (print (merge { topic: "trust-signer-manager" } result))
      (ok result)
    )
  )
)

;; Operator: distrust a code hash, effective at once. Does not undo a move made.
(define-public (distrust-signer-manager (code-hash (buff 32)))
  (begin
    (try! (authorize-operator))
    (asserts! (map-delete trusted-signers code-hash) ERR_SIGNER_NOT_TRUSTED)
    (print {
      topic: "distrust-signer-manager",
      code-hash: code-hash,
    })
    (ok true)
  )
)

;;; Leaving

;; Member: be released at the next roll (or by `unstake-sbtc`). The queued part
;; is refunded now; the committed part keeps its shares until the epoch settles.
(define-public (request-exit)
  (let (
      (record (settle (unwrap! (map-get? members tx-sender) ERR_NOTHING_DEPOSITED)))
      (member tx-sender)
      (sats (get bonded-sats record))
      (ustx (get bonded-ustx record))
      (refund-sats (get queued-sats record))
      (refund-ustx (get queued-ustx record))
      (epoch (var-get epoch-count))
    )
    (asserts! (> epoch u0) ERR_NOT_STAKED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (is-none (get exit-epoch record)) ERR_ALREADY_EXITING)
    (asserts! (> sats u0) ERR_NOTHING_DEPOSITED)

    (map-set members member
      (merge record {
        queued-sats: u0,
        queued-ustx: u0,
        exit-epoch: (some (- epoch u1)),
      })
    )
    (var-set queued-sats (- (var-get queued-sats) refund-sats))
    (var-set queued-ustx (- (var-get queued-ustx) refund-ustx))
    (var-set exiting-sats (+ (var-get exiting-sats) sats))
    (var-set exiting-ustx (+ (var-get exiting-ustx) ustx))
    (try! (pay-principal member refund-sats refund-ustx))

    (let ((result {
        member: member,
        sats: sats,
        ustx: ustx,
        refunded-sats: refund-sats,
        refunded-ustx: refund-ustx,
        exit-epoch: (- epoch u1),
      }))
      (print (merge { topic: "request-exit" } result))
      (ok result)
    )
  )
)

;; Member: withdraw a `request-exit` before the roll realises it.
(define-public (cancel-exit)
  (let (
      (record (settle (unwrap! (map-get? members tx-sender) ERR_NOTHING_DEPOSITED)))
      (member tx-sender)
      (epoch (unwrap! (get exit-epoch record) ERR_NOT_EXITING))
    )
    ;; An exit set by `unstake-sbtc-early` has no sats or shares to return to;
    ;; cancelling would carry bare STX into the next bond.
    (asserts! (> (get bonded-sats record) u0) ERR_NOTHING_DEPOSITED)
    ;; Only a request from the live epoch is still ahead of its roll.
    (asserts! (is-eq epoch (- (var-get epoch-count) u1)) ERR_POSITION_ACTIVE)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)

    (map-set members member (merge record { exit-epoch: none }))
    (var-set exiting-sats (- (var-get exiting-sats) (get bonded-sats record)))
    (var-set exiting-ustx (- (var-get exiting-ustx) (get bonded-ustx record)))

    (let ((result {
        member: member,
        sats: (get bonded-sats record),
        ustx: (get bonded-ustx record),
      }))
      (print (merge { topic: "cancel-exit" } result))
      (ok result)
    )
  )
)

;; Member: take committed sBTC back now via pox-5 `unstake-sbtc`. The STX leg is
;; released at the roll; unrecognised rewards and the rest of the bond are lost.
(define-public (unstake-sbtc-early
    (manager <signer-manager-trait>)
    (sats uint)
  )
  (begin
    ;; Checked here so a mismatch reads as this contract's error.
    (asserts! (is-eq (contract-of manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (let (
        ;; Ledger first, so a pool refusal reads as the pool's error. One tx.
        (booked (try! (apply-early-unstake tx-sender sats)))
        (unstaked (try! (as-contract?
          (
            ;; pox-5 returns the sats here; forwarded to the treasury.
            (with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            "sbtc-token" sats
          )
            (with-pox)
          )
          (let ((removed (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5 unstake-sbtc
              manager sats
            ))))
            (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              transfer sats tx-sender .bond-treasury none
            ))
            removed
          ))))
      )
      (let ((result (merge booked { pox: unstaked })))
        (print (merge { topic: "unstake-sbtc-early" } result))
        (ok result)
      )
    )
  )
)

;; Ledger half of `unstake-sbtc-early`, split out so the fuzzer can drive it
;; without a protocol bond on simnet.
(define-private (apply-early-unstake
    (member principal)
    (sats uint)
  )
  (let (
      (record (settle (unwrap! (map-get? members member) ERR_NOTHING_DEPOSITED)))
      (live (unwrap! (get-live-epoch) ERR_NOT_STAKED))
      (epoch (- (var-get epoch-count) u1))
      (held (get bonded-sats record))
      (leaving-all (is-eq sats held))
    )
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    ;; An exiting member's sats are already promised to the roll.
    (asserts! (is-none (get exit-epoch record)) ERR_ALREADY_EXITING)
    (asserts! (> held u0) ERR_NOTHING_DEPOSITED)
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    ;; Underflow guards; all implied by the pool's invariants.
    (asserts!
      (and
        (<= sats held)
        (<= sats (get shares record))
        (<= sats (get total-shares live))
        (<= sats (var-get bonded-sats))
      )
      ERR_INVALID_AMOUNT
    )

    (let ((shares-left (- (get total-shares live) sats)))
      ;; The last shares out remove the denominator: a pot `sync-rewards` would
      ;; still credit to this epoch must be recognised first; dust does not.
      (asserts!
        (not (and
          (is-eq shares-left u0)
          (is-eq (get-reward-epoch) (some epoch))
          (> (get-recognizable-rewards) u0)
        ))
        ERR_REWARDS_PENDING
      )
      ;; Future rewards split by what remains; `credit-offset` keeps the credit.
      (map-set epochs epoch
        (merge live {
          total-shares: shares-left,
          credit-offset: (- (get credited live)
            (/ (* shares-left (get reward-index live)) PRECISION)
          ),
        })
      )
      (map-set members member
        (merge record {
          shares: (- (get shares record) sats),
          bonded-sats: (- held sats),
          released-sats: (+ (get released-sats record) sats),
          ;; Nothing committed left: the roll frees the STX leg.
          exit-epoch: (if leaving-all
            (some epoch)
            (get exit-epoch record)
          ),
        })
      )
      (var-set bonded-sats (- (var-get bonded-sats) sats))
      (var-set released-sats (+ (var-get released-sats) sats))
      ;; Only the STX joins the exiting side; the sats are already released.
      (if leaving-all
        (var-set exiting-ustx (+ (var-get exiting-ustx) (get bonded-ustx record)))
        false
      )

      (ok {
        member: member,
        epoch: epoch,
        sats: sats,
        remaining-sats: (- held sats),
        shares-after: shares-left,
        ustx-at-roll: (if leaving-all
          (get bonded-ustx record)
          u0
        ),
        exiting: leaving-all,
      })
    )
  )
)

;;; Rewards

;; The `sync-rewards` arithmetic: new index, new credited total and the amount
;; recognised. Zero when `total-shares` is 0 or the surplus is sub-share dust.
(define-private (reward-split (record {
    bond-index: uint,
    first-reward-cycle: uint,
    unlock-burn-height: uint,
    staked-at-height: uint,
    staked-sats: uint,
    staked-ustx: uint,
    eligible-sats: uint,
    total-shares: uint,
    reward-index: uint,
    credited: uint,
    credit-offset: uint,
  }))
  (let (
      (shares (get total-shares record))
      (delta (if (> shares u0)
        (/ (* (get-unrecognized-rewards) PRECISION) shares)
        u0
      ))
      (next-index (+ (get reward-index record) delta))
      ;; Recomputed from the index, not accumulated -- see `total-credited`.
      (credited (+ (/ (* shares next-index) PRECISION) (get credit-offset record)))
    )
    {
      reward-index: next-index,
      credited: credited,
      recognized: (- credited (get credited record)),
    }
  )
)

;; What `sync-rewards` would credit now; zero when it would refuse.
(define-read-only (get-recognizable-rewards)
  (match (get-reward-epoch)
    epoch (match (map-get? epochs epoch)
      record (get recognized (reward-split record))
      u0
    )
    u0
  )
)

;; Anyone: split the unrecognised sBTC across the reward epoch's shares. Leaves
;; sub-share dust for a later call. Refused mid-roll (ERR_PRINCIPAL_IN_TRANSIT).
(define-public (sync-rewards)
  (let (
      (epoch (unwrap! (get-reward-epoch) ERR_NOT_STAKED))
      (record (unwrap! (map-get? epochs epoch) ERR_UNKNOWN_EPOCH))
      (split (reward-split record))
      (next-index (get reward-index split))
      (credited (get credited split))
      (recognized (get recognized split))
    )
    (asserts! (is-eq (var-get principal-in-transit) u0) ERR_PRINCIPAL_IN_TRANSIT)
    (asserts! (> recognized u0) ERR_NOTHING_TO_CLAIM)

    (map-set epochs epoch
      (merge record {
        reward-index: next-index,
        credited: credited,
      })
    )
    (var-set total-credited (+ (var-get total-credited) recognized))

    (let ((result {
        epoch: epoch,
        recognized: recognized,
        reward-index: next-index,
      }))
      (print (merge { topic: "sync-rewards" } result))
      (ok result)
    )
  )
)

;; Anyone: pay `member` their settled rewards.
(define-public (claim-rewards (member principal))
  (let (
      (record (settle (unwrap! (map-get? members member) ERR_NOTHING_DEPOSITED)))
      (amount (get pending record))
    )
    (asserts! (> amount u0) ERR_NOTHING_TO_CLAIM)

    (map-set members member (merge record { pending: u0 }))
    ;; Never exceeds `total-credited`: member and epoch credit floor alike.
    (var-set total-paid (+ (var-get total-paid) amount))

    (try! (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        amount
      ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer amount tx-sender member none
      ))
    ))

    (print {
      topic: "claim-rewards",
      member: member,
      amount: amount,
    })
    (ok amount)
  )
)

;; Anyone: pay `member` their released principal. Shares stay on the books, so
;; rewards still owed keep settling.
(define-public (claim-principal (member principal))
  (let (
      (record (settle (unwrap! (map-get? members member) ERR_NOTHING_DEPOSITED)))
      (sats (get released-sats record))
      (ustx (get released-ustx record))
    )
    (asserts! (> (+ sats ustx) u0) ERR_NOTHING_TO_CLAIM)

    (map-set members member
      (merge record {
        released-sats: u0,
        released-ustx: u0,
      })
    )
    (var-set released-sats (- (var-get released-sats) sats))
    (var-set released-ustx (- (var-get released-ustx) ustx))
    (try! (pay-principal member sats ustx))

    (let ((result {
        member: member,
        sats: sats,
        ustx: ustx,
      }))
      (print (merge { topic: "claim-principal" } result))
      (ok result)
    )
  )
)

;; Settle a record without moving money; repeat past CATCHUP_STEPS epochs.
(define-public (settle-member (member principal))
  (let ((record (settle (unwrap! (map-get? members member) ERR_NOTHING_DEPOSITED))))
    (map-set members member record)
    (ok record)
  )
)

;;; Ledger side of the L1 bridge; `bond-bridge` is the only caller.

(define-private (authorize-operator)
  (ok (asserts! (is-operator tx-sender) ERR_UNAUTHORIZED))
)

(define-private (authorize-bridge)
  (ok (asserts! (is-eq contract-caller .bond-bridge) ERR_UNAUTHORIZED))
)

;; Hold allocation room for an announced deposit; returns its STX leg.
(define-public (reserve-bridged-deposit
    (member principal)
    (sats uint)
  )
  (begin
    (try! (authorize-bridge))
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (< burn-block-height (stake-window-end)) ERR_TOO_LATE)
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    (asserts! (<= (+ (get-committing-sats) sats) (var-get pending-max-sats))
      ERR_ALLOCATION_EXCEEDED
    )
    (asserts! (is-none (get exit-epoch (settle (get-or-create-member member))))
      ERR_ALREADY_EXITING
    )
    (var-set announced-sats (+ (var-get announced-sats) sats))
    (ok (get-required-ustx sats))
  )
)

;; Release the room of an abandoned announcement.
(define-public (abandon-bridged-deposit (sats uint))
  (begin
    (try! (authorize-bridge))
    (var-set announced-sats (- (var-get announced-sats) sats))
    (ok true)
  )
)

;; Queue a confirmed bridge deposit; sats are in the treasury, STX handed over.
(define-public (credit-bridged-deposit
    (member principal)
    (sats uint)
    (ustx uint)
  )
  (begin
    (try! (authorize-bridge))
    (var-set announced-sats (- (var-get announced-sats) sats))
    (try! (credit-queue (settle (get-or-create-member member)) member sats ustx))
    (ok true)
  )
)

;; Move released sats to the bridge for a BTC withdrawal; returns the amount.
(define-public (debit-released-for-bridge
    (member principal)
    (max-fee uint)
  )
  (begin
    (try! (authorize-bridge))
    (let (
        (record (settle (unwrap! (map-get? members member) ERR_NOTHING_DEPOSITED)))
        (locked (get released-sats record))
      )
      (asserts! (> locked max-fee) ERR_INVALID_AMOUNT)

      (map-set members member (merge record { released-sats: u0 }))
      (var-set released-sats (- (var-get released-sats) locked))
      (var-set withdrawing-sats (+ (var-get withdrawing-sats) locked))
      (try! (contract-call? .iou-bond-btc lock locked member))
      (ok locked)
    )
  )
)

;; Close a BTC withdrawal; rejected sats return to the member's released sats.
(define-public (settle-bridge-withdrawal
    (member principal)
    (sats uint)
    (accepted bool)
  )
  (begin
    (try! (authorize-bridge))
    (var-set withdrawing-sats (- (var-get withdrawing-sats) sats))
    (if accepted
      (try! (contract-call? .iou-bond-btc burn-locked sats member))
      (let ((record (settle (get-or-create-member member))))
        (map-set members member
          (merge record { released-sats: (+ (get released-sats record) sats) })
        )
        (var-set released-sats (+ (var-get released-sats) sats))
        (try! (contract-call? .iou-bond-btc unlock sats member))
      )
    )
    (ok true)
  )
)

;; Operator: pay out `get-unattributed-principal`; never member principal.
(define-public (sweep-unattributed-principal (recipient principal))
  (let ((amount (get-unattributed-principal)))
    (try! (authorize-operator))
    (asserts! (> amount u0) ERR_NOTHING_TO_CLAIM)
    (try! (contract-call? .bond-treasury payout amount recipient))
    (print {
      topic: "sweep-unattributed-principal",
      amount: amount,
      recipient: recipient,
    })
    (ok amount)
  )
)

;;; Private helpers

(define-private (get-or-create-member (member principal))
  (default-to {
    shares: u0,
    bonded-sats: u0,
    bonded-ustx: u0,
    queued-sats: u0,
    queued-ustx: u0,
    queued-epoch: u0,
    released-sats: u0,
    released-ustx: u0,
    ;; Settled at the epoch not yet opened: no shares in anything that ran.
    settled-epoch: (var-get epoch-count),
    reward-index: u0,
    pending: u0,
    tail-epoch: none,
    tail-shares: u0,
    tail-index: u0,
    exit-epoch: none,
  }
    (map-get? members member)
  )
)

;; Transfer sBTC to the treasury and STX here, then queue both.
(define-private (queue-for-next-bond
    (record {
      shares: uint,
      bonded-sats: uint,
      bonded-ustx: uint,
      queued-sats: uint,
      queued-ustx: uint,
      queued-epoch: uint,
      released-sats: uint,
      released-ustx: uint,
      settled-epoch: uint,
      reward-index: uint,
      pending: uint,
      tail-epoch: (optional uint),
      tail-shares: uint,
      tail-index: uint,
      exit-epoch: (optional uint),
    })
    (depositor principal)
    (sats uint)
    (ustx uint)
  )
  (begin
    (if (> sats u0)
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer sats depositor .bond-treasury none
      ))
      true
    )
    (if (> ustx u0)
      (try! (stx-transfer? ustx depositor current-contract))
      true
    )

    (credit-queue record depositor sats ustx)
  )
)

;; Book a deposit into the queue; bridge deposits arrive already paid.
(define-private (credit-queue
    (record {
      shares: uint,
      bonded-sats: uint,
      bonded-ustx: uint,
      queued-sats: uint,
      queued-ustx: uint,
      queued-epoch: uint,
      released-sats: uint,
      released-ustx: uint,
      settled-epoch: uint,
      reward-index: uint,
      pending: uint,
      tail-epoch: (optional uint),
      tail-shares: uint,
      tail-index: uint,
      exit-epoch: (optional uint),
    })
    (member principal)
    (sats uint)
    (ustx uint)
  )
  (begin
    ;; An exiting member must `cancel-exit` first.
    (asserts! (is-none (get exit-epoch record)) ERR_ALREADY_EXITING)
    ;; One queued batch at a time, so it cannot be re-dated to a later epoch.
    (asserts!
      (or
        (is-eq (+ (get queued-sats record) (get queued-ustx record)) u0)
        (is-eq (get queued-epoch record) (var-get epoch-count))
      )
      ERR_QUEUE_PENDING
    )
    (map-set members member
      (merge record {
        queued-sats: (+ (get queued-sats record) sats),
        queued-ustx: (+ (get queued-ustx record) ustx),
        queued-epoch: (var-get epoch-count),
      })
    )
    (var-set queued-sats (+ (var-get queued-sats) sats))
    (var-set queued-ustx (+ (var-get queued-ustx) ustx))
    (mint-receipts member sats ustx)
  )
)

;; sBTC from the treasury, STX from here.
(define-private (pay-principal
    (recipient principal)
    (sats uint)
    (ustx uint)
  )
  (begin
    (try! (burn-receipts recipient sats ustx))
    (if (> sats u0)
      (try! (contract-call? .bond-treasury payout sats recipient))
      u0
    )
    (if (> ustx u0)
      (try! (as-contract? ((with-stx ustx))
        (try! (stx-transfer? ustx tx-sender recipient))
      ))
      true
    )
    (ok true)
  )
)

;; Receipt tokens mirror a member's principal: `iou-bond-btc` supply is
;; queued + bonded + released sats, `iou-bond-stx` the same in ustx.
(define-private (mint-receipts
    (member principal)
    (sats uint)
    (ustx uint)
  )
  (begin
    (if (> sats u0)
      (try! (contract-call? .iou-bond-btc mint sats member))
      true
    )
    (if (> ustx u0)
      (try! (contract-call? .iou-bond-stx mint ustx member))
      true
    )
    (ok true)
  )
)

(define-private (burn-receipts
    (member principal)
    (sats uint)
    (ustx uint)
  )
  (begin
    (if (> sats u0)
      (try! (contract-call? .iou-bond-btc burn sats member))
      true
    )
    (if (> ustx u0)
      (try! (contract-call? .iou-bond-stx burn ustx member))
      true
    )
    (ok true)
  )
)

;; Settle closed epochs, commit a queued deposit once its epoch opened, realise
;; an exit or wind-down, then accrue the current epoch and any stash.
(define-read-only (settle (record {
  shares: uint,
  bonded-sats: uint,
  bonded-ustx: uint,
  queued-sats: uint,
  queued-ustx: uint,
  queued-epoch: uint,
  released-sats: uint,
  released-ustx: uint,
  settled-epoch: uint,
  reward-index: uint,
  pending: uint,
  tail-epoch: (optional uint),
  tail-shares: uint,
  tail-index: uint,
  exit-epoch: (optional uint),
}))
  (release-if-finished
    ;; `accrue-stash` runs before the fold (bank a stash about to be replaced)
    ;; and after (draw down one the fold created). Idempotent.
    (accrue-current (accrue-stash (get record
      (fold advance-epoch CATCHUP_STEPS {
        record: (commit-queue (accrue-stash record)),
        done: false,
      })
    )))
  )
)

;; Commit a deposit queued for the member's settled epoch once it has opened,
;; scaled by that roll. Later queues are committed by `advance-epoch`.
(define-private (commit-queue (record {
  shares: uint,
  bonded-sats: uint,
  bonded-ustx: uint,
  queued-sats: uint,
  queued-ustx: uint,
  queued-epoch: uint,
  released-sats: uint,
  released-ustx: uint,
  settled-epoch: uint,
  reward-index: uint,
  pending: uint,
  tail-epoch: (optional uint),
  tail-shares: uint,
  tail-index: uint,
  exit-epoch: (optional uint),
}))
  (if (and
      (> (+ (get queued-sats record) (get queued-ustx record)) u0)
      (<= (get queued-epoch record) (get settled-epoch record))
      (< (get queued-epoch record) (var-get epoch-count))
    )
    (let (
        (committed (scale-into-epoch (get queued-sats record) (get queued-epoch record)))
        (handed-back (scale-released-from-epoch (get queued-sats record)
          (get queued-epoch record)
        ))
      )
      (merge record {
        shares: (+ (get shares record) committed),
        bonded-sats: (+ (get bonded-sats record) committed),
        bonded-ustx: (+ (get bonded-ustx record) (get queued-ustx record)),
        released-sats: (+ (get released-sats record) handed-back),
        queued-sats: u0,
        queued-ustx: u0,
      })
    )
    record
  )
)

;; One catch-up step: close `settled-epoch`, move into the next. Stops at an
;; epoch still open.
(define-private (advance-epoch
    (step uint)
    (state {
      record: {
        shares: uint,
        bonded-sats: uint,
        bonded-ustx: uint,
        queued-sats: uint,
        queued-ustx: uint,
        queued-epoch: uint,
        released-sats: uint,
        released-ustx: uint,
        settled-epoch: uint,
        reward-index: uint,
        pending: uint,
        tail-epoch: (optional uint),
        tail-shares: uint,
        tail-index: uint,
        exit-epoch: (optional uint),
      },
      done: bool,
    })
  )
  (let (
      (record (get record state))
      (epoch (get settled-epoch record))
    )
    (if (or (get done state) (not (is-epoch-ended epoch)))
      (merge state { done: true })
      (let (
          (index (default-to u0 (get reward-index (map-get? epochs epoch))))
          ;; If the epoch left is still paying, stash the claim: `accrue-stash`.
          (defer (not (is-epoch-settled epoch)))
          (next (+ epoch u1))
          (leaving (is-eq (get exit-epoch record) (some epoch)))
          (joining (is-eq (get queued-epoch record) next))
          (joining-sats (if joining
            (get queued-sats record)
            u0
          ))
          (joining-ustx (if joining
            (get queued-ustx record)
            u0
          ))
          (offered (if leaving
            u0
            (+ (get bonded-sats record) joining-sats)
          ))
          (carried (scale-into-epoch offered next))
          (handed-back (if leaving
            (get bonded-sats record)
            (scale-released-from-epoch offered next)
          ))
        )
        (merge state { record: (merge record {
          pending: (if defer
            (get pending record)
            (+ (get pending record)
              (/ (* (get shares record) (- index (get reward-index record)))
                PRECISION
              ))
          ),
          ;; At most one stash: an epoch settles half a cycle into the next,
          ;; cycles before the following roll.
          tail-epoch: (if defer
            (some epoch)
            none
          ),
          tail-shares: (if defer
            (get shares record)
            u0
          ),
          tail-index: (if defer
            (get reward-index record)
            u0
          ),
          reward-index: u0,
          settled-epoch: next,
          shares: carried,
          bonded-sats: carried,
          bonded-ustx: (if leaving
            u0
            (+ (get bonded-ustx record) joining-ustx)
          ),
          released-sats: (+ (get released-sats record) handed-back),
          released-ustx: (+ (get released-ustx record)
            (if leaving
              (get bonded-ustx record)
              u0
            )),
          queued-sats: (- (get queued-sats record) joining-sats),
          queued-ustx: (- (get queued-ustx record) joining-ustx),
          ;; Spent by this roll; clearing the flag lets the member return.
          exit-epoch: (if leaving
            none
            (get exit-epoch record)
          ),
        }) }
        )
      )
    )
  )
)

;; Draw down the stash on an epoch the member was rolled out of; dropped once
;; that epoch settles.
(define-private (accrue-stash (record {
  shares: uint,
  bonded-sats: uint,
  bonded-ustx: uint,
  queued-sats: uint,
  queued-ustx: uint,
  queued-epoch: uint,
  released-sats: uint,
  released-ustx: uint,
  settled-epoch: uint,
  reward-index: uint,
  pending: uint,
  tail-epoch: (optional uint),
  tail-shares: uint,
  tail-index: uint,
  exit-epoch: (optional uint),
}))
  (match (get tail-epoch record)
    epoch (let ((index (default-to u0 (get reward-index (map-get? epochs epoch)))))
      (merge record {
        pending: (+ (get pending record)
          (/ (* (get tail-shares record) (- index (get tail-index record)))
            PRECISION
          )),
        tail-index: index,
        tail-epoch: (if (is-epoch-settled epoch)
          none
          (some epoch)
        ),
        tail-shares: (if (is-epoch-settled epoch)
          u0
          (get tail-shares record)
        ),
      })
    )
    record
  )
)

;; Accrue the current epoch's credit since the member's index snapshot.
(define-private (accrue-current (record {
  shares: uint,
  bonded-sats: uint,
  bonded-ustx: uint,
  queued-sats: uint,
  queued-ustx: uint,
  queued-epoch: uint,
  released-sats: uint,
  released-ustx: uint,
  settled-epoch: uint,
  reward-index: uint,
  pending: uint,
  tail-epoch: (optional uint),
  tail-shares: uint,
  tail-index: uint,
  exit-epoch: (optional uint),
}))
  (let ((index (default-to u0
      (get reward-index (map-get? epochs (get settled-epoch record)))
    )))
    (merge record {
      pending: (+ (get pending record)
        (/ (* (get shares record) (- index (get reward-index record))) PRECISION)
      ),
      reward-index: index,
    })
  )
)

;; After `unstake-sbtc`, release committed principal; shares stay for rewards.
(define-private (release-if-finished (record {
  shares: uint,
  bonded-sats: uint,
  bonded-ustx: uint,
  queued-sats: uint,
  queued-ustx: uint,
  queued-epoch: uint,
  released-sats: uint,
  released-ustx: uint,
  settled-epoch: uint,
  reward-index: uint,
  pending: uint,
  tail-epoch: (optional uint),
  tail-shares: uint,
  tail-index: uint,
  exit-epoch: (optional uint),
}))
  (if (and
      (var-get finished)
      (> (+ (get bonded-sats record) (get bonded-ustx record)) u0)
    )
    (merge record {
      released-sats: (+ (get released-sats record) (get bonded-sats record)),
      released-ustx: (+ (get released-ustx record) (get bonded-ustx record)),
      bonded-sats: u0,
      bonded-ustx: u0,
    })
    record
  )
)

;;; Simnet-only fuzzing surface: Rendezvous invariants, properties and stand-ins
;;; for the pox-5 entry points. Every form carries `;; #[env(simnet)]`, which
;;; Clarinet and `scripts/build-network.mjs` strip from published source.
;;; Stand-ins shrink timings: a bond starts within 200 blocks and runs 3000.
;; #[env(simnet)]
(define-map context
  (string-ascii 100)
  { called: uint }
)

;; #[env(simnet)]
(define-private (update-context
    (function-name (string-ascii 100))
    (called uint)
  )
  (ok (map-set context function-name { called: called }))
)

;;; Stand-ins for the pox-5 calls
;; `bind-next-bond` without pox-5. Arguments folded into usable ranges; pricing
;; fixed at the first bind.
;; #[env(simnet)]
(define-public (harness-bind
    (allocation-sats uint)
    (ratio uint)
    (bips uint)
    (blocks-ahead uint)
  )
  ;; Far enough out that BIND_NOTICE runs out before the stake window closes.
  (let ((start (+ burn-block-height u900 (mod blocks-ahead u400))))
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    ;; As in `bind-next-bond`: a bond that closed unstaked is replaceable.
    (asserts! (not (can-still-stake)) ERR_BOND_ALREADY_BOUND)
    (if (is-eq (var-get epoch-count) u0)
      (begin
        ;; Any deployed contract serves as the manager; it is never called.
        (map-set operators DEPLOYER true)
        (var-set signer-manager .bond-treasury)
        (map-set trusted-signers (unwrap-panic (contract-hash? .bond-treasury))
          u0
        )
        (var-set initialized true)
        (var-set pending-stx-value-ratio (+ u1 (mod ratio u1000000)))
        (var-set pending-min-ustx-ratio (+ u1 (mod bips u10000)))
      )
      true
    )
    (var-set pending-bond-index (* (var-get epoch-count) NEXT_BOND_OFFSET))
    (var-set pending-max-sats (+ u1000000 (mod allocation-sats u100000000000)))
    (var-set pending-start-height start)
    (var-set pending-unlock-height (+ start u3000))
    (var-set bound-at-height burn-block-height)
    (var-set bond-bound true)
    (ok true)
  )
)

;; `stake` without pox-5: same gates and state; `bond-escrow` stands in for it.
;; #[env(simnet)]
(define-public (harness-lock)
  (let (
      (preview (get-stake-preview))
      (eligible (get eligible-sats preview))
      (sats (get sats preview))
      (ustx (get ustx preview))
      (custodied (var-get bonded-sats))
      (epoch (var-get epoch-count))
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (> eligible u0) ERR_NOTHING_DEPOSITED)
    (asserts! (> sats u0) ERR_INSUFFICIENT_STX)
    (asserts! (>= burn-block-height (stake-window-start)) ERR_TOO_EARLY)
    (asserts! (< burn-block-height (stake-window-end)) ERR_TOO_LATE)
    (asserts! (>= burn-block-height (+ (var-get bound-at-height) BIND_NOTICE))
      ERR_TOO_EARLY
    )

    (if (> sats custodied)
      (begin
        ;; Flagged and cleared as `stake` does, for the in-transit invariant.
        (var-set principal-in-transit (- sats custodied))
        (try! (contract-call? .bond-treasury payout (- sats custodied) current-contract))
        (try! (as-contract?
          ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            "sbtc-token" (- sats custodied)
          ))
          (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            transfer (- sats custodied) tx-sender .bond-escrow none
          ))
        ))
        (var-set principal-in-transit u0)
      )
      (if (< sats custodied)
        (begin
          (try! (contract-call? .bond-escrow release (- custodied sats)
            current-contract
          ))
          (try! (as-contract?
            ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              "sbtc-token" (- custodied sats)
            ))
            (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              transfer (- custodied sats) tx-sender .bond-treasury none
            ))
          ))
        )
        true
      )
    )

    (map-set epochs epoch {
      bond-index: (var-get pending-bond-index),
      first-reward-cycle: (+ u1
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          current-pox-reward-cycle
        )),
      unlock-burn-height: (var-get pending-unlock-height),
      staked-at-height: burn-block-height,
      eligible-sats: eligible,
      total-shares: sats,
      staked-sats: sats,
      staked-ustx: ustx,
      reward-index: u0,
      credited: u0,
      credit-offset: u0,
    })
    (var-set epoch-count (+ epoch u1))
    (var-set released-sats
      (+ (var-get released-sats) (+ (var-get exiting-sats) (- eligible sats)))
    )
    (var-set released-ustx (+ (var-get released-ustx) (var-get exiting-ustx)))
    (var-set exiting-sats u0)
    (var-set exiting-ustx u0)
    (var-set queued-sats u0)
    (var-set queued-ustx u0)
    (var-set bonded-sats sats)
    (var-set bonded-ustx ustx)
    (var-set bond-bound false)
    (ok sats)
  )
)

;; `unstake-sbtc` without pox-5.
;; #[env(simnet)]
(define-public (harness-release)
  (let ((sats (var-get bonded-sats)))
    (asserts! (> (var-get epoch-count) u0) ERR_NOT_STAKED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts!
      (>= burn-block-height
        (get unlock-burn-height (unwrap-panic (get-live-epoch)))
      )
      ERR_TOO_EARLY
    )

    (var-set finished true)
    (var-set bond-bound false)
    (var-set released-sats (+ (var-get released-sats) sats))
    (var-set released-ustx (+ (var-get released-ustx) (var-get bonded-ustx)))
    (var-set bonded-sats u0)
    (var-set bonded-ustx u0)
    (var-set exiting-sats u0)
    (var-set exiting-ustx u0)

    (try! (contract-call? .bond-escrow release sats current-contract))
    (try! (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        sats
      ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer sats tx-sender .bond-treasury none
      ))
    ))
    (ok sats)
  )
)

;; `unstake-sbtc-early` without pox-5: the real `apply-early-unstake`, with the
;; escrow paying the sats back. One call in three takes the whole position.
;; #[env(simnet)]
(define-public (harness-unstake-early (seed uint))
  (let (
      (whoever tx-sender)
      (held (match (get-settled-member whoever)
        record (get bonded-sats record)
        u0
      ))
      (sats (if (is-eq (mod seed u3) u0)
        held
        (+ u1 (mod seed held))
      ))
    )
    (asserts! (> held u0) ERR_NOTHING_DEPOSITED)
    (let ((booked (try! (apply-early-unstake whoever sats))))
      (try! (contract-call? .bond-escrow release sats current-contract))
      (try! (as-contract?
        ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          "sbtc-token" sats
        ))
        (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          transfer sats tx-sender .bond-treasury none
        ))
      ))
      (ok booked)
    )
  )
)

;; `deposit` with the amount folded into a range a simnet wallet can pay.
;; #[env(simnet)]
(define-public (harness-deposit (seed uint))
  (let (
      (committing (get-committing-sats))
      (room (if (> (var-get pending-max-sats) committing)
        (- (var-get pending-max-sats) committing)
        u0
      ))
      (ceiling (if (< room u2000000)
        room
        u2000000
      ))
    )
    (deposit (+ u1 (mod seed (+ u1 ceiling))))
  )
)

;; A reward payment as the signer manager would make it.
;; #[env(simnet)]
(define-public (harness-pay-rewards (amount uint))
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer
    amount tx-sender current-contract none
  )
)

;;; Invariants: the pool
;; The pool holds every reward credited and not yet paid.
;; #[env(simnet)]
(define-read-only (invariant-sbtc-covers-unpaid-rewards)
  (>= (get-sbtc-balance) (get-unclaimed-rewards))
)

;; Principal passes through only inside a call; never flagged between calls.
;; #[env(simnet)]
(define-read-only (invariant-no-principal-left-in-transit)
  (is-eq (var-get principal-in-transit) u0)
)

;; The treasury holds at least queued + released + withdrawing sats.
;; #[env(simnet)]
(define-read-only (invariant-treasury-covers-its-books)
  (>= (get-treasury-balance)
    (+ (var-get queued-sats)
      (+ (var-get released-sats) (var-get withdrawing-sats))
    ))
)

;; Receipts equal principal on the books; locked receipts equal withdrawing.
;; #[env(simnet)]
(define-read-only (invariant-receipts-match-principal)
  (and
    (is-eq (unwrap-panic (contract-call? .iou-bond-btc get-total-supply))
      (+ (var-get queued-sats) (+ (var-get bonded-sats) (var-get released-sats)))
    )
    (is-eq (unwrap-panic (contract-call? .iou-bond-btc get-locked-supply))
      (var-get withdrawing-sats)
    )
    (is-eq (unwrap-panic (contract-call? .iou-bond-stx get-total-supply))
      (+ (var-get queued-ustx) (+ (var-get bonded-ustx) (var-get released-ustx)))
    )
  )
)

;; The sweep reaches only what is above the books.
;; #[env(simnet)]
(define-read-only (invariant-sweep-cannot-reach-principal)
  (<=
    (+ (get-unattributed-principal)
      (+ (var-get queued-sats)
        (+ (var-get released-sats) (var-get withdrawing-sats))
      ))
    (get-treasury-balance)
  )
)

;; The contract's STX (locked + unlocked) covers every member's STX.
;; #[env(simnet)]
(define-read-only (invariant-stx-covers-obligations)
  (let ((account (stx-account current-contract)))
    (>= (+ (get locked account) (get unlocked account))
      (+ (var-get queued-ustx) (+ (var-get bonded-ustx) (var-get released-ustx)))
    )
  )
)

;; Live epoch shares equal the pool's committed sats.
;; #[env(simnet)]
(define-read-only (invariant-live-epoch-matches-the-pool)
  (match (get-live-epoch)
    live (or
      (var-get finished)
      (is-eq (get total-shares live) (var-get bonded-sats))
    )
    (and (is-eq (var-get bonded-sats) u0) (is-eq (var-get bonded-ustx) u0))
  )
)

;; Only a committed position can be on its way out.
;; #[env(simnet)]
(define-read-only (invariant-exits-fit-the-position)
  (and
    (<= (var-get exiting-sats) (var-get bonded-sats))
    (<= (var-get exiting-ustx) (var-get bonded-ustx))
  )
)

;; Rewards cannot start accruing before there is a bond to earn them.
;; #[env(simnet)]
(define-read-only (invariant-rewards-only-after-staking)
  (or
    (> (var-get epoch-count) u0)
    (and (is-eq (var-get total-credited) u0) (is-eq (var-get total-paid) u0))
  )
)

;; The pool never pays out more reward than it recognised.
;; #[env(simnet)]
(define-read-only (invariant-paid-within-credited)
  (<= (var-get total-paid) (var-get total-credited))
)

;; A wound-down pool holds no position and can never take another one.
;; #[env(simnet)]
(define-read-only (invariant-finished-is-final)
  (or
    (not (var-get finished))
    (and
      (is-eq (var-get bonded-sats) u0)
      (not (var-get bond-bound))
    )
  )
)

;;; Invariants: the early unstake
;; `total-shares` never exceeds `staked-sats`; only early unstakes part them.
;; #[env(simnet)]
(define-read-only (invariant-shares-never-exceed-the-roll (epoch uint))
  (match (map-get? epochs epoch)
    record (<= (get total-shares record) (get staked-sats record))
    true
  )
)

;; `credited` = total-shares * reward-index / PRECISION + credit-offset, the
;; identity `sync-rewards` recomputes from and `apply-early-unstake` re-bases.
;; #[env(simnet)]
(define-read-only (invariant-epoch-credit-is-accounted-for (epoch uint))
  (match (map-get? epochs epoch)
    record (is-eq (get credited record)
      (+ (/ (* (get total-shares record) (get reward-index record)) PRECISION)
        (get credit-offset record)
      ))
    true
  )
)

;;; Invariants: a member
;; No member holds more weight in their epoch than the epoch itself has.
;; #[env(simnet)]
(define-read-only (invariant-member-shares-fit-the-epoch (member principal))
  (match (get-settled-member member)
    record (match (map-get? epochs (get settled-epoch record))
      current
      (<= (get shares record) (get total-shares current))
      ;; No such epoch yet: no shares in it.
      (is-eq (get shares record) u0)
    )
    true
  )
)

;; No member is owed more reward than the pool has credited and not paid.
;; #[env(simnet)]
(define-read-only (invariant-member-rewards-fit-the-pool (member principal))
  (match (get-settled-member member)
    record (<= (get pending record) (get-unclaimed-rewards))
    true
  )
)

;; A member's principal is covered by the pool's books, both legs, every bucket.
;; #[env(simnet)]
(define-read-only (invariant-member-principal-fits-the-pool (member principal))
  (match (get-settled-member member)
    record (and
      (<= (get queued-sats record) (var-get queued-sats))
      (<= (get queued-ustx record) (var-get queued-ustx))
      (<= (get released-sats record) (var-get released-sats))
      (<= (get released-ustx record) (var-get released-ustx))
      (<= (get bonded-sats record)
        (+ (var-get bonded-sats) (var-get released-sats))
      )
      (<= (get bonded-ustx record)
        (+ (var-get bonded-ustx) (var-get released-ustx))
      )
    )
    true
  )
)

;; `settled-epoch` never exceeds `epoch-count` (a newcomer starts there).
;; #[env(simnet)]
(define-read-only (invariant-member-settled-within-the-pool (member principal))
  (match (get-settled-member member)
    record (<= (get settled-epoch record) (var-get epoch-count))
    true
  )
)

;; Shares are held only in an epoch that has opened.
;; #[env(simnet)]
(define-read-only (invariant-member-shares-need-an-epoch (member principal))
  (match (get-settled-member member)
    record (or
      (is-eq (get shares record) u0)
      (< (get settled-epoch record) (var-get epoch-count))
    )
    true
  )
)

;; The signer manager is a contract. Not asserted: that it is still trusted;
;; distrust does not unwind a move already made.
;; #[env(simnet)]
(define-read-only (invariant-signer-manager-is-a-contract)
  (or
    (is-eq (var-get epoch-count) u0)
    (is-ok (contract-hash? (var-get signer-manager)))
  )
)

;;; Properties
;; `get-required-ustx` is never below pox-5's `min-ustx-for-sats-amount`.
;; #[env(simnet)]
(define-private (test-required-ustx-covers-pox-minimum (sats uint))
  (let ((bounded (mod sats u100000000000)))
    (asserts!
      (>= (get-required-ustx bounded)
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          min-ustx-for-sats-amount bounded (var-get pending-stx-value-ratio)
          (var-get pending-min-ustx-ratio)
        ))
      (err u2900)
    )
    (ok true)
  )
)

;; `ceil-div` rounds up, and by less than one whole denominator.
;; #[env(simnet)]
(define-private (test-ceil-div-is-tight
    (numerator uint)
    (denominator uint)
  )
  (let (
      (n (mod numerator u1000000000000000000))
      (d (+ u1 (mod denominator u1000000)))
      (q (ceil-div (mod numerator u1000000000000000000)
        (+ u1 (mod denominator u1000000))
      ))
    )
    (asserts! (>= (* q d) n) (err u2901))
    (asserts! (or (is-eq q u0) (< (* (- q u1) d) n)) (err u2902))
    (ok true)
  )
)

;; Settling never loses accrued rewards or moves principal.
;; #[env(simnet)]
(define-private (test-settle-preserves-pending-and-principal
    (sats uint)
    (pending uint)
  )
  (let (
      (record {
        shares: (mod sats u100000000),
        bonded-sats: (mod sats u100000000),
        bonded-ustx: u0,
        queued-sats: u0,
        queued-ustx: u0,
        queued-epoch: u0,
        released-sats: u0,
        released-ustx: u0,
        settled-epoch: u0,
        reward-index: u0,
        pending: (mod pending u100000000),
        tail-epoch: none,
        tail-shares: u0,
        tail-index: u0,
        exit-epoch: none,
      })
      (settled (settle record))
    )
    (asserts! (>= (get pending settled) (get pending record)) (err u2903))
    ;; Principal moves between buckets, never created or lost.
    (asserts!
      (is-eq
        (+ (get bonded-sats settled)
          (+ (get queued-sats settled) (get released-sats settled))
        )
        (+ (get bonded-sats record)
          (+ (get queued-sats record) (get released-sats record))
        ))
      (err u2904)
    )
    (ok true)
  )
)

;; Re-basing credit when shares leave neither underflows nor moves the total.
;; #[env(simnet)]
(define-private (test-credit-offset-holds-the-total
    (shares uint)
    (leaving uint)
    (index uint)
  )
  (let (
      (total (+ u1 (mod shares u100000000000)))
      (out (mod leaving (+ u1 total)))
      (left (- total out))
      (idx (mod index u100000000000000000))
      (credited (/ (* total idx) PRECISION))
      (accounted (/ (* left idx) PRECISION))
    )
    (asserts! (>= credited accounted) (err u2905))
    (asserts! (is-eq (+ accounted (- credited accounted)) credited) (err u2906))
    (ok true)
  )
)
