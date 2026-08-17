;; Bitcoin Staking Bond staker
;;
;; A pooled staker for pox-5 protocol bonds. The contract is the pox-5
;; *staker*: it is the principal that appears on a bond's allowlist, the
;; principal whose sBTC pox-5 custodies for the bond term, and the principal
;; whose STX pox-5 locks. Depositors hold a claim on this contract, not on
;; pox-5.
;;
;; Epochs
;;
;; The pool lives through a sequence of bonds. Each bond it stakes into is an
;; *epoch*: a frozen record of which bond, when it started and ends, how many
;; shares were committed to it, and its own reward pot. Epoch 0 is the pool's
;; first bond; every later epoch is a roll-over out of the one before it.
;;
;; pox-5 makes rolling seamless: bond N's term ends at exactly the cycle bond
;; N+6 begins, and `register-for-bond` on the new bond while still a member of
;; the old one moves only the *net difference* in sBTC and resizes the STX
;; lock in place. So a roll neither unwinds nor re-funds the position -- it
;; adds the new deposits, releases the leavers, and carries the rest across
;; untouched.
;;
;; Three quantities per member
;;
;;   sats    the sBTC they deposited     -- what they get back
;;   ustx    the STX they deposited      -- what they get back
;;   shares  their weight in an epoch    -- what their rewards are split by
;;
;; Shares are struck when a bond is staked or rolled, and one share is one
;; committed satoshi, mirroring how pox-5 itself weights bond rewards. They
;; are held separately from the deposit rather than derived from it because
;; the two come apart: a member who has left keeps their shares in the epoch
;; they were part of -- and so keeps earning that bond's rewards as they
;; arrive -- while their sats and STX are already claimable.
;;
;; A roll that does not fit
;;
;; Two things can make a bond too small for everything queued up for it: the
;; allocation the bond admin granted, and the STX floor. Every bond prices
;; sats in STX for itself, so a bond that opens after Bitcoin has gained on
;; STX demands more STX for the same sats than the pool was funded with.
;;
;; Neither is allowed to fail the roll. Missing the window is far worse than
;; rolling a little light: the position would have to run to term and wind
;; down, and it can be missed over a shortfall of a single satoshi. So `stake`
;; commits what fits -- `min(what is queued up, the allocation, what the STX
;; supports)` -- scales every member's committed sats by the same fraction,
;; and releases the remainder to them. Members can top the STX up with
;; `deposit-stx` beforehand to avoid the haircut, and `get-stake-preview`
;; shows what the roll would do before its window opens.
;;
;; The pool has the remainder back from pox-5 the moment it rolls, but a
;; member only sees it once the epoch they were in stops taking rewards, a
;; cycle into the new bond: a position is not carried out of an epoch while
;; that epoch can still pay. Asking to leave is the one exception -- an exit
;; is settled at the roll, since it does not depend on what the epoch does
;; next.
;;
;; The STX is not scaled: it is the binding side, so all of it rides on. A
;; member who is scaled back therefore comes out over-collateralised in STX
;; rather than short, and can `request-exit` if they would rather not.
;;
;; Where the money sits
;;
;; The pooled principal lives in `bond-treasury` whenever pox-5 does not have
;; custody of it: the treasury's balance is exactly the queued deposits plus
;; the principal released to members. The consequence is that any sBTC *this*
;; contract holds is reward. There is no principal to net off before splitting
;; a payout, and no way for the two to be confused. The STX leg is the
;; exception -- pox-5 locks the *staker's* STX, so it is held here.
;;
;; Which epoch a reward belongs to
;;
;; Rewards arrive as a bare sBTC transfer, carrying no record of the cycle they
;; are for, so the pool dates them by the clock. pox-5 settles a reward cycle
;; only once that cycle has ended, so a bond's final cycle pays out *after* the
;; roll that replaced it: an epoch keeps taking rewards until the epoch after it
;; has a full reward cycle behind it, and `sync-rewards` credits the oldest
;; epoch still paying. At most two are, and the latest never settles, so a late
;; payment is never stranded.
;;
;; Two clocks, then, and they are deliberately not the same one:
;;
;;   positions move when the pool rolls -- so a member's record never
;;   describes a position the pool has already moved on from, which is what
;;   keeps every counter here in step with every member's record
;;
;;   rewards move when an epoch settles -- so the bond a member was actually
;;   in is the one that pays them, including the member who left at the roll
;;
;; The gap between the two is bridged by a *stash*: when the roll carries a
;; member out of an epoch that is still paying, their claim on it -- the shares
;; they held and the point they had drawn it down to -- is set aside, and
;; `accrue-stash` keeps drawing it until that epoch settles. Only ever one
;; stash: an epoch settles a cycle into the next one, and the roll after that
;; is a bond term further on.
;;
;; The STX/sBTC split
;;
;; pox-5 requires a bond participant to lock STX worth `min-ustx-ratio` of the
;; sats they bond (`min-ustx-for-sats-amount`). For the genesis bond that
;; ratio is 500 bips, i.e. the STX leg is 5% of the value of the sBTC leg -- a
;; deposit of 95.24% sBTC / 4.76% STX by value. `get-required-ustx` derives
;; the STX leg from the *bound* bond's parameters, so a deposit is always
;; priced for the bond it is queued for. The per-deposit STX is rounded up, so
;; the pooled sum is never below pox-5's requirement for the pooled sats.
;;
;; Naming
;;
;; Each function that reaches into pox-5 carries pox-5's own name for what it
;; does there, so the two APIs read the same way:
;;
;;   stake                    -> pox-5.register-for-bond
;;   unstake-sbtc             -> pox-5.unstake-sbtc
;;   update-bond-registration -> pox-5.update-bond-registration
;;
;; Note that pox-5's `unstake` and `stake-update` are *not* the counterparts
;; of the first two: they act on `staker-info`, which only STX-only staking
;; creates, and a bond position never has one.
;;
;; Lifecycle
;;
;;   initialize    deployer, once: the signer manager and the operator.
;;   bind-bond     operator, once per bond, after the bond admin has run
;;                 `setup-bond` and allowlisted this contract. Bond parameters
;;                 are read from pox-5 rather than supplied. Opens deposits.
;;   deposit       anyone, while a bond is bound and has not started.
;;   deposit-stx   anyone, to raise the STX behind the pool's sats.
;;   withdraw      anyone, for their own queued deposit, until it is staked.
;;   stake         permissionless, inside a window of STAKE_WINDOW burn blocks
;;                 before the bound bond starts. The first call opens epoch 0;
;;                 every later call rolls the position into the next bond.
;;   request-exit  a member, to be released at the next roll.
;;   unstake-sbtc  permissionless, once the live bond's 12 cycles have
;;                 elapsed. Winds the pool down for good.
;;   claim-*       anyone, on behalf of any member: rewards as they settle,
;;                 principal as it is released.
;;
;; Redeploying for a new bond
;;
;; Nothing about a specific bond is baked into this source: a bond's rate,
;; ratio, start height, unlock height and this contract's sats allowance are
;; all read from pox-5 at `bind-bond`. The genesis bond starts at bitcoin
;; block 966,350 in reward cycle 143, with a deliberately limited capacity
;; handed out to pre-approved participants:
;; https://www.stacks.co/blog/the-genesis-bond-starts-at-bitcoin-block-966-350
;;
;; That allowlist is the one precondition this contract cannot arrange for
;; itself: the bond admin must have called `setup-bond` naming this contract
;; before `bind-bond` will succeed -- for the first bond and for every roll.

(use-trait signer-manager-trait 'ST000000000000000000002AMW42H.pox-5.signer-manager-trait)

;;; Errors

(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_ALREADY_INITIALIZED (err u101))
(define-constant ERR_NOT_INITIALIZED (err u102))
(define-constant ERR_BOND_NOT_FOUND (err u103))
(define-constant ERR_NOT_ALLOWLISTED (err u104))
(define-constant ERR_ALLOCATION_EXCEEDED (err u105))
(define-constant ERR_NOT_STAKED (err u107))
(define-constant ERR_TOO_EARLY (err u108))
(define-constant ERR_TOO_LATE (err u109))
(define-constant ERR_NOTHING_DEPOSITED (err u110))
(define-constant ERR_INVALID_SIGNER_MANAGER (err u111))
(define-constant ERR_ALREADY_UNSTAKED (err u112))
(define-constant ERR_POSITION_ACTIVE (err u113))
(define-constant ERR_NOTHING_TO_CLAIM (err u114))
(define-constant ERR_INVALID_AMOUNT (err u116))
(define-constant ERR_SIGNER_NOT_REGISTERED (err u117))
(define-constant ERR_NO_BOND_BOUND (err u118))
(define-constant ERR_BOND_ALREADY_BOUND (err u119))
(define-constant ERR_INVALID_BOND_INDEX (err u120))
(define-constant ERR_INSUFFICIENT_STX (err u121))
(define-constant ERR_NOT_EXITING (err u122))
(define-constant ERR_ALREADY_EXITING (err u123))
(define-constant ERR_UNKNOWN_EPOCH (err u124))
(define-constant ERR_QUEUE_PENDING (err u125))

;;; Protocol constants -- these mirror pox-5 and are not deployment knobs

;; The length, in reward cycles, of a bond period. 12 cycles is ~6 months.
(define-constant BOND_LENGTH_CYCLES u12)

;; How many bond periods later the next seamless bond begins. pox-5 opens a
;; bond every 2 cycles, so bond N + 6 is the first one whose term starts
;; exactly where bond N's ends.
(define-constant NEXT_BOND_OFFSET u6)

;; How long before the bond starts `stake` may be called, in burn blocks.
;; ~2 days: long enough to get the transaction mined, short enough that
;; deposits stay open for as long as possible. Comfortably inside pox-5's own
;; roll-over window, which opens half a reward cycle before the bond starts.
(define-constant STAKE_WINDOW u288)

;; Slack, in uSTX, held back when working out how many sats the pool's STX
;; can carry. `get-required-ustx` rounds twice, each time by less than one
;; unit, so two is enough for its inverse to never overshoot.
(define-constant USTX_ROUNDING_SLACK u2)

;; Fixed-point scale for the per-share reward accumulator.
(define-constant PRECISION u1000000000000) ;; 1e12

;; How many closed epochs one settlement can catch up on. A member who has
;; been away longer just settles more than once.
(define-constant CATCHUP_STEPS (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9))

;; Only this principal may `initialize` the contract.
(define-constant DEPLOYER tx-sender)
(define-constant POX_5 'SP000000000000000000002Q6VF78.pox-5)
(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
;;; Configuration

(define-data-var initialized bool false)

;; Binds each bond and may move the pool to another signer manager. Has no
;; access to deposits, and cannot keep the pool from winding down: `stake` and
;; `unstake-sbtc` are both permissionless.
(define-data-var operator principal tx-sender)

;; The signer manager the pool stakes through. `stake` only accepts this one.
(define-data-var signer-manager principal tx-sender)

;;; The bound bond -- the one the next `stake` will commit to

(define-data-var bond-bound bool false)
(define-data-var pending-bond-index uint u0)
(define-data-var pending-max-sats uint u0)
;; `stx-value-ratio` is uSTX per 100 sats, `min-ustx-ratio` is in bips.
(define-data-var pending-stx-value-ratio uint u0)
(define-data-var pending-min-ustx-ratio uint u0)
(define-data-var pending-start-height uint u0)
(define-data-var pending-unlock-height uint u0)

;;; Epochs

;; One record per bond the pool has staked into. Frozen at `stake`, except for
;; the reward fields, which keep moving while the epoch is open.
(define-map epochs
  uint
  {
    bond-index: uint,
    first-reward-cycle: uint,
    unlock-burn-height: uint,
    staked-at-height: uint,
    ;; What wanted in, and what fitted. `total-shares / eligible-sats` is the
    ;; fraction of every member's position that was carried into this epoch;
    ;; the two are equal unless the allocation or the STX floor bit.
    eligible-sats: uint,
    total-shares: uint,
    staked-sats: uint,
    staked-ustx: uint,
    ;; Rewards per share, scaled by PRECISION, and the total those shares have
    ;; been credited so far.
    reward-index: uint,
    credited: uint,
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
;; `queued-sats + released-sats` is the treasury's sBTC balance, always.

(define-data-var queued-sats uint u0)
(define-data-var queued-ustx uint u0)
(define-data-var bonded-sats uint u0)
(define-data-var bonded-ustx uint u0)
(define-data-var exiting-sats uint u0)
(define-data-var exiting-ustx uint u0)
(define-data-var released-sats uint u0)
(define-data-var released-ustx uint u0)

;;; Coming in and going out over the sBTC bridge
;;
;; A member who holds L1 BTC never has to touch sBTC. They announce the deposit
;; they are about to broadcast -- paying its STX leg in the same call, which is
;; the one Stacks transaction they were always going to need -- and address the
;; bitcoin to the treasury. Once the sBTC signers have swept it,
;; `confirm-btc-deposit` reads the sBTC registry, matches the transaction to
;; the announcement, and queues the sats.
;;
;; Announcing before broadcasting is what makes this safe. A deposit addressed
;; to the treasury carries no record of who sent it, so the only thing tying it
;; to a member is the announcement -- and until the transaction is broadcast,
;; nobody else can know its txid to announce it first.

;; Sats announced but not yet swept. They hold allocation room, and their STX
;; leg is already paid, but no sBTC has arrived for them yet.
(define-data-var announced-sats uint u0)

;; Principal locked in the bridge for withdrawal requests that have not been
;; settled yet. Still part of the treasury's balance until the signers sweep.
(define-data-var withdrawing-sats uint u0)



;;; Pooled rewards
;;
;; Credit is derived from an epoch's reward index in one step -- never
;; accumulated per sync -- so it is floored the same way a member's own share
;; is. Accumulating the per-sync floors instead would credit the pool less
;; than the sum of the shares it owes (floor(a) + floor(b) can be one short of
;; floor(a + b)), and the last member to claim would find the pool a satoshi
;; light.

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
    ;; No longer committed: an exit taken, or the part of a position a roll
    ;; could not carry. Claimable.
    released-sats: uint,
    released-ustx: uint,
    ;; Reward bookkeeping: `reward-index` is a snapshot of epoch
    ;; `settled-epoch`'s index, `pending` is settled but unpaid.
    settled-epoch: uint,
    reward-index: uint,
    pending: uint,
    ;; A claim kept on an epoch the roll has carried them out of, while that
    ;; epoch is still paying: the shares they held in it and how far they have
    ;; drawn the claim down.
    tail-epoch: (optional uint),
    tail-shares: uint,
    tail-index: uint,
    ;; The epoch during which they asked to leave; the roll out of that epoch
    ;; releases them.
    exit-epoch: (optional uint),
  }
)

;;; Read-only: configuration and pool state

(define-read-only (get-config)
  {
    initialized: (var-get initialized),
    operator: (var-get operator),
    signer-manager: (var-get signer-manager),
    epoch-count: (var-get epoch-count),
    finished: (var-get finished),
  }
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
    stakeable: (can-still-stake),
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

;; What the next `stake` would do.
;;
;;   eligible-sats  everything that wants in: the committed position less the
;;                  members leaving, plus the queued deposits
;;   sats           what actually fits, once the allocation and the STX floor
;;                  are applied
;;   ustx           the STX behind it -- all of it rides, never scaled
;;   short-ustx     what would have to be deposited to carry `eligible-sats`
;;                  in full
;;
;; `sats` below `eligible-sats` means every member's position is scaled by
;; `sats / eligible-sats` and the remainder released to them.
(define-read-only (get-stake-preview)
  (let (
      (eligible (+ (- (var-get bonded-sats) (var-get exiting-sats))
        (var-get queued-sats)
      ))
      (ustx (+ (- (var-get bonded-ustx) (var-get exiting-ustx))
        (var-get queued-ustx)
      ))
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

;; The STX leg pox-5 requires alongside `sats` for the *bound* bond, rounded
;; up. Deposits are priced against the bond they are queued for.
(define-read-only (get-required-ustx (sats uint))
  (ceil-div
    (* (ceil-div (* (var-get pending-stx-value-ratio) sats) u100)
      (var-get pending-min-ustx-ratio)
    )
    u10000
  )
)

;; The inverse: the most sats `ustx` can carry under the bound bond.
;;
;; The straight division ignores the two roundings in `get-required-ustx`, so
;; its answer is checked and, if it overshoots, recomputed against a `ustx`
;; held back by the most those roundings can add. Trying the exact answer
;; first matters: a pool funded to the satoshi -- which is what `deposit`
;; charges for -- must not be scaled back by a rounding artefact.
(define-read-only (get-sats-for-ustx (ustx uint))
  (let ((per-million (* (var-get pending-stx-value-ratio)
      (var-get pending-min-ustx-ratio)
    )))
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

;; The pooled principal pox-5 does not have custody of.
(define-private (get-treasury-balance)
  (contract-call? .bond-treasury get-balance)
)

(define-private (get-sbtc-balance)
  (unwrap-panic
    (contract-call? SBTC
      get-balance current-contract
    ))
)

;; Rewards credited to members that the pool has not paid out yet.
(define-read-only (get-unclaimed-rewards)
  (- (var-get total-credited) (var-get total-paid))
)

;; sBTC this contract holds beyond the rewards it has already recognised --
;; the pot `sync-rewards` distributes. Every satoshi here is reward: the
;; principal is the treasury's.
(define-private (get-unrecognized-rewards)
  (let (
      (balance (get-sbtc-balance))
      (recognized (get-unclaimed-rewards))
    )
    (if (> balance recognized)
      (- balance recognized)
      u0
    )
  )
)

;; First burn height at which `stake` may be called for the bound bond.
(define-read-only (stake-window-start)
  (let ((start (var-get pending-start-height)))
    (if (> start STAKE_WINDOW)
      (- start STAKE_WINDOW)
      u0
    )
  )
)

;; False once the bound bond has started without the pool: it can no longer be
;; staked, and `bind-bond` may replace it.
(define-read-only (can-still-stake)
  (and
    (var-get bond-bound)
    (< burn-block-height (var-get pending-start-height))
  )
)

;; An epoch is over the moment the pool rolls out of it. *Positions* move then
;; and only then: members are carried into the new epoch in the same breath as
;; the pool is, so a member's record never describes a position the pool has
;; already moved on from.
(define-read-only (is-epoch-ended (epoch uint))
  (is-some (map-get? epochs (+ epoch u1)))
)

;; Rewards run on a slower clock. pox-5 settles a reward cycle only once that
;; cycle has ended, so a bond's final cycle pays out *after* the roll that
;; replaced it -- an epoch therefore keeps taking rewards until the epoch after
;; it has a full reward cycle behind it. The latest epoch never settles, so a
;; late payment is never stranded.
(define-private (is-epoch-settled (epoch uint))
  (match (map-get? epochs (+ epoch u1))
    next (>= burn-block-height
      (contract-call? POX_5
        reward-cycle-to-burn-height (+ (get first-reward-cycle next) u1)
      ))
    false
  )
)

;; The epoch `sync-rewards` credits: the oldest one still taking rewards. At
;; most two are, since an epoch settles one cycle into the next and a bond runs
;; for twelve.
(define-private (get-reward-epoch)
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

;; Everything holding a place in the next bond: what the roll would commit,
;; plus deposits announced over the bridge whose sats have not landed yet.
(define-read-only (get-committing-sats)
  (+ (get eligible-sats (get-stake-preview)) (var-get announced-sats))
)

;; sBTC in the treasury that the books do not account for: an unspent
;; withdrawal fee handed back by the bridge, a bridge deposit nobody announced,
;; or a plain mistaken transfer. Cannot include a satoshi of member principal.
(define-private (get-unattributed-principal)
  (let (
      (balance (unwrap-panic (get-treasury-balance)))
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

;; The part of `amount` that epoch `epoch` had room for. One for one unless
;; that roll was scaled back.
(define-read-only (scale-into-epoch
    (amount uint)
    (epoch uint)
  )
  (match (map-get? epochs epoch)
    record (if (or
        (is-eq (get eligible-sats record) u0)
        (>= (get total-shares record) (get eligible-sats record))
      )
      amount
      (/ (* amount (get total-shares record)) (get eligible-sats record))
    )
    amount
  )
)

;; The part of `amount` that epoch `epoch` had no room for, and so hands back.
;;
;; Deliberately floored in its own right rather than taken as the remainder of
;; `scale-into-epoch`. Both sides have to round *down* for the pool to stay
;; solvent on both: the carried parts must sum to no more than the epoch's
;; shares, and the handed-back parts to no more than the pool released. Deriving
;; one from the other rounds it up, and a scaled roll then owes its members a
;; satoshi more principal than it credited -- which is exactly what the
;; rendezvous run caught. What the two floors leave behind, at most one satoshi
;; per member per scaled roll, is unattributed principal.
(define-read-only (scale-released-from-epoch
    (amount uint)
    (epoch uint)
  )
  (match (map-get? epochs epoch)
    record (if (or
        (is-eq (get eligible-sats record) u0)
        (>= (get total-shares record) (get eligible-sats record))
      )
      u0
      (/ (* amount (- (get eligible-sats record) (get total-shares record)))
        (get eligible-sats record)
      )
    )
    u0
  )
)

;;; Read-only: member state

;; The member's record brought up to date: closed epochs settled, a queued
;; deposit committed, an exit or a scale-back realised. This is what every
;; member-facing function works from.
(define-private (get-settled-member (member principal))
  (match (map-get? members member)
    record (some (settle record))
    none
  )
)

(define-private (get-claimable-rewards (member principal))
  (match (map-get? members member)
    record (get pending (settle record))
    u0
  )
)

;; Principal the member can take right now: whatever has been released, plus
;; their queued deposit, which `withdraw` returns at any time.
(define-private (get-claimable-principal (member principal))
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

;;; Initialization

;; Set the signer manager the pool stakes through and the operator that binds
;; its bonds. Callable once, by the deployer.
(define-public (initialize
    (manager principal)
    (pool-operator principal)
  )
  (begin
    (asserts! (is-eq tx-sender DEPLOYER) ERR_UNAUTHORIZED)
    (asserts! (not (var-get initialized)) ERR_ALREADY_INITIALIZED)
    (asserts!
      (is-some
        (contract-call? POX_5 get-signer-info
          manager
        ))
      ERR_SIGNER_NOT_REGISTERED
    )
    (var-set signer-manager manager)
    (var-set operator pool-operator)
    (var-set initialized true)
    (print (merge { topic: "initialize" } (get-config)))
    (ok (get-config))
  )
)

;; Bind the pool to the bond it will stake into next, opening deposits.
;;
;; The bond must already exist and have this contract on its allowlist. Every
;; parameter but the allocation is read from pox-5, so none of them can be
;; wrong. Rolling on from a live bond means an index at least
;; NEXT_BOND_OFFSET ahead -- anything nearer overlaps the running term, and
;; pox-5 would reject it.
;;
;; A bond that has come and gone without being staked can be replaced, so a
;; missed window costs the pool one bond period rather than its whole future.
(define-public (bind-bond
    (index uint)
    (allocation-sats uint)
  )
  (let (
      (bond (unwrap!
        (contract-call? POX_5 get-protocol-bond
          index
        )
        ERR_BOND_NOT_FOUND
      ))
      (allowance (unwrap!
        (contract-call? POX_5 get-bond-allowance
          index current-contract
        )
        ERR_NOT_ALLOWLISTED
      ))
      (start-height (contract-call? POX_5
        bond-period-to-burn-height index
      ))
      (start-cycle (contract-call? POX_5
        bond-period-to-reward-cycle index
      ))
      (unlock-height (contract-call? POX_5
        reward-cycle-to-burn-height (+ start-cycle BOND_LENGTH_CYCLES)
      ))
    )
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (asserts! (is-eq tx-sender (var-get operator)) ERR_UNAUTHORIZED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (not (can-still-stake)) ERR_BOND_ALREADY_BOUND)
    (asserts! (> allocation-sats u0) ERR_INVALID_AMOUNT)
    ;; Never advertise more room than pox-5 will let the pool bond.
    (asserts! (<= allocation-sats allowance) ERR_ALLOCATION_EXCEEDED)
    ;; Deposits would be pointless: the bond can no longer be joined.
    (asserts! (< burn-block-height start-height) ERR_TOO_LATE)
    (asserts!
      (match (get-live-epoch)
        live (>= index (+ (get bond-index live) NEXT_BOND_OFFSET))
        true
      )
      ERR_INVALID_BOND_INDEX
    )

    (var-set pending-bond-index index)
    (var-set pending-max-sats allocation-sats)
    (var-set pending-stx-value-ratio (get stx-value-ratio bond))
    (var-set pending-min-ustx-ratio (get min-ustx-ratio bond))
    (var-set pending-start-height start-height)
    (var-set pending-unlock-height unlock-height)
    (var-set bond-bound true)

    (print (merge { topic: "bind-bond" } (get-bound-bond)))
    (ok (get-bound-bond))
  )
)

;;; Deposits

;; Deposit `sats` of sBTC plus the STX leg the bound bond requires for it.
;; The sBTC goes straight to the treasury; only the STX is held here, because
;; pox-5 locks the staker's own STX. `get-required-ustx` says how much STX
;; will be pulled.
(define-public (deposit (sats uint))
  (let (
      (ustx (get-required-ustx sats))
      (record (settle (get-or-create-member tx-sender)))
      (depositor tx-sender)
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (< burn-block-height (var-get pending-start-height)) ERR_TOO_LATE)
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

;; Add STX without adding sBTC, to raise what the pool's sats can be carried
;; on. Useful when the bond coming up prices sats higher in STX than the one
;; running does: `get-stake-preview` reports the gap as `short-ustx`, and
;; closing it is what keeps the next roll from scaling everyone back.
;;
;; The STX belongs to whoever deposited it and comes back to them like any
;; other deposit.
(define-public (deposit-stx (ustx uint))
  (let (
      (record (settle (get-or-create-member tx-sender)))
      (depositor tx-sender)
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (< burn-block-height (var-get pending-start-height)) ERR_TOO_LATE)
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

;; Take back a queued deposit, in full. Possible until the deposit is
;; committed by `stake`, and still possible afterwards if that never happens,
;; so a deposit can never be stranded.
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

;; Commit the pool to the bound bond. The first call opens epoch 0; every
;; later call rolls the live position into the next bond, adding the queued
;; deposits and releasing the members who asked to leave.
;;
;; Commits what fits rather than insisting on everything: see `A roll that
;; does not fit` above, and `get-stake-preview` for what this call would do.
;;
;; Permissionless: the only thing gating it is the clock, so no operator can
;; strand the pool by not acting.
(define-public (stake (manager <signer-manager-trait>))
  (let (
      (preview (get-stake-preview))
      (eligible (get eligible-sats preview))
      (sats (get sats preview))
      (ustx (get ustx preview))
      (index (var-get pending-bond-index))
      (custodied (var-get bonded-sats))
      (epoch (var-get epoch-count))
      (start-cycle (contract-call? POX_5
        bond-period-to-reward-cycle index
      ))
    )
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (is-eq (contract-of manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (asserts! (> eligible u0) ERR_NOTHING_DEPOSITED)
    ;; Nothing at all fits: the pool holds no usable STX for this bond.
    (asserts! (> sats u0) ERR_INSUFFICIENT_STX)
    (asserts! (>= burn-block-height (stake-window-start)) ERR_TOO_EARLY)
    (asserts! (< burn-block-height (var-get pending-start-height)) ERR_TOO_LATE)

    ;; pox-5 moves only the difference between what it already holds for this
    ;; staker and what the new bond needs, so top the contract up first when
    ;; the position is growing.
    (if (> sats custodied)
      (try! (contract-call? .bond-treasury payout (- sats custodied)
        current-contract
      ))
      u0
    )

    (let ((result (try! (as-contract?
        (
          ;; Covers whichever way the difference moves: out to pox-5 when the
          ;; position grows, out to the treasury when it shrinks.
          (with-ft SBTC
            "sbtc-token" (if (> sats custodied)
              (- sats custodied)
              (- custodied sats)
            ))
          ;; pox-5 locks the pooled STX for the bond term, and resizes the
          ;; lock in place when rolling.
          (with-staking ustx)
          (with-pox)
        )
        (let ((registered (try!
            (contract-call? POX_5
              register-for-bond index manager ustx (err sats) none
            ))))
          ;; A shrinking roll refunds the difference to the staker; send it
          ;; back to the treasury so this contract holds rewards only.
          (if (< sats custodied)
            (try!
              (contract-call?
                SBTC transfer
                (- custodied sats) tx-sender .bond-treasury none
              ))
            true
          )
          registered
        )
      ))))

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
      })
      (var-set epoch-count (+ epoch u1))

      ;; Members who asked to leave are released, along with whatever the bond
      ;; had no room for; the rest carries across.
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

;; Wind the pool down for good: pull the pooled sBTC back out of pox-5 and
;; release every position. Permissionless once the live bond's 12 cycles have
;; run, which is also when the pooled STX unlocks.
(define-public (unstake-sbtc (manager <signer-manager-trait>))
  (let (
      (live (unwrap! (get-live-epoch) ERR_NOT_STAKED))
      (sats (var-get bonded-sats))
    )
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (is-eq (contract-of manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (asserts! (>= burn-block-height (get unlock-burn-height live)) ERR_TOO_EARLY)

    (var-set finished true)
    (var-set bond-bound false)
    (var-set released-sats (+ (var-get released-sats) sats))
    (var-set released-ustx (+ (var-get released-ustx) (var-get bonded-ustx)))
    (var-set bonded-sats u0)
    (var-set bonded-ustx u0)
    (var-set exiting-sats u0)
    (var-set exiting-ustx u0)

    (let ((result (try! (as-contract?
        ;; pox-5 returns the sBTC to the staker and the pooled STX comes out
        ;; of its lock, which is a PoX state change. The sBTC goes straight
        ;; back to the treasury, so that what this contract holds is rewards
        ;; and nothing else.
        (
          (with-ft SBTC
            "sbtc-token" sats
          )
          (with-pox)
        )
        (let ((unstaked (try!
            (contract-call? POX_5 unstake-sbtc
              manager sats
            ))))
          (try!
            (contract-call? SBTC
              transfer sats tx-sender .bond-treasury none
            ))
          unstaked
        )
      ))))
      (print (merge { topic: "unstake-sbtc" } result))
      (ok result)
    )
  )
)

;; Move the pool's stake to a different signer manager for the remaining
;; cycles. The operator picks the signer, exactly as it picked the initial one
;; at `initialize`. Positions are untouched -- the bond term, the sats and the
;; STX all stay as they are.
(define-public (update-bond-registration
    (manager <signer-manager-trait>)
    (old-manager <signer-manager-trait>)
  )
  (begin
    (asserts! (is-eq tx-sender (var-get operator)) ERR_UNAUTHORIZED)
    (asserts! (is-some (get-live-epoch)) ERR_NOT_STAKED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    (asserts! (is-eq (contract-of old-manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )

    (var-set signer-manager (contract-of manager))

    (let ((result (try! (as-contract?
        ;; Only the signer behind the position changes: no asset may move.
        ((with-pox))
        (try!
          (contract-call? POX_5
            update-bond-registration manager old-manager none
          ))
      ))))
      (print (merge { topic: "update-bond-registration" } result))
      (ok result)
    )
  )
)

;;; Leaving

;; Ask to be released at the next roll. The queued part of the position is
;; paid back immediately; the committed part is released when the pool rolls
;; out of the live epoch, and its shares keep earning that bond's rewards
;; until the epoch's book closes.
;;
;; If the pool never rolls again, `unstake-sbtc` releases it instead.
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

;; Change your mind, as long as the roll has not happened yet.
(define-public (cancel-exit)
  (let (
      (record (settle (unwrap! (map-get? members tx-sender) ERR_NOTHING_DEPOSITED)))
      (member tx-sender)
      (epoch (unwrap! (get exit-epoch record) ERR_NOT_EXITING))
    )
    ;; A request made during the live epoch is still ahead of its roll; an
    ;; older one has already been realised and cannot be taken back.
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

;;; Rewards

;; Recognise sBTC that has arrived for the pool and split it across the shares
;; of the oldest epoch still open. Permissionless, and safe to call as often
;; as anyone likes: it only ever moves the surplus, and the sub-share
;; remainder is left behind for the next call rather than being lost.
(define-public (sync-rewards)
  (let (
      (epoch (unwrap! (get-reward-epoch) ERR_NOT_STAKED))
      (record (unwrap! (map-get? epochs epoch) ERR_UNKNOWN_EPOCH))
      (shares (get total-shares record))
      (surplus (get-unrecognized-rewards))
      ;; `shares` is non-zero for any epoch that exists -- `stake` rejects an
      ;; empty pool -- but this `let` is evaluated before the assert below.
      (delta (if (> shares u0)
        (/ (* surplus PRECISION) shares)
        u0
      ))
      (next-index (+ (get reward-index record) delta))
      ;; Total ever credited to this epoch, recomputed from the new index
      ;; rather than accumulated -- see `total-credited`.
      (credited (/ (* shares next-index) PRECISION))
      (recognized (- credited (get credited record)))
    )
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

;; Pay `member` the rewards their shares have earned, across every epoch they
;; have been part of. Permissionless: the sBTC always goes to `member`, so
;; anyone can settle up on their behalf.
(define-public (claim-rewards (member principal))
  (let (
      (record (settle (unwrap! (map-get? members member) ERR_NOTHING_DEPOSITED)))
      (amount (get pending record))
    )
    (asserts! (> amount u0) ERR_NOTHING_TO_CLAIM)

    (map-set members member (merge record { pending: u0 }))
    ;; Never exceeds what was credited: a member's share is floored against
    ;; the same index the epoch's own credit is derived from, and the shares
    ;; of an epoch sum to its total.
    (var-set total-paid (+ (var-get total-paid) amount))

    (try! (as-contract?
      ((with-ft SBTC
        "sbtc-token" amount
      ))
      (try!
        (contract-call? SBTC
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

;; Return principal that is no longer committed: an exit that a roll has since
;; realised, a position a roll could not carry in full, or everything, once
;; the pool has wound down. The member's shares stay on the books, so rewards
;; still owed for the bonds they were part of keep settling to them.
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

;; Bring a member's record up to date without moving any money. Useful when a
;; member has sat out more epochs than one settlement can catch up on.
(define-public (settle-member (member principal))
  (let ((record (settle (unwrap! (map-get? members member) ERR_NOTHING_DEPOSITED))))
    (map-set members member record)
    (ok record)
  )
)

;;; The ledger side of the L1 bridge
;;
;; `bond-bridge` owns the bridge protocol -- announcements, the sBTC registry
;; lookups, withdrawal requests -- and calls in here to move the ledger. It is
;; the only caller these five accept, and none of them can be reached any other
;; way.

(define-private (authorize-bridge)
  (ok (asserts! (is-eq contract-caller .bond-bridge) ERR_UNAUTHORIZED))
)

;; Hold allocation room for a deposit that is on its way over the bridge, and
;; report the STX leg it has to come with.
(define-public (reserve-bridged-deposit
    (member principal)
    (sats uint)
  )
  (begin
    (try! (authorize-bridge))
    (asserts! (var-get bond-bound) ERR_NO_BOND_BOUND)
    (asserts! (< burn-block-height (var-get pending-start-height)) ERR_TOO_LATE)
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    (asserts! (<= (+ (get-committing-sats) sats) (var-get pending-max-sats))
      ERR_ALLOCATION_EXCEEDED
    )
    (asserts!
      (is-none (get exit-epoch (settle (get-or-create-member member))))
      ERR_ALREADY_EXITING
    )
    (var-set announced-sats (+ (var-get announced-sats) sats))
    (ok (get-required-ustx sats))
  )
)

;; Give the room back: the deposit was called off.
(define-public (abandon-bridged-deposit (sats uint))
  (begin
    (try! (authorize-bridge))
    (var-set announced-sats (- (var-get announced-sats) sats))
    (ok true)
  )
)

;; Queue a deposit that has arrived over the bridge. The sats are already in
;; the treasury and the bridge has just handed the STX leg over, so this only
;; has to be written down.
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

;; Take a member's released sats out of the pool's hands and into the bridge's,
;; ready to be sent to bitcoin. Returns what was locked, so the bridge knows
;; the amount to request.
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
      ;; A fee bigger than the position is not a withdrawal.
      (asserts! (> locked max-fee) ERR_INVALID_AMOUNT)

      (map-set members member (merge record { released-sats: u0 }))
      (var-set released-sats (- (var-get released-sats) locked))
      (var-set withdrawing-sats (+ (var-get withdrawing-sats) locked))
      (ok locked)
    )
  )
)

;; Close the books on a bitcoin withdrawal. Rejected, and the sBTC is back in
;; the treasury for the member to claim; accepted, and it has left for good.
(define-public (settle-bridge-withdrawal
    (member principal)
    (sats uint)
    (accepted bool)
  )
  (begin
    (try! (authorize-bridge))
    (var-set withdrawing-sats (- (var-get withdrawing-sats) sats))
    (if accepted
      true
      (let ((record (settle (get-or-create-member member))))
        (map-set members member
          (merge record { released-sats: (+ (get released-sats record) sats) })
        )
        (var-set released-sats (+ (var-get released-sats) sats))
      )
    )
    (ok true)
  )
)

;; Move sBTC the treasury holds that the books do not account for. That is the
;; unspent part of a withdrawal fee, a bridge deposit nobody announced, or a
;; mistaken transfer -- never member principal, since the amount is measured as
;; the balance *above* everything owed.
(define-public (sweep-unattributed-principal (recipient principal))
  (let ((amount (get-unattributed-principal)))
    (asserts! (is-eq tx-sender (var-get operator)) ERR_UNAUTHORIZED)
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
    ;; A newcomer is settled at the epoch that has not opened yet: they hold
    ;; no shares in anything that has already run.
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

;; Take `sats` of sBTC into the treasury and `ustx` of STX into this contract,
;; and queue both for the bond that is bound. Shared by `deposit` and
;; `deposit-stx`.
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
      (try!
        (contract-call? SBTC
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

;; Write a deposit into the queue. Split out from the transfers because a
;; deposit that came over the bridge is already paid for by the time it is
;; confirmed -- the sats are in the treasury and the STX is here.
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
    ;; A member on the way out has to come back in through `cancel-exit`.
    (asserts! (is-none (get exit-epoch record)) ERR_ALREADY_EXITING)
    ;; One queued batch at a time, so it cannot be re-dated to a later epoch
    ;; than the one it paid for. Unreachable in practice -- a queue is
    ;; committed within a cycle of its epoch opening, and the next bond cannot
    ;; be bound anywhere near that soon -- but the accounting depends on it.
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
    (ok true)
  )
)

;; The treasury's principal, for comparing against a bridge deposit's named
;; recipient.
;; Pay principal out: the sBTC from the treasury, the STX from here.
(define-private (pay-principal
    (recipient principal)
    (sats uint)
    (ustx uint)
  )
  (begin
    (if (> sats u0)
      (try! (contract-call? .bond-treasury payout sats recipient))
      u0
    )
    (if (> ustx u0)
      (try! (as-contract?
        ((with-stx ustx))
        (try! (stx-transfer? ustx tx-sender recipient))
      ))
      true
    )
    (ok true)
  )
)

;; Bring a member's record up to date: settle rewards for every closed epoch
;; they lived through, commit a queued deposit the moment its epoch opened,
;; release them once an exit or a wind-down has taken effect, and finally
;; accrue whatever the epoch they now sit in has paid so far.
(define-private (settle (record {
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
    ;; `accrue-stash` runs on both sides of the fold: before, so a stash that
    ;; is about to be replaced is banked first, and after, so one the fold has
    ;; just created is drawn down in the same breath. Running it twice is
    ;; harmless -- the second pass finds nothing new to credit.
    (accrue-current (accrue-stash (get record (fold advance-epoch CATCHUP_STEPS {
      record: (commit-queue (accrue-stash record)),
      done: false,
    }))))
  )
)

;; A deposit queued for the epoch the member is already settled at -- which is
;; how a newcomer starts out -- is committed as soon as that epoch opens, and
;; scaled by whatever fraction of it that epoch had room for. A queue for a
;; *later* epoch is committed by `advance-epoch` instead, as the member is
;; carried into it, so that they hold no shares in the epochs in between.
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
        (committed (scale-into-epoch (get queued-sats record)
          (get queued-epoch record)
        ))
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

;; One step of the catch-up: close out `settled-epoch` and move into the next.
;; Stops as soon as the epoch the member sits in is still open, since more
;; rewards can still be credited to it.
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
          ;; The epoch being left may still be paying: pox-5 settles its final
          ;; cycle after the pool has rolled on. If so, the member's claim on
          ;; it is stashed rather than closed out, and `accrue-stash` keeps
          ;; drawing it down until the epoch settles.
          (defer (not (is-epoch-settled epoch)))
          (next (+ epoch u1))
          ;; An exit asked for during `epoch` takes effect as the pool rolls
          ;; out of it.
          (leaving (is-eq (get exit-epoch record) (some epoch)))
          ;; A deposit queued for `next` is committed as `next` opens.
          (joining (is-eq (get queued-epoch record) next))
          (joining-sats (if joining
            (get queued-sats record)
            u0
          ))
          (joining-ustx (if joining
            (get queued-ustx record)
            u0
          ))
          ;; Everything of theirs that wanted into `next`...
          (offered (if leaving
            u0
            (+ (get bonded-sats record) joining-sats)
          ))
          ;; ...the part of it the bond had room for...
          (carried (scale-into-epoch offered next))
          ;; ...and the part it handed back, floored in its own right.
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
          ;; Only ever one stash: an epoch settles a cycle into the next one,
          ;; and the roll after that is twelve cycles further on. Overwriting
          ;; one is therefore unreachable, and if it ever did happen it would
          ;; cost that member the rest of the older epoch's tail rather than
          ;; letting their position drift out of step with the pool.
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
          ;; What did not carry across is theirs to take back: the whole
          ;; position on the way out, otherwise whatever was scaled off.
          released-sats: (+ (get released-sats record) handed-back),
          released-ustx: (+ (get released-ustx record)
            (if leaving
              (get bonded-ustx record)
              u0
            )),
          queued-sats: (- (get queued-sats record) joining-sats),
          queued-ustx: (- (get queued-ustx record) joining-ustx),
        }) })
      )
    )
  )
)

;; Draw down the claim a member kept on an epoch the pool has already rolled
;; out of. Re-run on every touch while that epoch is still paying, and dropped
;; once it settles -- which is what lets a member who left at the roll collect
;; their share of the bond's final cycle.
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
    epoch (let ((index (default-to u0
        (get reward-index (map-get? epochs epoch))
      )))
      (merge record {
        pending: (+ (get pending record)
          (/ (* (get tail-shares record) (- index (get tail-index record)))
            PRECISION
          )),
        tail-index: index,
        ;; Nothing more can be credited to it: let the stash go.
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

;; Accrue what the epoch the member now sits in has credited since their
;; snapshot. That epoch is still paying, so this is re-run on every touch.
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

;; A wound-down pool has no epoch left to carry anyone into, so the committed
;; principal is released here instead. Shares are untouched: the final bond's
;; rewards are still coming.
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
