# Fuzzing `bond-staker` with Rendezvous

```
npm run fuzz:invariant     # invariant mode
npm run fuzz:test          # property mode
npx rv . bond-staker invariant --runs 500 --seed 3   # more control
```

Both scripts regenerate the harness first (`npm run fuzz:build`).

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
that role belongs to an address no wallet holds. So `initialize`, `stake` and
`unstake-sbtc` can never get past their pox-5 calls in a fuzz run, and without
help the fuzzer would only ever see an unbound pool.

`harness-bind`, `harness-lock` and `harness-release` write exactly the state
those three write and move the sBTC exactly as pox-5 would — out of
`bond-treasury` into `bond-escrow` on the way in, and back through this
contract to the treasury on the way out. Everything the invariants actually constrain — `deposit`,
`withdraw`, `sync-rewards`, `claim-rewards`, `claim-principal` — is the
untouched production code. The real pox-5 path is covered by
`tests/bond-staker.test.ts`, which drives the boot-address bond admin directly.

Two timings are shrunk so a run can reach the late states: the bond starts
within 400 burn blocks instead of weeks out, and the lock lasts 20 burn blocks
instead of 12 reward cycles.

## Trophy

`invariant-position-rewards-fit-the-pool` (then part of a combined
`invariant-position-fits-the-pool`) caught a rounding bug in reward
accounting. `sync-rewards` credited the pool `floor` of each sync's pot in
turn, while a depositor's share is floored once against the running index —
and `floor(a) + floor(b)` can be one satoshi short of `floor(a + b)`. After
enough syncs the pool owed its depositors more than it had credited, and the
last claim would have aborted on the underflow. Fixed by deriving
`rewards-credited` from the index in one step; pinned by the "reward rounding
across repeated syncs" unit test.
