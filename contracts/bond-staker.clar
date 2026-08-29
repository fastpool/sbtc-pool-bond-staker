;; Bitcoin Staking Bond staker
;;
;; A member may take their committed sBTC back mid-term, rather than waiting
;; for the roll that settles `request-exit` or for the bond to run out.
;;
;; That is the one thing this pool does that the design before it did not, and
;; the earlier one is kept whole under `v1/` -- same file, same contract names,
;; without this. So
;;
;;     diff v1/contracts/bond-staker.clar contracts/bond-staker.clar
;;
;; is exactly what the power costs, and `v1/README.md` says how to run and fuzz
;; the older one against it.
;;
;; What that one power touches
;;
;;   unstake-sbtc-early        the new entry point -- see its own comment for
;;                             what leaving early costs the member
;;   apply-early-unstake       its ledger half, split out so the fuzzer can
;;                             drive the arithmetic without a bond
;;   get-early-unstake-preview what it would return, and what it would forfeit
;;   epochs.total-shares       shrinks when a member leaves mid-term, so
;;                             rewards are split by what is still committed
;;   epochs.staked-sats        carries the roll's scaling fraction, which
;;                             `total-shares` carried before and cannot now
;;   epochs.credit-offset      only bookkeeping: it keeps the epoch's running
;;                             credit flat when shares leave
;;   cancel-exit               refuses an exit that has no position behind it
;;
;; Why pox-5 permits this at all: its own `unstake-sbtc` takes any amount at
;; any point in a bond and hands the sBTC straight back -- the twelve-cycle
;; wait the older design imposed was its own policy, not the protocol's. What pox-5 does
;; *not* do is release the STX leg early, which is why the STX still comes
;; back at the roll here. `announce-l1-early-exit` is a different mechanism
;; again and is not reachable from this pool: it is for native-BTC
;; bondholders, and asserts `is-l1-lock` on a membership this pool never has.
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
;; the two come apart -- and which way they come apart depends on how the
;; member left.
;;
;; Leaving at a roll keeps the shares. Those sats stayed staked for the whole
;; of that bond's term and pox-5 pays on them to the end, so the member holds
;; their shares in the epoch they were part of until it settles -- still
;; earning that bond's rewards as they arrive -- while their sats and STX are
;; already claimable. That is what `tail-epoch` carries.
;;
;; Leaving early does not. `unstake-sbtc-early` has pox-5 drop the sats from
;; the current reward cycle as well as every later one, so nothing further is
;; earned on them by anyone; the member's shares leave the epoch in the same
;; call, and `total-shares` with them. A share not backed by staked sats
;; accrues nothing, which is what keeps the split honest for whoever stays.
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
;; are for, so the pool dates them by the clock. pox-5 pays out twice per reward
;; cycle, and each payout covers the cycle that has just ended -- so a bond's
;; final cycle pays out at the *start* of the cycle the roll moved on to, and
;; that cycle's own first payout comes half a cycle later. An epoch therefore
;; keeps taking rewards until the midpoint of the next epoch's first cycle, and
;; `sync-rewards` credits the oldest epoch still paying. At most two are, and
;; the latest never settles, so a late payment is never stranded.
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
;; stash: an epoch settles half a cycle into the next one, and the roll after
;; that is a bond term further on.
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
;;   set-next-bond operator: a floor on which bond period comes next, which
;;                 is how the members skip one. Optional.
;;   bind-next-bond
;;                 permissionless, once the bond admin has run `setup-bond`
;;                 and allowlisted this contract. Takes no arguments: index,
;;                 allocation and every term are read from pox-5. Opens
;;                 deposits.
;;   deposit       anyone, while a bond is bound and has not started.
;;   deposit-stx   anyone, to raise the STX behind the pool's sats.
;;   withdraw      anyone, for their own queued deposit, until it is staked.
;;   stake         permissionless, inside a window of STAKE_WINDOW burn blocks
;;                 before the bound bond starts. The first call opens epoch 0;
;;                 every later call rolls the position into the next bond.
;;   request-exit  a member, to be released at the next roll.
;;   unstake-sbtc-early
;;                 a member, for committed sBTC they want back now rather
;;                 than at the roll.
;;   unstake-sbtc  permissionless, once the live bond's 12 cycles have
;;                 elapsed. Winds the pool down for good.
;;   claim-*       anyone, on behalf of any member: rewards as they settle,
;;                 principal as it is released.
;;
;; Redeploying for a new bond
;;
;; Nothing about a specific bond is baked into this source: a bond's rate,
;; ratio, start height, unlock height and this contract's sats allowance are
;; all read from pox-5 at `bind-next-bond`. The genesis bond starts at bitcoin
;; block 966,350 in reward cycle 143, with a deliberately limited capacity
;; handed out to pre-approved participants:
;; https://www.stacks.co/blog/the-genesis-bond-starts-at-bitcoin-block-966-350
;;
;; That allowlist is the one precondition this contract cannot arrange for
;; itself: the bond admin must have called `setup-bond` naming this contract
;; before `bind-next-bond` will succeed -- first bond and every roll alike.

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
(define-constant ERR_SIGNER_NOT_TRUSTED (err u126))
(define-constant ERR_ALREADY_TRUSTED (err u127))
(define-constant ERR_NOT_A_CONTRACT (err u128))
(define-constant ERR_PRINCIPAL_IN_TRANSIT (err u130))
;; u129 was ERR_BELOW_LAUNCH_FLOOR, from when a bind could carry a launch
;; floor. Left unused rather than reassigned: an error number is part of what
;; a caller reads back, and reusing one changes the meaning of an old code.

;;; Protocol constants -- these mirror pox-5 and are not deployment knobs

;; The length, in reward cycles, of a bond period. 12 cycles is ~6 months.
(define-constant BOND_LENGTH_CYCLES u12)

;; How many bond periods later the next seamless bond begins. pox-5 opens a
;; bond every 2 cycles, so bond N + 6 is the first one whose term starts
;; exactly where bond N's ends.
(define-constant NEXT_BOND_OFFSET u6)

;; How much notice the members get of a bond the operator has bound, in burn
;; blocks. `stake` will not run until it has passed, so nobody is carried into
;; a bond they had no chance to read the terms of and `request-exit` from.
;;
;; ~4 days. It has to fit inside the window pox-5 allows for `setup-bond` --
;; two cycles before the bond starts -- with the STAKE_WINDOW still to come
;; after it, which it does on both mainnet (2100-block cycles) and testnet
;; (900).
(define-constant BIND_NOTICE u576)

;; How many bond periods ahead `bind-next-bond` looks for one this pool can
;; take. pox-5 opens a period every 2 cycles, so twelve of them is about two
;; years -- further out than a bond admin has ever set up, and short enough
;; that the search stays a handful of map reads.
(define-constant BOND_SEARCH (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11))

;; How far past `earliest-reachable-bond` `set-next-bond` may put its floor. A
;; hundred bond periods is some forty years, so this bounds nothing anyone
;; would ask for.
;;
;; What it bounds is a fat-fingered uint. pox-5 works a period's start height
;; out as `first + index * spacing`, which overflows and aborts for an absurd
;; index -- and `find-next-bond` is a read-only the front end calls, so a floor
;; nobody could reach would take the page down with it until another vote
;; cleared it.
;;
;; It is measured against the protocol's floor and not the pool's on purpose.
;; Against the pool's, a floor would be part of what bounds the next floor, so
;; a hundred at a time could be walked out as far as anyone cared to vote; the
;; cap would be on the step and not on the distance.
(define-constant MAX_SKIP u100)

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

;;; Configuration

(define-data-var initialized bool false)

;; Who may bind bonds and move the pool between vetted signer managers. No
;; access to deposits, and no way to keep the pool from winding down: `stake`
;; and `unstake-sbtc` are both permissionless.
;;
;; A set rather than a single principal, so the seat can be rotated without a
;; gap and handed over without trusting a single key to stay uncompromised.
(define-map operators
  principal
  bool
)

;; The signer manager the pool stakes through. `stake` only accepts this one.
(define-data-var signer-manager principal tx-sender)

;; Code hashes of the signer managers the pool may be moved onto, each stamped
;; with the pool's epoch count at the moment it was added.
;;
;; The operator picks the signer, and the signer is where rewards flow: pox-5
;; pays the manager, which pays the pool. A manager that simply never pays out
;; costs the members a bond's rewards. So the operator cannot name one freely --
;; only a contract whose code hash is on this list, vetted in advance.
;;
;; A hash added during an epoch cannot be used until the pool has rolled out of
;; that epoch. That is not an arbitrary delay: the roll is the *only* moment a
;; member can leave, so pinning adoption to it is what makes the notice worth
;; anything. A hash that was already on the list when the epoch was staked can
;; be moved onto at once, which is what leaves an emergency switch available.
;;
;; Removing a hash takes effect immediately, because removing is the safe
;; direction. It does not unwind a move already made.
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

;; The earliest bond period `bind-next-bond` may take, as set by the members
;; through `set-next-bond`.
;;
;; A floor rather than an exact index, and deliberately so. An exact pin on a
;; period pox-5 never sets up would strand the pool until another vote cleared
;; it -- which is the liveness problem this whole call exists to remove. As a
;; floor it still says both of the things worth saying: skip bond N by setting
;; N + 1, aim at bond M by setting M. If the bond admin's allowlist disagrees,
;; the walk carries on from there rather than stopping.
(define-data-var min-bond-index uint u0)

;;; Epochs

;; One record per bond the pool has staked into. Frozen at `stake`, except for
;; the reward fields, which keep moving while the epoch is open -- and
;; `total-shares`, which shrinks as members unstake mid-term.
(define-map epochs
  uint
  {
    bond-index: uint,
    first-reward-cycle: uint,
    unlock-burn-height: uint,
    staked-at-height: uint,
    ;; What wanted in, and what fitted. `staked-sats / eligible-sats` is the
    ;; fraction of every member's position that was carried into this epoch;
    ;; the two are equal unless the allocation or the STX floor bit.
    ;;
    ;; These two split a job one field used to do. `staked-sats` is what the
    ;; roll committed, and never moves: the scaling fraction has to read the
    ;; same for a member settling long after someone else has left as it did
    ;; for everyone carried at the roll itself. `total-shares` is what is
    ;; *still* committed, and is what rewards are split by --
    ;; `unstake-sbtc-early` takes a leaver's shares out of it. Before any early
    ;; unstake the two are equal, which is why one field once did for both.
    eligible-sats: uint,
    total-shares: uint,
    staked-sats: uint,
    staked-ustx: uint,
    ;; Rewards per share, scaled by PRECISION, and the total those shares have
    ;; been credited so far.
    reward-index: uint,
    credited: uint,
    ;; Credit that belongs to shares which have since left. `credited` is
    ;; recomputed from `total-shares * reward-index` on every sync rather than
    ;; accumulated -- see `total-credited` -- so it would drop the moment
    ;; shares do, and `sync-rewards` would underflow on the next call. This
    ;; holds the difference, which keeps the epoch's running total flat across
    ;; an early unstake instead of running backwards.
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
;; `queued-sats + released-sats` is the treasury's sBTC balance, always.

(define-data-var queued-sats uint u0)
(define-data-var queued-ustx uint u0)
(define-data-var bonded-sats uint u0)
(define-data-var bonded-ustx uint u0)
(define-data-var exiting-sats uint u0)
(define-data-var exiting-ustx uint u0)
(define-data-var released-sats uint u0)
(define-data-var released-ustx uint u0)

;; Member principal sitting in *this* contract rather than in the treasury or
;; in pox-5's custody, for the length of one call and no longer.
;;
;; There is exactly one moment it is not zero. pox-5 moves only the difference
;; between what it already holds for a staker and what the new bond needs, and
;; it pulls that difference from the staker -- so a growing roll has to top
;; this contract up out of the treasury before calling `register-for-bond`.
;;
;; That matters because everything this contract holds is otherwise reward:
;; `get-unrecognized-rewards` is the balance less what has been recognised
;; already, and for those few lines the balance is not all reward. The window
;; is reachable, too -- `register-for-bond` calls the signer manager's
;; `validate-stake!` *before* it takes the sBTC, and a manager is free to call
;; back in. So the amount is recorded rather than assumed away, and every
;; reader of the balance subtracts it.
;;
;; Rolls back with the rest of the call if the roll fails, so it cannot stick.
(define-data-var principal-in-transit uint u0)

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
    signer-manager: (var-get signer-manager),
    epoch-count: (var-get epoch-count),
    finished: (var-get finished),
    ;; The floor the members have put under the next bind, if any.
    min-bond-index: (var-get min-bond-index),
  }
)

;; Whether `who` may bind bonds and move the pool between vetted managers.
(define-read-only (is-operator (who principal))
  (default-to false (map-get? operators who))
)

;; The code hash of a deployed contract -- what `trust-signer-manager` takes.
;; Read it here rather than working it out off chain, so what is vetted and
;; what is committed to are the same bytes.
(define-read-only (get-signer-manager-hash (manager principal))
  (contract-hash? manager)
)

;; The cycle from which a signer manager with this code hash may be used, if it
;; is trusted at all.
(define-read-only (get-trusted-signer (code-hash (buff 32)))
  (map-get? trusted-signers code-hash)
)

;; Whether the operator could move the pool onto `manager` right now.
(define-read-only (can-use-signer-manager (manager principal))
  (match (contract-hash? manager)
    code-hash (match (map-get? trusted-signers code-hash)
      ;; Trusted while epoch `trusted-at - 1` was live; usable once the pool
      ;; has opened a later one.
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

;; The pooled principal pox-5 does not have custody of.
(define-read-only (get-treasury-balance)
  (contract-call? .bond-treasury get-balance)
)

(define-private (get-sbtc-balance)
  (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance current-contract
  ))
)

;; Rewards credited to members that the pool has not paid out yet.
(define-read-only (get-unclaimed-rewards)
  (- (var-get total-credited) (var-get total-paid))
)

;; sBTC this contract holds beyond the rewards it has already recognised --
;; the pot `sync-rewards` distributes.
;;
;; Every satoshi here is reward. The principal is the treasury's, except for
;; the few lines of a growing roll where it is passing through on its way to
;; pox-5, and `principal-in-transit` is exactly that: see its definition for
;; why the window exists and how it is reachable. Subtracting it is what makes
;; the sentence above true rather than nearly true.
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

;; When the stake window opens for a bond starting at `start`.
(define-read-only (stake-window-start-of (start uint))
  (if (> start STAKE_WINDOW)
    (- start STAKE_WINDOW)
    u0
  )
)

;; First burn height at which `stake` may be called for the bound bond.
(define-read-only (stake-window-start)
  (stake-window-start-of (var-get pending-start-height))
)

;; False once the bound bond has started without the pool: it can no longer be
;; staked, and `bind-next-bond` may replace it.
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

;; Rewards run on a slower clock. pox-5 pays out twice per reward cycle, each
;; payout covering the cycle that has just ended -- so a bond's final cycle
;; pays out at the start of the cycle the roll moved on to, and that cycle's
;; own first payout comes half a cycle later. An epoch therefore keeps taking
;; rewards until the midpoint of the next epoch's first cycle. The latest
;; epoch never settles, so a late payment is never stranded.
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

;; The epoch `sync-rewards` credits: the oldest one still taking rewards. At
;; most two are, since an epoch settles half a cycle into the next and a bond
;; runs for twelve.
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

;; Everything holding a place in the next bond: what the roll would commit,
;; plus deposits announced over the bridge whose sats have not landed yet.
(define-read-only (get-committing-sats)
  (+ (get eligible-sats (get-stake-preview)) (var-get announced-sats))
)

;; sBTC in the treasury that the books do not account for: an unspent
;; withdrawal fee handed back by the bridge, a bridge deposit nobody announced,
;; or a plain mistaken transfer. Cannot include a satoshi of member principal.
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

;; The part of `amount` that epoch `epoch` had room for. One for one unless
;; that roll was scaled back.
;;
;; Measured against `staked-sats` rather than `total-shares`, which are the
;; same number until someone leaves mid-term. The fraction is a property of the roll: every member
;; carried by it was scaled by the same one, and a member who settles late has
;; to be scaled by that one too, not by whatever the live share count has
;; since fallen to.
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

;; The member's record brought up to date: closed epochs settled, a queued
;; deposit committed, an exit or a scale-back realised. This is what every
;; member-facing function works from.
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

;; Principal the member can take right now: whatever has been released, plus
;; their queued deposit, which `withdraw` returns at any time.
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

;; What `unstake-sbtc-early` would do for `member` right now, and what it would
;; cost them.
;;
;;   sats             the committed sBTC it would hand back
;;   ustx-at-roll     the STX leg, which the roll releases rather than this
;;   banked-rewards   what they have already accrued, which they keep
;;   at-risk-rewards  reward sBTC the pool is holding but has not recognised
;;                    yet, at their current weight -- forfeited unless
;;                    `sync-rewards` is called first, which anyone may do
(define-read-only (get-early-unstake-preview (member principal))
  (match (map-get? members member)
    stored (let (
        (record (settle stored))
        (live-shares (match (get-live-epoch)
          live (get total-shares live)
          u0
        ))
      )
      {
        sats: (get bonded-sats record),
        ustx-at-roll: (get bonded-ustx record),
        banked-rewards: (get pending record),
        at-risk-rewards: (if (> live-shares u0)
          (/ (* (get-unrecognized-rewards) (get shares record)) live-shares)
          u0
        ),
      }
    )
    {
      sats: u0,
      ustx-at-roll: u0,
      banked-rewards: u0,
      at-risk-rewards: u0,
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
      (is-some (contract-call? 'ST000000000000000000002AMW42H.pox-5 get-signer-info
        manager
      ))
      ERR_SIGNER_NOT_REGISTERED
    )
    ;; Nobody has deposited yet, so the first choice needs no notice period.
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

;; Whether this pool could bind `index` right now.
;;
;; Three questions, and all three are pox-5's to answer: has the bond admin set
;; the period up, is this contract on its allowlist for anything at all, and is
;; the start still far enough out that the whole notice runs before the stake
;; window opens.
;;
;; That last one is what stops a bind nobody could ever stake, and it is the
;; *window* it is measured against rather than the start. Leaving the notice to
;; expire somewhere inside the window looks like it would do -- `stake` only
;; wants the notice over and the bond not yet started -- but a bond period
;; begins on a reward cycle boundary, and pox-5 refuses to register inside that
;; cycle's prepare phase. A notice ending in those last blocks is a bind that
;; holds the slot and can never be used. BIND_NOTICE + STAKE_WINDOW clears the
;; prepare phase with the whole window to spare.
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

;; The earliest period worth looking at, before the allowlist is consulted.
;;
;; The earliest period the *protocol* leaves open, before the members have
;; their say.
;;
;; Two floors, and the higher wins. The clock: a period whose stake window
;; opens sooner than BIND_NOTICE from now can never be staked, and since
;; periods are evenly spaced the first one that clears it is arithmetic rather
;; than a walk. The roll: a bond nearer than NEXT_BOND_OFFSET overlaps the
;; running term and pox-5 would reject it.
;;
;; Split out from `earliest-bindable-bond` because `set-next-bond` has to
;; measure its floor against something the floor itself is not part of. Bound
;; against the full answer, each call could stand on the last one's shoulders
;; and MAX_SKIP would cap a single step rather than the distance.
(define-read-only (earliest-reachable-bond)
  (let (
      (first (contract-call? 'ST000000000000000000002AMW42H.pox-5
        bond-period-to-burn-height u0
      ))
      (second (contract-call? 'ST000000000000000000002AMW42H.pox-5
        bond-period-to-burn-height u1
      ))
      ;; pox-5 spaces periods by a fixed number of cycles, so this is a
      ;; constant. Guarded anyway: a zero would be a division, not a bug here.
      (spacing (if (> second first)
        (- second first)
        u1
      ))
      ;; The first start height whose stake window opens late enough for the
      ;; notice to run out first -- the same rule `bindable-bond` applies, as
      ;; an index rather than a test.
      (deadline (+ burn-block-height BIND_NOTICE STAKE_WINDOW))
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

;; Where the walk starts: the earliest period the protocol leaves open, or the
;; members' floor, whichever is higher.
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

;; The bond `bind-next-bond` would take: the first period from
;; `earliest-bindable-bond` on that this pool can actually bind.
;;
;; `none` is the ordinary answer between a bond admin's `setup-bond` calls,
;; not an error -- there is simply nothing to bind yet.
(define-read-only (find-next-bond)
  (get index
    (fold check-bond-candidate BOND_SEARCH {
      from: (earliest-bindable-bond),
      index: none,
    })
  )
)

;; The bond period the members want next: `bind-next-bond` will not take
;; anything below it.
;;
;; This is the whole of the discretion left in the roll. Which bond the pool
;; goes into is otherwise arithmetic -- the earliest one pox-5 has set up with
;; this contract allowlisted, far enough out that the notice still fits -- and
;; arithmetic needs no permission. What a vote is good for is the judgement
;; the arithmetic cannot make: sit this one out.
;;
;; Skipping bond N is `set-next-bond(N + 1)`. Aiming at bond M is
;; `set-next-bond(M)`. Setting u0 puts the floor back where it started.
(define-public (set-next-bond (index uint))
  (begin
    (try! (authorize-operator))
    ;; Measured against the protocol's floor rather than the pool's, so the
    ;; distance is capped rather than each step: a floor cannot be used to
    ;; lever the next one further out.
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

;; Bind the pool to the bond it will stake into next, opening deposits.
;;
;; Permissionless, and takes no arguments, which are the same fact said twice:
;; there is nothing here for a caller to choose. The index is the earliest one
;; `find-next-bond` allows, the allocation is the whole of what pox-5 lets
;; this pool bond, and every term -- rate, ratio, start, unlock -- is read off
;; the bond itself. Two callers of this function write the same state, so
;; there is nothing to authorize and nothing to grief.
;;
;; That matters because a bind is sticky: it cannot be replaced until the bond
;; it named has started (`can-still-stake`), so a bind nobody could correct is
;; a bond period gone. Under a key it was worse than sticky -- it was a
;; liveness dependency, and a missed window cost the pool a period for no
;; better reason than that nobody was watching.
;;
;; The one judgement left is the members': `set-next-bond` puts a floor under
;; the index, which is how a bond gets deliberately skipped.
;;
;; The bond admin's `setup-bond` is still the precondition this contract
;; cannot arrange for itself. Until this pool is on a period's allowlist there
;; is nothing here to bind, for the first bond and for every roll.
(define-public (bind-next-bond)
  (begin
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    ;; A bond that has come and gone unstaked can be replaced, so a missed
    ;; window costs the pool one period rather than its whole future.
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
      ;; Both hold by construction -- `find-next-bond` starts no lower than
      ;; the roll offset and takes nothing whose notice cannot run out in
      ;; time. Asserted anyway, because they are the two properties that make
      ;; the call safe to leave open, and an assert is where a reader looks
      ;; for them.
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
      ;; The whole allowance. There is no smaller number a caller could be
      ;; trusted to pick, and the pool never has to be capped below what pox-5
      ;; already caps it at: `get-stake-preview` scales to whatever turned up.
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
    ;; Nothing at all fits: the pool holds no usable STX for this bond.
    (asserts! (> sats u0) ERR_INSUFFICIENT_STX)
    (asserts! (>= burn-block-height (stake-window-start)) ERR_TOO_EARLY)
    (asserts! (< burn-block-height (var-get pending-start-height)) ERR_TOO_LATE)
    ;; The members' notice on this bond has to have run out too, so nobody is
    ;; carried into terms they had no chance to read and leave over. Checked
    ;; after the window so a bond that has simply started reads as TOO_LATE.
    (asserts! (>= burn-block-height (+ (var-get bound-at-height) BIND_NOTICE))
      ERR_TOO_EARLY
    )

    ;; pox-5 moves only the difference between what it already holds for this
    ;; staker and what the new bond needs, so top the contract up first when
    ;; the position is growing. Flagged as in transit before it arrives and
    ;; cleared once pox-5 has it, so that for the lines in between -- which
    ;; include the signer manager's `validate-stake!`, and so anything that
    ;; manager cares to call -- this contract's sBTC balance still reads as the
    ;; rewards it is.
    (if (> sats custodied)
      (begin
        (var-set principal-in-transit (- sats custodied))
        (try! (contract-call? .bond-treasury payout (- sats custodied) current-contract))
      )
      u0
    )

    (let ((result (try! (as-contract?
        (
          ;; Covers whichever way the difference moves: out to pox-5 when the
          ;; position grows, out to the treasury when it shrinks.
          (with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          "sbtc-token"
          (if (> sats custodied)
            (- sats custodied)
            (- custodied sats)
          ))
          ;; pox-5 locks the pooled STX for the bond term, and resizes the
          ;; lock in place when rolling.
          (with-staking ustx)
          (with-pox)
        )
        (let ((registered (try! (contract-call? 'ST000000000000000000002AMW42H.pox-5 register-for-bond
            index manager ustx (err sats) none
          ))))
          ;; A shrinking roll refunds the difference to the staker; send it
          ;; back to the treasury so this contract holds rewards only.
          (if (< sats custodied)
            (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              transfer (- custodied sats) tx-sender .bond-treasury none
            ))
            true
          )
          registered
        )))))
      ;; pox-5 has it now.
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
;;
;; There may be nothing left to pull: every member can have taken their sats
;; out early, leaving only the STX leg. pox-5 is skipped then, since a zero-sat
;; withdrawal reaches an sBTC transfer of zero, which the token refuses.
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
            ;; pox-5 returns the sBTC to the staker and the pooled STX comes
            ;; out of its lock, which is a PoX state change. The sBTC goes
            ;; straight back to the treasury, so that what this contract holds
            ;; is rewards and nothing else.
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

;; Move the pool's stake to a different signer manager for the remaining
;; cycles. The operator picks the signer, exactly as it picked the initial one
;; at `initialize`. Positions are untouched -- the bond term, the sats and the
;; STX all stay as they are.
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
    ;; Vetted in advance, and past its notice period.
    (asserts! (can-use-signer-manager (contract-of manager))
      ERR_SIGNER_NOT_TRUSTED
    )

    (var-set signer-manager (contract-of manager))

    (let ((result (try! (as-contract?
        ;; Only the signer behind the position changes: no asset may move.
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

;; Add or remove an operator. Follows the signer manager's convention, down to
;; refusing to change your own entry: rotating the seat therefore always takes
;; two live operators, and no single key can lock itself out or lock everyone
;; else out.
;;
;; Handing over is: the sitting operator enables the newcomer, the newcomer
;; disables the sitting one. Winding the role down for good is the same move
;; with nobody enabled at the end -- after which the pool finishes its bond and
;; `unstake-sbtc`, which needs no operator, ends it.
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

;; Put a signer manager's code hash on the list. Usable once the pool has rolled
;; into its next bond -- the one moment a member who would rather not be behind
;; it can be gone.
;;
;; Takes a hash rather than a principal so a contract can be vetted, and
;; committed to, before it is deployed.
(define-public (trust-signer-manager (code-hash (buff 32)))
  (let ((trusted-at (var-get epoch-count)))
    (try! (authorize-operator))
    ;; Re-adding must not quietly restart the clock on a hash already pending.
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

;; Take a signer manager's code hash off the list, at once. No delay: this only
;; ever narrows what the operator can do, and waiting would be the wrong side to
;; err on. It does not unwind a move already made -- for that the pool rolls, or
;; winds down.
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
    ;; An exit that `unstake-sbtc-early` set has nothing left to come back
    ;; to. The sats are already paid out and the shares already gone; only the
    ;; STX leg is still waiting on the roll, and taking the request back would
    ;; carry that STX into the next bond with no sats and no weight behind it.
    (asserts! (> (get bonded-sats record) u0) ERR_NOTHING_DEPOSITED)
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

;; Take committed sBTC back before the bond's term is up. Everything below is
;; the price of it.
;;
;; pox-5 has never required the wait. Its own `unstake-sbtc` takes any amount,
;; at any point in a bond, and hands the sBTC straight back; the twelve-cycle
;; wait in v1 is that contract's policy, not the protocol's. Three things
;; follow from taking the protocol up on it, and none of them is hidden.
;;
;; The STX leg does not come back with it. pox-5 leaves a staker's locked STX
;; alone on an unstake and frees it on the bond's normal unlock cycle, so there
;; is nothing here to hand over. A member taking their whole position out is
;; marked as exiting, and the roll releases their STX exactly as it would have
;; released both legs had they left the ordinary way.
;;
;; Rewards the pool has not recognised yet are forfeited. sBTC is split by
;; shares at the moment `sync-rewards` recognises it, and these shares are gone
;; the moment this returns -- so a cycle that has ended but whose sBTC has not
;; been swept in yet pays the leaver nothing. `sync-rewards` is permissionless:
;; calling it first banks everything that has actually arrived, and
;; `get-early-unstake-preview` reports what is still at risk.
;;
;; The remainder of the bond is forfeited outright, which is the substance of
;; leaving rather than a penalty bolted on: pox-5 drops the unstaked sats from
;; the current reward cycle as well as every later one, so nothing further is
;; earned on them by anybody.
;;
;; What it does not do is cost anyone else. The pool's reward stream shrinks by
;; exactly the shares that left, and the remaining members' slice of whatever
;; still arrives grows to match. No member is diluted by an exit, and none
;; subsidises one.
;;
;; pox-5 refuses this during a reward cycle's prepare phase, so a call can
;; bounce on timing alone and simply be retried a few blocks later.
(define-public (unstake-sbtc-early
    (manager <signer-manager-trait>)
    (sats uint)
  )
  (begin
    ;; Checked up here so a mismatch reads as this contract's error rather
    ;; than as whatever pox-5 makes of it. pox-5 refuses one too.
    (asserts! (is-eq (contract-of manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (let (
        ;; The ledger moves first, so a request the *pool* refuses says why in
        ;; its own error. The two halves are one transaction either way: if
        ;; pox-5 says no below -- during a prepare phase, say -- none of this
        ;; happened.
        (booked (try! (apply-early-unstake tx-sender sats)))
        (unstaked (try! (as-contract?
          (
            ;; pox-5 hands the sats to the staker, which is this contract, and
            ;; they carry straight on to the treasury: what the pool itself
            ;; holds has to stay reward and nothing else.
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

;; The ledger half of an early unstake: every check it makes, and every book it
;; moves. Split out from the pox-5 call above for one reason -- the fuzzer.
;;
;; Rendezvous cannot create a protocol bond on simnet, so it can never reach
;; the public entry point; the harness works around the same problem for
;; `stake` and `unstake-sbtc` by hand-writing stand-ins. That is tolerable for
;; state a stand-in can copy exactly, and a poor trade for the arithmetic here,
;; which is the part worth fuzzing. So the harness calls *this*, and what it
;; exercises is production code rather than a second copy of it.
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
    ;; A member already on their way out has these sats promised to the roll.
    ;; Taking them now would leave `exiting-sats` describing a position the
    ;; pool no longer holds.
    (asserts! (is-none (get exit-epoch record)) ERR_ALREADY_EXITING)
    (asserts! (> held u0) ERR_NOTHING_DEPOSITED)
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    ;; Underflow guards. Every one of these is implied by the pool's own
    ;; invariants -- a member's shares are their committed sats, and the live
    ;; epoch's shares are the pool's -- but the arithmetic below is total
    ;; either way rather than only in the states we believe are reachable.
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
      ;; Future rewards are split by what is still committed. The epoch's
      ;; running credit is held flat across the change -- see `credit-offset`.
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
          ;; A member with nothing committed left is on their way out, so the
          ;; roll frees the STX leg that cannot be handed back here.
          exit-epoch: (if leaving-all
            (some epoch)
            (get exit-epoch record)
          ),
        })
      )
      (var-set bonded-sats (- (var-get bonded-sats) sats))
      (var-set released-sats (+ (var-get released-sats) sats))
      ;; Only the STX joins the exiting side. The sats have left the committed
      ;; pool already, and counting them again would have the roll release
      ;; them a second time out of somebody else's principal.
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

;; Recognise sBTC that has arrived for the pool and split it across the shares
;; of the oldest epoch still open. Permissionless, and safe to call as often
;; as anyone likes: it only ever moves the surplus, and the sub-share
;; remainder is left behind for the next call rather than being lost.
;;
;; Refused for the one call in which member principal is passing through this
;; contract on its way to pox-5. `get-unrecognized-rewards` already subtracts
;; that, so what this assert adds is not correctness but a legible answer: the
;; caller is inside somebody's roll, and a reward split taken there would be a
;; split of a pool that is mid-move. It is reachable -- see
;; `principal-in-transit` -- and it is the only mutator that can be reached
;; that way, because every other one moves sBTC and would blow the roll's own
;; post-condition.
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
      ;; rather than accumulated -- see `total-credited`. `credit-offset`
      ;; carries the part of it that belongs to shares which have already
      ;; left, so the recomputation cannot fall below what was recognised.
      (credited (+ (/ (* shares next-index) PRECISION) (get credit-offset record)))
      (recognized (- credited (get credited record)))
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

(define-private (authorize-operator)
  (ok (asserts! (is-operator tx-sender) ERR_UNAUTHORIZED))
)

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
    (asserts! (is-none (get exit-epoch (settle (get-or-create-member member))))
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
      (try! (as-contract? ((with-stx ustx))
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
    ;; `accrue-stash` runs on both sides of the fold: before, so a stash that
    ;; is about to be replaced is banked first, and after, so one the fold has
    ;; just created is drawn down in the same breath. Running it twice is
    ;; harmless -- the second pass finds nothing new to credit.
    (accrue-current (accrue-stash (get record
      (fold advance-epoch CATCHUP_STEPS {
        record: (commit-queue (accrue-stash record)),
        done: false,
      })
    )))
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
          ;; Only ever one stash: an epoch settles half a cycle into the next
          ;; one, and the roll after that is twelve cycles further on.
          ;; Overwriting one is therefore unreachable, and if it ever did
          ;; happen it would cost that member the rest of the older epoch's
          ;; tail rather than letting their position drift out of step with
          ;; the pool.
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
          ;; The request is spent here: this roll is what it asked for. Leaving
          ;; the flag set would bar every deposit path with ERR_ALREADY_EXITING
          ;; and offer no way back -- `cancel-exit` only takes back a request
          ;; still ahead of its roll, which this one no longer is. A member who
          ;; leaves is meant to be able to return, not to be barred for good.
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
    epoch (let ((index (default-to u0 (get reward-index (map-get? epochs epoch)))))
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

;;; Simnet-only: the fuzzing surface
;;; 
;;; What follows this note in `contracts/bond-staker.clar` -- and is absent
;;; from every build under `build/<network>/`, which is why there may be
;;; nothing after it here -- is the surface Rendezvous reads: the invariants,
;;; the properties, and stand-ins for the three entry points that reach pox-5.
;;; 
;;; Each form carries `;; #[env(simnet)]`. Clarinet strips those from any
;;; publish source, and `scripts/build-network.mjs` strips them on the way into
;;; `build/`, so none of it reaches a chain. `clarinet check` compiles this
;;; contract both with and without them, which is what makes it safe to keep
;;; the two in one file.

;;; 
;;; They are here rather than in a generated harness because Rendezvous reads
;;; invariants and properties out of the contract under test, and a copy that
;;; has to be concatenated in is a copy that can drift from what it constrains.
;;; 
;;; `harness-bind`, `harness-lock` and `harness-release` stand in for the three
;;; entry points that reach pox-5. They are needed because a protocol bond can
;;; only be created by pox-5's bond admin -- a boot address no simnet wallet
;;; holds, and one neither a Rendezvous dialer nor a deployment plan can reach
;;; for more than the first bond. Without them the fuzzer would only ever see
;;; an unbound pool. Everything the invariants actually constrain is untouched
;;; production code.
;;; 
;;; Two timings are shrunk so a run reaches the late states: a bond starts
;;; within 200 burn blocks rather than months out, and its term runs 3000 burn
;;; blocks rather than 12 reward cycles. Epoch *closure* is left alone: it runs
;;; on pox-5's real reward cycles.
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
;; `bind-next-bond` without the pox-5 lookups. Arguments are folded into sane
;; ranges so a random call produces a usable bond instead of bouncing. The
;; pricing is fixed at the first bind: letting it drift between bonds would
;; mostly produce rolls that bounce on the STX floor, which the unit tests
;; cover directly.
;; #[env(simnet)]
(define-public (harness-bind
    (allocation-sats uint)
    (ratio uint)
    (bips uint)
    (blocks-ahead uint)
  )
  ;; Far enough out that BIND_NOTICE (576) runs out before the stake window
  ;; opens at start - 288. Bound any nearer and the notice outlasts the bond's
  ;; start, which is exactly the trap `bind-next-bond` warns about -- and had
  ;; been silently stopping this harness from ever opening an epoch.
  (let ((start (+ burn-block-height u900 (mod blocks-ahead u400))))
    (asserts! (not (var-get finished)) ERR_ALREADY_UNSTAKED)
    ;; Same rule as `bind-next-bond`: a bond whose window closed unstaked can be
    ;; replaced. rv jumps hundreds of burn blocks between rounds, so without
    ;; this the first missed window would end the run.
    (asserts! (not (can-still-stake)) ERR_BOND_ALREADY_BOUND)
    (if (is-eq (var-get epoch-count) u0)
      (begin
        ;; Any deployed contract will do -- the harness never calls it -- but it
        ;; has to be a contract, since that is what the trust list keys on.
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
    ;; The notice runs from here, same as `bind-next-bond`.
    (var-set bound-at-height burn-block-height)
    (var-set bond-bound true)
    (ok true)
  )
)

;; `stake` without pox-5: same gates, same state, and the sBTC difference
;; moves between the treasury and the escrow exactly as it would move between
;; the treasury and pox-5.
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
    (asserts! (< burn-block-height (var-get pending-start-height)) ERR_TOO_LATE)
    (asserts! (>= burn-block-height (+ (var-get bound-at-height) BIND_NOTICE))
      ERR_TOO_EARLY
    )

    (if (> sats custodied)
      (begin
        ;; Flagged and cleared exactly as `stake` does it, so that
        ;; `invariant-no-principal-left-in-transit` is checking a flag this
        ;; harness actually raises rather than one it never touches.
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

;; `unstake-sbtc-early` without pox-5.
;;
;; Unlike the three above this is not a copy of what it stands in for: the
;; ledger half is `apply-early-unstake` itself, and only the sBTC hand-back is
;; played by the escrow. The amount is folded into what the caller actually
;; holds, so a random call exercises the path instead of bouncing on its
;; bounds -- roughly one call in three takes the whole position, which is the
;; case that also sets the exit flag and moves the STX leg.
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
      ;; The escrow stands in for pox-5's custody, so it is what pays the sats
      ;; back; they carry on to the treasury exactly as they do in production.
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

;; The real `deposit`, with the amount folded into a range a simnet wallet can
;; actually pay. Fuzzing `deposit` directly is still worthwhile -- it covers
;; the rejection paths -- but a full-range uint never buys anything, so
;; without this the deposit-dependent half of the contract is never reached.
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

;; A reward payment landing on the pool, as the signer manager would make it.
;; #[env(simnet)]
(define-public (harness-pay-rewards (amount uint))
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer
    amount tx-sender current-contract none
  )
)

;;; Invariants: the pool
;; Whatever rewards the pool has credited and not yet paid, it still holds.
;; The principal is the treasury's problem, never netted off this balance.
;; #[env(simnet)]
(define-read-only (invariant-sbtc-covers-unpaid-rewards)
  (>= (get-sbtc-balance) (get-unclaimed-rewards))
)

;; Principal only ever passes through this contract inside a single call, so
;; between calls -- which is the only place anything can look -- there is none.
;; A non-zero reading here would mean a roll left it set, and every balance the
;; pool reports would be short by that much until the next one cleared it.
;; #[env(simnet)]
(define-read-only (invariant-no-principal-left-in-transit)
  (is-eq (var-get principal-in-transit) u0)
)

;; The treasury holds the principal that pox-5 does not: deposits waiting for a
;; bond, positions that have ended and not yet been claimed, and sats locked in
;; the sBTC bridge on their way to L1. It may hold more -- an unspent
;; withdrawal fee, an unannounced bridge deposit -- but never less.
;; #[env(simnet)]
(define-read-only (invariant-treasury-covers-its-books)
  (>= (get-treasury-balance)
    (+ (var-get queued-sats)
      (+ (var-get released-sats) (var-get withdrawing-sats))
    ))
)

;; Anything above the books is unattributed, and that is the only thing the
;; operator's sweep can reach.
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

;; The STX leg never leaves until it is claimed, so the contract can always
;; cover every member's STX.
;; #[env(simnet)]
(define-read-only (invariant-stx-covers-obligations)
  (let ((account (stx-account current-contract)))
    (>= (+ (get locked account) (get unlocked account))
      (+ (var-get queued-ustx) (+ (var-get bonded-ustx) (var-get released-ustx)))
    )
  )
)

;; The live epoch's shares are the pool's committed sats. Rewards are split by
;; the former and principal is owed on the latter, so the two must not drift.
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
;; An epoch's live shares never exceed what its roll actually committed.
;; `stake` sets the two equal, and `unstake-sbtc-early` is the only thing that
;; moves them apart -- only ever downwards.
;; #[env(simnet)]
(define-read-only (invariant-shares-never-exceed-the-roll (epoch uint))
  (match (map-get? epochs epoch)
    record (<= (get total-shares record) (get staked-sats record))
    true
  )
)

;; What an epoch has credited is exactly what its live shares account for plus
;; what the shares that have left accounted for. This is the identity
;; `sync-rewards` recomputes `credited` from and `apply-early-unstake`
;; re-bases; break it and the next sync either credits the pool the difference
;; or underflows working out what it recognised.
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
      ;; No epoch under that index yet: the member cannot hold shares in it.
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

;; A member's principal is always covered by the pool's own books, on both
;; legs and in whichever bucket it currently sits.
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

;; A member never sits beyond the next epoch the pool could open. A newcomer
;; starts one ahead of the live epoch -- that is how they hold no shares in
;; anything already running -- and nothing may carry them further.
;; #[env(simnet)]
(define-read-only (invariant-member-settled-within-the-pool (member principal))
  (match (get-settled-member member)
    record (<= (get settled-epoch record) (var-get epoch-count))
    true
  )
)

;; Holding shares means sitting in an epoch that has actually opened, so the
;; weight is always measured against a real reward pot. Together with
;; `invariant-member-shares-fit-the-epoch` this is what stops a member being
;; carried past an epoch they still have weight in.
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

;; The pool is always pointed at a contract, never a bare account -- the trust
;; list keys on code hashes, and only a contract has one.
;;
;; Note what is *not* asserted: that the current manager is still trusted.
;; Distrusting takes effect at once and deliberately does not unwind a move
;; already made, so a manager can outlive its entry on the list. That the
;; operator can only ever *move onto* a trusted one is a property of the
;; transition rather than of the state, and is covered by the unit tests.
;; #[env(simnet)]
(define-read-only (invariant-signer-manager-is-a-contract)
  (or
    (is-eq (var-get epoch-count) u0)
    (is-ok (contract-hash? (var-get signer-manager)))
  )
)

;;; Properties
;; The STX the pool charges is never less than the STX pox-5 demands for the
;; same sats -- the whole point of rounding the per-deposit leg up.
;; #[env(simnet)]
(define-private (test-required-ustx-covers-pox-minimum (sats uint))
  (let ((bounded (mod sats u100000000000)))
    (asserts!
      (>= (get-required-ustx bounded)
        (contract-call? 'ST000000000000000000002AMW42H.pox-5
          min-ustx-for-sats-amount bounded (var-get pending-stx-value-ratio)
          (var-get pending-min-ustx-ratio)
        ))
      (err u900)
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
    (asserts! (>= (* q d) n) (err u901))
    (asserts! (or (is-eq q u0) (< (* (- q u1) d) n)) (err u902))
    (ok true)
  )
)

;; Settling never loses rewards a member had already accrued, and never
;; moves their principal.
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
    (asserts! (>= (get pending settled) (get pending record)) (err u903))
    ;; principal is only ever moved between buckets, never created or lost
    (asserts!
      (is-eq
        (+ (get bonded-sats settled)
          (+ (get queued-sats settled) (get released-sats settled))
        )
        (+ (get bonded-sats record)
          (+ (get queued-sats record) (get released-sats record))
        ))
      (err u904)
    )
    (ok true)
  )
)

;; Re-basing an epoch's credit when shares leave neither underflows nor moves
;; the running total. `apply-early-unstake` takes the new offset to be the
;; shortfall between what was credited and what the remaining shares account
;; for, which is only sound if the second is never the larger of the two.
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
    ;; the shortfall is never negative, which is what makes the subtraction in
    ;; `apply-early-unstake` total
    (asserts! (>= credited accounted) (err u905))
    ;; ...and re-basing lands exactly back on the number it started from
    (asserts! (is-eq (+ accounted (- credited accounted)) credited) (err u906))
    (ok true)
  )
)
