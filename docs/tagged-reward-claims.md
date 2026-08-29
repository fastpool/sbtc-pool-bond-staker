# Attributing rewards by tag rather than by clock

**Designed 2026-08-29, unbuilt.** How `bond-staker` could stop dating reward
sBTC by the burn height it arrives at and start reading the reward cycle it was
earned in. Closes the residual half of [#2][issue2]. Read against `bond-staker.clar`
at `98d2946`.

[issue2]: https://github.com/fastpool/sbtc-pool-bond-staker/issues/2

## The short answer

The pool cannot ask pox-5 what a payout was for — pox-5 keys a staker's rewards
by `contract-caller`, so only the signer manager can claim them. But it does not
need pox-5. `fastpool-max500-signer-manager` already exposes
`settle-staker-rewards(staker, reward-cycle, bond-index)`, which **moves no
sBTC** and returns the exact net-of-fee amount owed for one cycle of one bond.

Book that number against the epoch. Let the money arrive separately.

Nothing about this needs a change to pox-5's `signer-manager-trait`, and
nothing needs the deployed manager redeployed — it already conforms to the
trait this proposes, which is checked below rather than assumed.

## What is wrong with the clock

Reward sBTC arrives as a bare transfer carrying no record of what it is for.
`sync-rewards` therefore dates it: `get-reward-epoch` picks the oldest epoch
still open, and `is-epoch-settled` decides when an epoch closes.

`758dacb` moved that boundary to the midpoint of the successor's first reward
cycle, which is where pox-5's payout cadence actually divides one bond's money
from the next's. That is correct for a payout that arrives on time.

It is still wrong for one that does not. A cycle's rewards sit in pox-5 until
somebody calls the manager's `claim-rewards`, and then in the manager until
somebody settles and pays out. Both are permissionless, and neither is on a
schedule. A predecessor cycle claimed late — after the midpoint — is credited to
the successor's shares, and no amount of arithmetic on burn heights can tell
the difference, because the difference is not in the burn height.

The window is now half a reward cycle rather than a cycle and a half, and it
takes a delayed upstream claim rather than an ordinary one to fall into it. That
is the whole of what the shipped fix bought.

## Why a second trait is unavoidable

pox-5 settles a staker's share against the signer that earned it:

```clarity
(define-public (claim-staker-rewards-for-signer (staker principal) ...)
    (let ((rewards-info (settle-staker-rewards contract-caller reward-cycle bond-index staker)))
```

`contract-caller`. The pool calling this directly would settle against *itself*
as the signer, which owns nothing. Only the manager can claim the pool's share.

And pox-5's trait — a boot contract's, so genuinely unchangeable without a hard
fork — carries one method:

```clarity
(define-trait signer-manager-trait (
    (validate-stake! (principal uint uint uint uint bool (optional (buff 500))) (response bool uint))
))
```

So the pool needs a second trait of its own. That is not a fork; it is a trait
definition in a contract the pool controls, and Clarity conformance is
structural — a manager satisfies it by having the right functions, not by
declaring anything.

### The deployed manager already conforms

Checked, not assumed. A probe contract defining the trait and passing the
deployed manager as a literal where the trait is expected — which Clarity
resolves at analysis time — compiles clean:

```clarity
(define-trait claimable-manager-trait (
  (settle-staker-rewards (principal uint (optional uint)) (response uint uint))
  (payout (principal) (response {
    amount: uint,
    withdrawal-request: (optional uint),
  } uint))
))

(define-public (probe (manager <claimable-manager-trait>))
  (contract-call? manager settle-staker-rewards tx-sender u10 (some u2))
)

(define-public (probe-literal)
  (probe .fastpool-max500-signer-manager)   ;; <- compiles only if it conforms
)
```

`clarinet check`: 11 contracts checked, no errors. So this costs a `bond-staker`
redeploy — which every bond already costs, since nothing about a bond is baked
into the source — and nothing else.

## The design

### Attribution and money movement, split

The issue's own sketch measures an sBTC balance delta around a claim. Do not do
that. `settle-staker-rewards` is better on every axis:

- it **moves no sBTC**, so there is no delta to measure and no reentrancy window
  worth worrying about — a manager that called back into the pool mid-settle
  would find the books exactly as it left them;
- it **returns the number**, net of the manager's fee at the rate snapshotted
  for that cycle, so what the pool books is exactly what will arrive;
- it is **permissionless**, and takes the staker as an argument, so the pool
  passes `current-contract` in a plain `contract-call?` — no `as-contract?`, no
  `tx-sender` to reason about.

`payout` moves the lot later, and the arriving sBTC is drawn down against what
was booked instead of split by the clock.

### `bond-index` already keys the epoch

The pool stores `bond-index` in every `epochs` entry, and each epoch is exactly
one bond period — `NEXT_BOND_OFFSET` guarantees a roll never reuses one. So the
map from a pox-5 `(reward-cycle, bond-index)` to a local epoch is a lookup the
pool can already do, and no cycle→epoch table is needed. The cycle is only ever
needed to address pox-5's bucket, never to decide whose money it is.

### Sketch

```clarity
;; What the manager has settled for an epoch and not yet paid over.
(define-map epoch-claims uint uint)
(define-data-var total-claimed uint u0)

;; Book one reward cycle of one epoch's bond. Permissionless: it moves no sBTC
;; and can only ever attribute money more precisely than the clock would.
(define-public (claim-epoch-rewards
    (manager <claimable-manager-trait>)
    (epoch uint)
    (reward-cycle uint)
  )
  (let (
      (record (unwrap! (map-get? epochs epoch) ERR_UNKNOWN_EPOCH))
      (earned (try! (contract-call? manager settle-staker-rewards
        current-contract reward-cycle (some (get bond-index record))
      )))
    )
    (asserts! (is-eq (contract-of manager) (var-get signer-manager))
      ERR_INVALID_SIGNER_MANAGER
    )
    (map-set epoch-claims epoch (+ (default-to u0 (map-get? epoch-claims epoch)) earned))
    (var-set total-claimed (+ (var-get total-claimed) earned))
    (ok earned)
  )
)
```

`sync-rewards` then changes from *"credit the epoch the clock names"* to
*"credit the epochs that have claims outstanding, oldest first, and fall back to
the clock for whatever is left over"*. Every satoshi covered by a booked claim
is attributed by tag; anything else — a bare donation, an unswept bridge fee, a
mistaken transfer — keeps today's behaviour.

## What stays clock-based, and why that is fine

`is-epoch-settled` does not go away. It still decides when a member's tail is
dropped, and under tagged claiming it could be made stronger: an epoch is
finished when its bond has no unclaimed cycles left, which is a fact rather
than a deadline. That is a second change and should be a second decision.

The point is that the fallback stops being the mechanism. Today a manager
payout and a stranger's donation are indistinguishable and both go by the
clock. Afterwards, the payout carries a tag and only the donation is a guess —
which is the right split, because a donation genuinely has no correct answer.

## A cheaper option that does not work

Worth recording, because it looks like it should. pox-5 has a read-only that
takes the signer as an *argument* rather than reading `contract-caller`:

```clarity
(define-read-only (get-earned-staker-rewards (signer principal) (reward-cycle uint)
                                             (bond-index (optional uint)) (staker principal))
```

The pool holds its manager's principal as a plain value, so it can call this on
pox-5 — a literal contract — with no trait at all. Read the gross owed for each
open epoch's `(cycle, bond)`, use those as weights to split arriving sBTC, and
the manager's flat per-cycle fee mostly cancels in the ratio.

It fails on timing. `claim-staker-rewards-for-signer` zeroes
`staker-unclaimed-rewards-for-cycle` when the manager settles, and the read-only
reads that map. By the time the sBTC lands in the pool, the cycle it came from
reads zero. The weights are only correct *before* the settlement that produces
the money, which is the one moment the pool cannot arrange to observe.

Detecting the drop to zero as a signal would mean the pool polling and
snapshotting on a cadence nobody is obliged to keep. That is a worse clock, not
the absence of one.

## What it costs

Not free, and worth being clear about before anyone starts.

- **A new trust surface.** The pool currently depends on the manager for
  `validate-stake!` and nothing else; that ignorance is load-bearing. Afterwards
  it depends on two more entry points, one of which moves sBTC. `payout` routes
  to a *Bitcoin* withdrawal when the staker has an L1 payout config — the pool
  must never set one, and "the pool has no payout config" becomes an invariant
  the contract relies on. It is safe by construction today, since
  `set-payout-config` authenticates as `tx-sender`, but it is a sentence that
  now has to be true.
- **A second reward path.** An `epoch-claims` map, one more permissionless entry
  point, and a drawdown rule for arrivals that do not match bookings — because a
  third party can call `payout` with only some cycles settled. All of it needs
  testing and fuzzing alongside the index machinery that already exists.
- **Manager coupling.** A future manager must implement both methods with these
  exact signatures, or the pool cannot be moved onto it. Today any
  `signer-manager-trait` implementer will do.

Against a defect whose blast radius is one delayed cycle's rewards at a rollover
where the membership changed, with the principal never at risk. That is why
`758dacb` shipped first and this did not.

## What would need testing

- A predecessor cycle claimed *after* the settlement midpoint still credits the
  predecessor — the case the clock cannot get right, and the whole point.
- Booking a cycle twice: the second `settle-staker-rewards` returns zero and
  `ERR_NO_CLAIMABLE_REWARDS`, so the pool must tolerate the error rather than
  double-book.
- `payout` triggered by a third party with some cycles booked and some not.
- Untagged sBTC arriving alongside booked claims, and each ending up where it
  should.
- A manager swap mid-epoch: cycles booked under the old manager, paid under the
  new one — `update-bond-registration` allows this and pox-5 keys rewards per
  signer, so the old manager still owes them.
- The solvency invariants, unchanged: `total-claimed` must never let
  `sync-rewards` credit more than arrived.
