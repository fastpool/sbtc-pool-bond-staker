# The pool as it is deployed on testnet

Every contract here is byte-for-byte what
`STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM` published at block 108893, modulo
the per-network address and name rewrites `scripts/build-network.mjs` applies
on the way out — on testnet the pool itself is published as `vault-1`.

That was checked against the chain rather than assumed:

```
curl -s https://api.testnet.hiro.so/v2/contracts/source/STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM/vault-1
```

with `SN3VMHX…` mapped back to `SM3VDX…` and `.vault-1` back to `.bond-staker`,
is `contracts/bond-staker.clar` below, with no differences. The same holds for
`bond-treasury`, `bond-bridge` and `esbee-dao`.

It is kept whole so the running system and the one being built in
`../contracts/` can be run, fuzzed and diffed side by side.

## What changed since

Two things, and they are unrelated to each other.

**The pool gained an early unstake.** A member can take committed sBTC back
mid-term instead of waiting for the roll that settles `request-exit` or for the
bond's twelve cycles to run out. `../README.md` has the costs; the header of
`../contracts/bond-staker.clar` lists every line it touches.

```
diff v1/contracts/bond-staker.clar contracts/bond-staker.clar
```

Note that the two are no longer laid out the same way: v1 keeps its invariants
in `v1/rendezvous/bond-staker.harness.clar` and concatenates them at fuzz time,
while the current contract carries them inline behind `;; #[env(simnet)]`. So
the diff is the early unstake *plus* that move.

| | |
| --- | --- |
| `unstake-sbtc-early` | the new entry point |
| `apply-early-unstake` | its ledger half, split out so the fuzzer can reach it |
| `get-early-unstake-preview` | what it would return, and what it would forfeit |
| `epochs.total-shares` | shrinks when a member leaves mid-term |
| `epochs.staked-sats` | carries the roll's scaling fraction, which `total-shares` used to |
| `epochs.credit-offset` | keeps an epoch's running credit flat when shares leave |
| `cancel-exit` | refuses an exit with no position behind it |

**The L1 ramp was rewritten.** `contracts/bond-bridge.clar` here is the 590-line
ramp that is on testnet today. `../contracts/bond-bridge.clar` is a different,
larger contract under the same name — the commit-and-reveal flow — and diffing
the two is not useful. `bond-treasury.clar` and `esbee-dao.clar` are unchanged
between the two projects.

## Running it

```
pnpm run test:v1            # unit tests, driving the real pox-5 in simnet
pnpm run fuzz:invariant:v1  # rendezvous, invariant mode
pnpm run fuzz:test:v1       # rendezvous, property mode
```

The root `vitest.config.ts` excludes `v1/`, so these are the only commands that
reach it. `v1/vitest.config.ts` points the same machinery at `v1/Clarinet.toml`,
where `bond-staker` is this contract and `bond-bridge` is the deployed ramp.

These tests are the ones that were committed alongside this code, not the
current suite — `../tests/` has moved on with both changes above.

## What is here

```
contracts/
  bond-treasury.clar        identical to ../contracts/bond-treasury.clar
  bond-staker.clar          the pool, without the early unstake
  bond-bridge.clar          the ramp on testnet today, not the rewritten one
  esbee-dao.clar            identical to ../contracts/esbee-dao.clar
rendezvous/
  bond-staker.harness.clar  invariants, properties, pox-5 stand-ins
  bond-escrow.clar          stands in for pox-5's custody
tests/
  bond-staker.test.ts       the suite as it was committed with this code
  helpers/bond-fixture.ts
settings/Devnet.toml        simnet wallets and their sBTC balances
Clarinet.toml               the manifest the tests run against
Clarinet-bond-staker.toml   the manifest `rv` picks up
scripts/build-rendezvous.mjs
vitest.config.ts
```

Nothing here is built or deployed by the root scripts. The sBTC requirements
are cached in `../.cache`, shared with the main project rather than fetched
twice.
