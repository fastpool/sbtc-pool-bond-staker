# Testnet run

What it takes to put this pool on public testnet. The repo side is ready and
the plan is to deploy now and bind later; what is left is a seed phrase and
some funds.

Everything below was re-read off testnet at **burn height 6847**. Heights move;
re-check with the commands in [Re-reading the chain](#re-reading-the-chain)
before acting on any deadline here.

## What is already on chain

| | |
| --- | --- |
| pox-5 | `ST000000000000000000002AMW42H.pox-5` |
| sBTC | `SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1` |
| signer manager | `ST1B38CGQRPXEMRH7B66VXTS22DQTNMSW4YJJ7QK1.signer-manager` — registered with pox-5, so `initialize` will accept it |
| our address | `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM` |

Two bonds exist, and both carry an allowlist grant for us:

| bond | starts (burn) | cycle | L1 unlock | allowance for `vault-1` and `vault-2` | staked so far |
| --- | --- | --- | --- | --- | --- |
| 1 | 5400 | 6 | 15750 | 100 000 000 sats (1 BTC) each | 0 |
| 2 | 7200 | 8 | 17550 | 100 000 000 sats (1 BTC) each | 0 |

Both bonds carry `stx-value-ratio = 1000`, `min-ustx-ratio = 500`,
`target-rate = 1000`. That prices the STX leg at **50 STX per whole BTC** —
0.5 STX for a 0.01 BTC test deposit. The contract reads all of this from
pox-5, so nothing needs configuring.

The cycle here is 900 burn blocks and bonds are spaced two cycles apart.

### The allowlist decides the contract's name

`get-bond-allowance` is keyed on the staker's *principal*, and the grants name
`STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM.vault-1` / `.vault-2` — neither of
which is deployed (the address has no transactions at all). pox-5 only inserts
allowances inside `setup-bond`, so these cannot be added to later or pointed at
a different name.

**So to use either existing grant, `bond-staker` has to be deployed under the
name `vault-1`.** That is a rename in the testnet build, not a code change, and
`build:testnet -- --staker-name vault-1` now does it — see
[What has to change](#what-has-to-change-in-the-repo).

Note the converse, which matters for the preferred path below: a *fresh* grant
can name anything, so a bond created with `<deployer>.bond-staker` on its
allowlist needs no rename at all.

## The blocker: bond 2 is already out of reach

`stake` will only run once `BIND_NOTICE` (576 burn blocks) has elapsed since
`bind-bond`, and only inside the `STAKE_WINDOW` (288 blocks) before the bond
starts. For bond 2 those two windows no longer overlap:

```
bond 2 starts            7200
stake window             6912 .. 7199
latest useful bind-bond  7199 - 576 = 6623
now                      6847          <- already past
```

Binding today, the notice expires at 7423 — 223 blocks after the bond has
already started. Bond 1 started at 5400 and is live. **Neither existing grant
can be staked with the audited constants.**

This is the same trap `bind-bond` warns about in its comment, and it is the
contract behaving correctly: the notice exists so members can leave before an
operator's choice of signer manager binds them.

### Two ways out

**Chosen: A, split in two.** The pool ships first and binds later. Publish the
four contracts, `initialize`, and seat the DAO as soon as the account is
funded; `bind-bond` waits for a grant on bond 3 or later.

Deploying commits the pool to nothing. Without a bind there is no bond, no
deposits, and nothing at risk -- an unbound pool is inert, and the audited
constants stay exactly as they are. It also means the grant, when it is asked
for, can name the contract that is already on chain.

**A. Ask for a grant on a later bond — preferred.** Whoever ran `setup-bond`
for bonds 1 and 2 creates bond 3 (or any later index) with our staker on its
allowlist. Bond 3 would start at 9000, opening a window at 8712 and leaving
until 8136 to bind — comfortable. No code change, audited constants intact,
and it is the only path that tests what will actually be deployed. Since the
grant is new it can name `<deployer>.bond-staker` directly, so this path does
not need the rename either.

Bond 3 does not exist yet: at 6847 the chain still has only bonds 1 and 2.
Nothing on our side can create it — `setup-bond` is the protocol operator's
call — so this path starts with a request, not a deploy.

**B. Lower `BIND_NOTICE` in a testnet-only build.** Reaches bond 2 with the
grants already in hand, at the cost of running something the audit did not
cover, in a race: four deploys, `initialize`, `update-operator`, `bind-bond`
and the deposits all have to land before 7200, and `stake` inside
`[6912, 7200)`. This is the path that needs `--staker-name vault-1`. Fine as a
rehearsal of the mechanics; not evidence about the real contract.

At 6847 there are ~350 burn blocks left before bond 2 starts — call it two to
three days. Lowering the notice to `u36` would move the bind deadline to 7163
and leave the window intact.

Worth knowing either way: **the roll target must exist before the roll.** A
pool on bond 2 rolls to bond 8 (`NEXT_BOND_OFFSET` = 6), which does not exist
and has no grant. Unless it is created with `vault-1` allowlisted, the pool
winds down at the end of its term instead of rolling. Same for bond 3 → bond 9.

## What has to change in the repo

Nothing — this is done. For the record, what it took:

1. **The pool can be published under any name.** `scripts/build-network.mjs`
   takes `--staker-name`, alongside the address rewriting it already did and
   with the same fail-if-anything-is-left check. It rewrites the 17 `.bond-staker`
   references — 1 in `bond-treasury.clar` (the `CONTROLLER` constant), 7 in
   `bond-bridge.clar`, 9 in `esbee-dao.clar` — and writes the contract out
   under the new file name. `scripts/make-testnet-plan.mjs` takes the same flag,
   and the UI's pool name is a field rather than a constant.

   The build directory is now emptied before each run, so a build under one
   name cannot leave the other one lying next to it.

   One manual step is left: `Clarinet-testnet.toml` names its contracts in
   section headers, so a rename means editing `[contracts.bond-staker]` and its
   path there to match. The file says so.

2. **`esbee-dao` is in the testnet pipeline.** It was missing from both the
   testnet manifest and the deployment plan, so the DAO would not have shipped
   at all. The plan now publishes all four contracts and seats the DAO as an
   operator in a third batch.

3. Nothing else. The pox-5 boot address in the source is already the testnet
   one; `build:testnet` only has to swap sBTC.

Verified: `clarinet check` passes on the renamed contracts (4 checked, warnings
only), and the suite is 112 green. Note that `clarinet check` cannot be run
against `Clarinet-testnet.toml` itself — testnet sBTC is not fetchable as a
requirement, so the manifest has none and every sBTC call reads as unresolved.
That is pre-existing; check the simnet flavour in `contracts/` instead.

## Prerequisites

Still open as of burn 6847, and none of them can be resolved from inside the
repo:

- **`settings/Testnet.toml` holds a five-word placeholder mnemonic.** It needs
  the real seed phrase for `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM`. Nothing
  can be signed until then — the file is gitignored, so it has to be filled in
  locally.
- **STX at that address: still 0.** Needed for fees — the plan totals 1.15 STX
  at the fee rate in `settings/Testnet.toml` — and for the STX leg (0.5 STX per
  0.01 BTC deposited).
- **sBTC at that address: still none.** Mint some through the testnet sBTC
  bridge.
The first three gate the deploy. A fourth gates only `bind-bond`, which is why
it is not in the way of shipping:

- **A reachable bond.** See [The blocker](#the-blocker-bond-2-is-already-out-of-reach):
  bonds 1 and 2 are both past their bind deadline under the audited constants,
  and bond 3 does not exist yet.

## The runbook

Once the seed phrase and the funds are in place, and a bond we can actually
reach exists:

```bash
pnpm run build:testnet                     # add: -- --staker-name vault-1
pnpm run plan:testnet STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM
pnpm exec clarinet deployments apply --testnet \
  --manifest-path Clarinet-testnet.toml \
  --deployment-plan-path deployments/testnet-plan.yaml
```

That plan is the launch. It runs three batches, each confirmed before the next:

| batch | what |
| --- | --- |
| 0 | publishes `bond-treasury`, the pool, `bond-bridge`, `esbee-dao`, in dependency order. The treasury and the bridge need no wiring: they identify each other through constants |
| 1 | `initialize(ST1B38…signer-manager, <deployer>)` — deployer-only, once. Also trusts that manager's code hash with no notice period, since nobody has deposited yet |
| 2 | `update-operator(<deployer>.esbee-dao, true)` — seats the DAO |

The deployer takes the operator seat in batch 1 rather than the DAO, because
`bind-bond` is deliberately not behind a vote: a bond has to be bound inside the
window pox-5 allows, which a voting period, a delay and a quorum cannot be
relied on to hit. Batch 2 then adds the DAO alongside it, which is what puts the
other four operator powers — signer moves, the trusted list, who the operators
are, and sweeps — in the members' hands. `update-operator` refuses to change the
caller's own entry, so the deployer cannot retire itself here; doing that is a
later call *from the DAO*, by vote. Leaving both seated is the right state for a
testnet run, since only the keyed operator can bind.

Then, as the operator:

| # | call | note |
| --- | --- | --- |
| 1 | `bind-bond(<index>, u100000000, u0)` | operator-only. `min-sats` **must** be `u0` — the launch floor is only accepted for bond 0 |
| 2 | `deposit(<sats>)` | moves both legs; the STX is pulled in the same call |
| 3 | `stake(ST1B38…signer-manager)` | permissionless, inside the window, once the notice has run |

Check before the last step with `get-stake-preview` — it reports `meets-floor`,
`short-ustx` and whether the pool is `stx-limited` or `allocation-limited`.
Confirm afterwards with pox-5's `get-total-sbtc-staked-for-bond(<index>)`.

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
