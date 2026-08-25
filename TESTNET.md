# Testnet run

What it takes to put this pool on public testnet. The repo side is ready, the
key and the funds are in place, and an earlier pool (`vault-1`, the code kept
under `v1/`) is already published. What is left is a deadline: bond 3 is the
last grant still in reach, and binding it closes around burn 8136.

Everything below was re-read off testnet at **burn height 7994**. Heights move;
re-check with the commands in [Re-reading the chain](#re-reading-the-chain)
before acting on any deadline here.

## What is already on chain

| | |
| --- | --- |
| pox-5 | `ST000000000000000000002AMW42H.pox-5` |
| sBTC | `SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1` |
| signer manager | `ST1B38CGQRPXEMRH7B66VXTS22DQTNMSW4YJJ7QK1.signer-manager` — registered with pox-5, so `initialize` will accept it |
| our address | `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM` |

**Bond 3 is the one to aim at.** It carries an allowlist grant for us and its
windows are still open:

| bond | starts (burn) | cycle | L1 unlock | allowance for `vault-1` and `vault-2` | staked so far |
| --- | --- | --- | --- | --- | --- |
| 3 | 9000 | 10 | 19350 | 100 000 000 sats (1 BTC) each | 19 500 sats, none of it ours |

Bonds 1 and 2 carry the same grants and are past their bind deadline under the
audited constants — see [Bond 3 is the last one in
reach](#bond-3-is-the-last-one-in-reach). Bond 4 onward do not exist and carry
no grant.

Bond 3 carries `stx-value-ratio = 1000`, `min-ustx-ratio = 500`,
`target-rate = 1000`. That prices the STX leg at **50 STX per whole BTC** —
0.5 STX for a 0.01 BTC test deposit. The contract reads all of this from
pox-5, so nothing needs configuring.

The cycle here is 900 burn blocks and bonds are spaced two cycles apart.

### The allowlist decides the contract's name

`get-bond-allowance` is keyed on the staker's *principal*, and the grants name
`STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM.vault-1` / `.vault-2`. pox-5 only
inserts allowances inside `setup-bond`, so these cannot be added to later or
pointed at a different name.

`vault-1` was published at block 108893 and carries the pool as it was before
members could unstake mid-term — the code now kept under `v1/`. So of the pair,
**`vault-2` is the free one, and that is what the build produces.** It is a
rename in the testnet build, not a code change, and `pnpm run build:testnet`
does it by default — the name is a property of the network, not a flag to
remember. See [What has to change](#what-has-to-change-in-the-repo).

### The siblings carry a `-2` too

A contract name can never be reused at an address, and `bond-treasury`,
`bond-bridge` and `esbee-dao` were all published alongside `vault-1`. Each is
wired to that pool by a constant that cannot be re-pointed, so the new pool
needs three of its own. `build:testnet` appends `-2` to all three, and rewrites
every reference between them.

The staker's own name is the exception: it is fixed by the grants, which is why
it is `vault-2` rather than `bond-staker-2`. That also rules out deploying from
a different address — the grants name *this* one.

Checked, not assumed:

```bash
D=STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM
for c in vault-2 bond-treasury-2 bond-bridge-2 esbee-dao-2; do
  curl -s -o /dev/null -w "$c %{http_code}\n" \
    https://api.testnet.hiro.so/v2/contracts/interface/$D/$c
done
# all four 404 — free

## Bond 3 is the last one in reach

> Written for the `vault-2` deployment, which predates `bind-next-bond`. The
> deployed contract still has `bind-bond(index, allocation, min-sats)`; the
> source in `contracts/` no longer does. Bond 3 came and went unstaked and the
> pool is bound to bond 4 — the sums below are kept because they are how the
> window is worked out, not because bond 3 is still live.

`stake` only runs once `BIND_NOTICE` (576 burn blocks) has elapsed since the
bind, and only inside the `STAKE_WINDOW` (288 blocks) before the bond starts.
Those two windows have to overlap, which is what put bonds 1 and 2 out of
reach — both started long before a bind today could clear its notice. Bond 3
still works:

```
now                        7994
bind by                    8136   <- leaves the whole stake window
absolute last bind         8423   <- leaves a sliver of it, and see below
notice ends                bind + 576
stake window               8712 .. 8999
bond 3 starts              9000
```

That is roughly 140 blocks — call it a day — to publish four contracts,
`initialize`, seat the DAO and bind. The publishes and the two calls are three
confirmed batches, so start early rather than at 8100.

`bind-next-bond` will not take the "sliver" line at all. It refuses any period
whose notice would run past the *opening* of the stake window — bind by
`start - 864` or not at all — because a bond period begins on a reward cycle
boundary and pox-5 refuses to register inside that cycle's prepare phase, so a
notice ending in the last blocks before the start is a bind that can never be
staked.

Missing it is not fatal, only slow: an unbound pool is inert and costs nothing
to leave standing, and the next grant would be a request to whoever runs
`setup-bond`. But there is no bond 4, so a miss means waiting on someone else.

**The roll target must exist before the roll.** A pool on bond 3 rolls to bond 9
(`NEXT_BOND_OFFSET` = 6), which does not exist and has no grant — confirmed
`none` at 7994. Unless bond 9 is created with `vault-2` allowlisted, the pool
winds down at the end of its term instead of rolling. Worth asking for
alongside anything else.

### Retiring `vault-1` first

`vault-1` is bound to bond 3 as well, with **15 000 000 sats queued** and
nothing staked — `epoch-count` is 0 and pox-5 custodies nothing for it. Its
grant is separate from `vault-2`'s, so it is not in the way; but the queued
deposits are real, and `withdraw` returns them in full for as long as the pool
never stakes. Do that before letting its bind lapse, or the sats sit in a pool
nobody is running.

## What has to change in the repo

Nothing — this is done. For the record, what it took:

1. **Every contract is named per network.** `scripts/build-network.mjs` carries
   the names alongside the two protocol addresses it already rewrote, with the
   same fail-if-anything-is-left check: the pool becomes `vault-2` because the
   grants say so, and the three siblings take a `-2` because their unsuffixed
   names are spent. It rewrites all 32 references between them and writes each
   contract out under its new file name. `Clarinet-testnet.toml` and the
   generated plan agree. Mainnet keeps every source name.

   `--staker-name` overrides the pool's name, for a grant that spells something
   else again. The build directory is emptied before each run, so a build under
   one name cannot leave the other lying next to it.

2. **The DAO is in the testnet pipeline.** It was missing from both the testnet
   manifest and the deployment plan, so it would not have shipped at all. The
   plan now publishes all four contracts and seats `esbee-dao-2` as an operator
   in a third batch.

3. **The fuzzing surface is stripped on the way out.** `bond-staker.clar`
   carries its invariants, properties and pox-5 stand-ins inline behind
   `;; #[env(simnet)]`. `build:testnet` removes those forms, so what lands in
   `build/testnet/` is the deployable contract and nothing but a short note
   saying what was taken out. Clarinet strips them again at publish, and
   `clarinet check` compiles the project both ways.

4. Nothing else. The pox-5 boot address in the source is already the testnet
   one; `build:testnet` only has to swap sBTC.

Verified: `clarinet check` passes both ways (9 contracts each), and the suite is
167 green with the fuzzer clean in both modes. Note that `clarinet check` cannot
be run against `Clarinet-testnet.toml` itself — testnet sBTC is not fetchable as
a requirement, so the manifest has none and every sBTC call reads as unresolved.
That is pre-existing; check the simnet flavour in `contracts/` instead.

## Prerequisites

Re-read at burn 7994. The first deployment cleared all of these; what is left
is the clock.

- **Seed phrase: in place.** `settings/Testnet.toml` holds an
  `encrypted_mnemonic_medium` for
  `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM` — the file is gitignored, and the
  first deployment signed with it.
- **STX at that address: 396.25.** Ample; the plan totals about 1.4 STX at the
  fee rate in `settings/Testnet.toml`, and the STX leg is 0.5 STX per 0.01 BTC
  deposited.
- **sBTC at that address: 0.** The earlier deposits moved it into `vault-1`'s
  treasury. Mint more through the testnet sBTC bridge before depositing, or
  withdraw from `vault-1` first — see [Retiring
  `vault-1`](#retiring-vault-1-first).
- **A reachable bond: bond 3, until burn 8136.** See [Bond 3 is the last one in
  reach](#bond-3-is-the-last-one-in-reach). This is the one that is actually
  scarce.

## The runbook

Everything but the clock is in place, so this can run now:

```bash
pnpm run build:testnet                     # -> build/testnet/vault-2.clar
pnpm run plan:testnet STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM
pnpm exec clarinet deployments apply --testnet \
  --manifest-path Clarinet-testnet.toml \
  --deployment-plan-path deployments/testnet-plan.yaml
```

That plan is the launch. It runs three batches, each confirmed before the next:

| batch | what |
| --- | --- |
| 0 | publishes `bond-treasury-2`, `vault-2`, `bond-bridge-2`, `esbee-dao-2`, in dependency order. The treasury and the bridge need no wiring: they identify each other through constants |
| 1 | `initialize(ST1B38…signer-manager, <deployer>)` — deployer-only, once. Also trusts that manager's code hash with no notice period, since nobody has deposited yet |
| 2 | `update-operator(<deployer>.esbee-dao-2, true)` — seats the DAO |

The deployer takes the operator seat in batch 1 rather than the DAO, because
the DAO cannot vote until the pool has staked: voting weight is committed
shares, and there are none before then. Batch 2 adds the DAO alongside it,
which is what puts the operator's powers — signer moves, the trusted list, who
the operators are, sweeps, and skipping a bond — in the members' hands.
`update-operator` refuses to change the caller's own entry, so the deployer
cannot retire itself here; doing that is a later call *from the DAO*, by vote.
Leaving both seated is the right state for a testnet run.

Then, as the operator:

| # | call | note |
| --- | --- | --- |
| 1 | `bind-bond(u4, u100000000, u0)` | the step with a deadline. Operator-only on the deployed `vault-2`; in the current source this is `bind-next-bond()`, permissionless and with no arguments. `deployments/testnet-bind-bond-4.yaml` is this call ready to apply |
| 2 | `deposit(<sats>)` | moves both legs; the STX is pulled in the same call |
| 3 | `stake(ST1B38…signer-manager)` | permissionless, inside the window, once the notice has run |

Check before the last step with `get-stake-preview` — it reports `short-ustx`
and whether the pool is `stx-limited` or `allocation-limited`. (The deployed
`vault-2` also reports `meets-floor`; the launch floor is gone from the
source.)
Confirm afterwards with pox-5's `get-total-sbtc-staked-for-bond(u3)` — which
already reads 19 500 sats from another staker, so compare the delta rather than
the total.

## Re-reading the chain

```bash
curl -s https://api.testnet.hiro.so/v2/info | python3 -c \
  "import json,sys; print('burn', json.load(sys.stdin)['burn_block_height'])"
```

For bond state and allowances, the probe used to gather the table above reads
`get-protocol-bond`, `bond-period-to-burn-height`, `get-bond-allowance` and
`get-total-sbtc-staked-for-bond` off `ST000000000000000000002AMW42H.pox-5`
through `@stacks/transactions`; run it from the project root so module
resolution finds the dependency.
