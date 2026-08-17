# Fuzzing `bond-staker` with Rendezvous

```
pnpm run fuzz:invariant    # invariant mode
pnpm run fuzz:test         # property mode
pnpm exec rv . bond-staker invariant --runs 500 --seed 42   # more control
```

Both scripts regenerate the harness first (`pnpm run fuzz:build`).

## How it is wired

`rv` fuzzes a contract deployed by a Clarinet manifest, so the invariants have
to live inside the contract under test. Rather than carry them in the
production source:

| file | role |
| --- | --- |
| `contracts/bond-staker.clar` | the contract, unmodified |
| `rendezvous/bond-staker.harness.clar` | invariants, properties, pox-5 stand-ins |
| `rendezvous/harnesses/bond-staker.clar` | the two concatenated (generated) |
| `Clarinet-bond-staker.toml` | manifest `rv` picks up for `bond-staker` |
| `rendezvous/bond-escrow.clar` | stands in for pox-5's custody of the staked sBTC |

`contracts/bond-treasury.clar` is deployed as-is: it is production code and
needs no stand-in.

## Why there are stand-ins

A pox-5 protocol bond can only be created by pox-5's bond admin, and on simnet
that role belongs to an address no wallet holds. So `bind-bond`, `stake` and
`unstake-sbtc` can never get past their pox-5 calls in a fuzz run, and without
help the fuzzer would only ever see an unbound pool.

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

**An over-strong invariant, not a contract bug.** An early
`invariant-member-not-settled-past-an-open-epoch` assumed every member sits at
or behind the live epoch. A newcomer is deliberately settled one epoch *ahead*
— that is how they end up holding no shares in a bond that was already running.
Replaced by `invariant-member-settled-within-the-pool` and
`invariant-member-shares-need-an-epoch`, which say what was actually meant:
holding shares means sitting in an epoch that has opened.
