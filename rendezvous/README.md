# Fuzzing `bond-staker` with Rendezvous

```
pnpm run fuzz:invariant    # invariant mode
pnpm run fuzz:test         # property mode
pnpm exec rv . bond-staker invariant --runs 500 --seed 42   # more control

pnpm run fuzz:invariant:v1 # the same, for the archived pool under v1/
pnpm run fuzz:test:v1
```

Nothing is generated for the first two: the invariants, the properties and the
pox-5 stand-ins live in `contracts/bond-staker.clar` itself, each form marked
`;; #[env(simnet)]`. The `:v1` scripts still concatenate a harness, because the
archived project predates the move.

## How it is wired

`rv` fuzzes a contract deployed by a Clarinet manifest, so the invariants have
to live inside the contract under test. Rather than carry them in the
production source:

| file | role |
| --- | --- |
| `contracts/bond-staker.clar` | the contract *and* the fuzzing surface, in one file |
| `Clarinet.toml` | the ordinary manifest; `rv` needs no other |
| `rendezvous/bond-escrow.clar` | stands in for pox-5's custody of the staked sBTC |

Everything in the contract's `Simnet-only` section carries `;; #[env(simnet)]`.
Clarinet strips those forms from any publish source and compiles the project
twice — `Checking contracts without #[env(simnet)] code` / `with` — so the
contract is verified as it will be deployed as well as as simnet sees it.
`scripts/build-network.mjs` strips them again on the way into `build/`, so the
file that is checked, sized for its fee and read by an auditor is already free
of them; only a short note survives to say what is missing and why.

That is why there is no harness file and no concat step. Rendezvous reads
invariants and properties out of the contract under test, and a copy that has
to be pasted in is a copy that can drift from what it constrains.

`contracts/bond-treasury.clar` and `contracts/bond-bridge.clar` are deployed
as-is: they are production code and need no stand-in.

## The early unstake

`unstake-sbtc-early` is the one entry point a stand-in would be worst at
covering, because the part worth fuzzing is its arithmetic rather than its
sBTC movement. So the contract splits its ledger half into
`apply-early-unstake`, and `harness-unstake-early` calls **that** directly --
only pox-5's side of the hand-back is played by `bond-escrow`. What the fuzzer
drives there is production code, not a copy of it.

Three checks come with it:

| check | what it covers |
| --- | --- |
| `invariant-shares-never-exceed-the-roll` | `total-shares <= staked-sats`, always |
| `invariant-epoch-credit-is-accounted-for` | `credited` is exactly live shares + `credit-offset` |
| `test-credit-offset-holds-the-total` | re-basing the offset neither underflows nor moves the total |

The invariant that does most of the work on the new path is an older one:
`invariant-live-epoch-matches-the-pool` says the live epoch's shares are the
pool's committed sats. An early unstake has to move both, by the same amount,
or it trips.

## Fuzzing the archived pool

`v1/` holds the pool as it was before any of this, and it is fuzzed the same
way through `v1/Clarinet-bond-staker.toml` and
`v1/rendezvous/bond-staker.harness.clar`, which is still a separate file — see
`v1/README.md`.

## Why there are stand-ins

A pox-5 protocol bond can only be created by pox-5's bond admin, and on simnet
that role belongs to an address no wallet holds. So `bind-next-bond`, `stake`
and `unstake-sbtc` can never get past their pox-5 calls in a fuzz run, and
without help the fuzzer would only ever see an unbound pool.

`harness-bind`, `harness-lock` and `harness-release` write exactly the state
those three write and move the sBTC exactly as pox-5 would — out of
`bond-treasury` into `bond-escrow` on the way in, back through the pool to the
treasury on the way out, and only the *net difference* on a roll. Everything
the invariants actually constrain — `deposit`, `withdraw`, `request-exit`,
`cancel-exit`, `sync-rewards`, `claim-rewards`, `claim-principal` and the whole
settlement machinery — is untouched production code. The real pox-5 path is
covered by `tests/bond-staker.test.ts`, which drives the boot-address bond
admin directly.

Two timings are shrunk so a run reaches the late states: a bond starts within
200 burn blocks instead of months out, and its term runs 3000 burn blocks
instead of 12 reward cycles — short enough to reach the wind-down, long enough
that rolling on is the usual path. Epoch *closure* is left alone: it runs on
pox-5's real reward cycles, so the fuzzer sees the same open/closed window the
deployed pool would.

## What it has caught

**A rounding hole in reward accounting.** `sync-rewards` credited the pool
`floor` of each sync's pot in turn, while a member's share is floored once
against the running index — and `floor(a) + floor(b)` can be one satoshi short
of `floor(a + b)`. After enough syncs the pool owed its members more than it
had credited, and the last claim would have aborted on the underflow. Fixed by
deriving credit from the epoch's index in one step; pinned by the "never owes
more than it has credited, across repeated syncs" unit test, which was checked
to fail against the old code.

**Principal conjured by rounding.** A roll that does not fit scales every
member's position by the same fraction. Taking the part handed back as the
*remainder* of the carried part rounded it up, so the members of a scaled roll
were collectively owed a satoshi more principal than the pool had credited —
`claim-principal-to-btc` aborted on the underflow, and with another member's
principal in the pot it would have paid out of it. Fixed by flooring both sides
independently and letting the sub-satoshi difference fall to unattributed
principal.

**A member's record describing a position the pool had moved on from.** Epochs
used to stay open for rewards past their roll, and *positions* waited for that
too — so members were carried across later than the pool was. A member who had
deposited for the next bond still showed that deposit as queued after the roll
had spent it, and `withdraw` / `request-exit` would refund it a second time out
of another member's queued funds. Fixed by splitting the two clocks: positions
move with the roll, rewards keep the slower settlement clock, and the stash
carries a member's claim on the epoch they left across the gap.

**An over-strong invariant, not a contract bug.** An early
`invariant-member-not-settled-past-an-open-epoch` assumed every member sits at
or behind the live epoch. A newcomer is deliberately settled one epoch *ahead*
— that is how they end up holding no shares in a bond that was already running.
Replaced by `invariant-member-settled-within-the-pool` and
`invariant-member-shares-need-an-epoch`, which say what was actually meant:
holding shares means sitting in an epoch that has opened.
