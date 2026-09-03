# Testnet run

What it takes to put this pool on public testnet as `vault-3`. Two earlier
pools are already published at our address — `vault-1` (the code under `v1/`)
and `vault-2` (the pool before binding became permissionless) — and neither
ever staked: each is still bound to a bond whose stake window has closed, with
everything it holds still queued. The repo side for a third is ready. What is missing is
not the clock this time but a **grant**: no bond pox-5 has set up allowlists
`vault-3`, and no bond a bind today could reach has been set up at all.

Everything below was re-read off testnet at **burn height 12607**. Heights
move; re-check with `pnpm run probe:testnet` (see [Re-reading the
chain](#re-reading-the-chain)) before acting on any of them.

## What is already on chain

| | |
| --- | --- |
| pox-5 | `ST000000000000000000002AMW42H.pox-5` — 900-block cycles, 100-block prepare phase, bonds spaced two cycles apart |
| sBTC | `SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1` |
| signer manager | `ST1B38CGQRPXEMRH7B66VXTS22DQTNMSW4YJJ7QK1.signer-manager` — registered with pox-5, so `initialize` will accept it |
| bond admin | `ST1V2ASRWGR81W7GBN1Z4W2JQKXJWCADPVZG30X45` — the only principal `setup-bond` accepts, so the only one who can grant us a bond |
| our address | `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM` |

Every bond set up so far has started, and every grant on them names a pool
that is already published:

| bond | starts (burn) | cycle | set up | allowlist | staked |
| --- | --- | --- | --- | --- | --- |
| 3 | 9000 | 10 | yes | `vault-1`, `vault-2`: 1 BTC each | 19 500 sats, not ours |
| 4 | 10800 | 12 | yes | `vault-1`, `vault-2`: 1 BTC each | 0 |
| 5 | 12600 | 14 | yes | `vault-1`, `vault-2`: 1 BTC each | 0 |
| 6 | 14400 | 16 | **no** | — | — |
| 7 | 16200 | 18 | **no** | — | — |

Every bond carries `stx-value-ratio = 1000`, `min-ustx-ratio = 500`,
`target-rate = 1000`, which prices the STX leg at **50 STX per whole BTC** —
0.5 STX per 0.01 BTC. The contract reads all of this from pox-5, so nothing
needs configuring, but a new bond can be priced differently.

The two pools stand where their last bind left them:

| pool | bound to | stake window | queued | of which ours |
| --- | --- | --- | --- | --- |
| `vault-1` | bond 3 | closed at 9000 | 5 000 000 sats, 2.5 STX | nothing |
| `vault-2` | bond 5 | closed at 12600 | 59 499 336 sats, 29.75 STX | 4 500 000 sats, 2.25 STX |

Neither has an epoch, and pox-5 custodies nothing for either. Everything in
them is still queued, and `withdraw` returns it in full — see [Retiring
`vault-2`](#retiring-vault-2-and-vault-1).

### The allowlist decides the contract's name

`get-bond-allowance` is keyed on the staker's *principal*. pox-5 only inserts
allowances inside `setup-bond`, from a list the bond admin passes, so a grant
cannot be added to a bond later and cannot be pointed at a different name. A
pool published under a name no grant mentions can never stake.

The grants so far spell `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM.vault-1` and
`.vault-2`, and both names are taken — a contract name can never be reused at
an address. So the third pool is **`vault-3`**, and the grant has to be asked
for under that name. `pnpm run build:testnet` produces it by default: the name
is a property of the network, not a flag to remember. Its three siblings take
a `-3` for the duller reason that their unsuffixed and `-2` names are spent
too; see [What has to change](#what-has-to-change-in-the-repo).

Checked, not assumed — all four free:

```bash
D=STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM
for c in vault-3 bond-treasury-3 bond-bridge-3 esbee-dao-3; do
  curl -s -o /dev/null -w "$c %{http_code}\n" \
    https://api.testnet.hiro.so/v2/contracts/interface/$D/$c
done
# all four 404 at burn 12607
```

## The ask: a bond with `vault-3` on it

`setup-bond` can only be called inside the two cycles before a bond starts —
1800 blocks — and `bind-next-bond` refuses any bond whose notice cannot run out
before its stake window opens, `BIND_NOTICE + STAKE_WINDOW + prepare` =
964 blocks ahead of the start. Between the two, a bond is grantable for the
whole of its setup window but bindable only for the first 836 blocks of it.

At ~4 minutes a burn block, the next two look like this:

| | bond 6 | bond 7 |
| --- | --- | --- |
| `setup-bond` opens | 12600 — open now | 14400 — Tue 8 Sep ~14:00 UTC |
| bind by | **13436 — Sat 5 Sep ~21:00 UTC** | 15236 — Thu 10 Sep ~23:00 UTC |
| notice ends | bind + 576 | bind + 576 |
| stake window | 14012 .. 14299 | 15812 .. 16099 |
| bond starts | 14400 — Tue 8 Sep ~14:00 UTC | 16200 — Sun 13 Sep ~16:00 UTC |
| L1 unlock | 25200 | 27000 |

So the request to the bond admin is one `setup-bond` call, for bond 6 if it
can land before burn 13436 and for bond 7 otherwise:

```clarity
(contract-call? 'ST000000000000000000002AMW42H.pox-5 setup-bond
  u6            ;; or u7
  u1000         ;; target-rate        -- whatever the admin prices it at
  u1000         ;; stx-value-ratio
  u500          ;; min-ustx-ratio
  0x21032853a683729ff79dc33bce675d83892cf0bad4fc15462225de42d7b88ed89292ac  ;; early-unlock-bytes, as on bonds 3-5
  (list { staker: 'STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM.vault-3, max-sats: u100000000 }))
```

A bond 6 or 7 from someone else's request is just as good, as long as the list
carries our line.

**The roll target needs a grant too, later.** A pool on bond 6 rolls to bond
12 (`NEXT_BOND_OFFSET` = 6; bond 13 from bond 7). That bond cannot be set up
until 1800 blocks before it starts — burn 23400 for bond 12 — so this is a
second request, months out, and worth saying now. Without it the pool winds
down at the end of its term instead of rolling. Nothing is lost that way; it
just stops.

## What has to change in the repo

Done. For the record:

1. **The names moved to the third generation.** `scripts/build-network.mjs`
   publishes the pool as `vault-3` and the siblings as `bond-treasury-3`,
   `bond-bridge-3`, `esbee-dao-3` by default, rewriting the 34 references
   between them. `scripts/make-testnet-plan.mjs` and `Clarinet-testnet.toml`
   agree. Both scripts take `--staker-name` and, new, `--suffix`, so a fourth
   generation is `-- --staker-name vault-4 --suffix -4` to both rather than an
   edit; the manifest's four `[contracts.*]` headers still have to be renamed
   by hand.

2. **The plans are for the current source.** `deployments/testnet-plan.yaml`
   is regenerated; `testnet-bind-next-bond.yaml` is the argument-free bind;
   `deposit.testnet-plan.yaml` points at `vault-3`. The old
   `testnet-bind-bond-4.yaml` — `bind-bond(index, allocation, min-sats)` on
   the deployed `vault-2` — is gone: that call is spent, and the source no
   longer has the function. `testnet-withdraw-vault-2.yaml` takes our deposit
   back out of the old pool.

3. **The chain can be re-read in one command.** `scripts/probe-testnet.mjs`
   prints the burn height, the bonds around it with their grants and bind
   deadlines worked out the way `bind-next-bond` works them out, and where
   each published pool stands. `pnpm run probe:testnet`.

The rest is as it was: the fuzzing surface is stripped on the way out, the
DAO is in the pipeline, `clarinet check` cannot be run against
`Clarinet-testnet.toml` itself (testnet sBTC is not fetchable as a
requirement), so check the simnet flavour in `contracts/` instead.

## Prerequisites

Re-read at burn 12607.

- **Seed phrase: in place.** `settings/Testnet.toml` holds an
  `encrypted_mnemonic_medium` for
  `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM` — the file is gitignored, and both
  earlier deployments signed with it.
- **STX at that address: 394.79.** Ample; the plan totals about 1.8 STX at the
  fee rate in `settings/Testnet.toml`, and the STX leg is 0.5 STX per 0.01 BTC
  deposited.
- **sBTC at that address: 0.005**, plus **0.045 recoverable** from `vault-2`
  with one `withdraw`. Enough for a 0.045 BTC test deposit; the testnet sBTC
  bridge for more.
- **A bond with `vault-3` allowlisted: none.** See [The ask](#the-ask-a-bond-with-vault-3-on-it).
  This is the one that is actually scarce, and it is not ours to make.

## The runbook

Publishing does not wait on the grant — the grant names a principal, and the
principal exists the moment the name is chosen — so the four contracts can go
up now, and the bond admin can read what they are granting to.

```bash
pnpm run build:testnet                     # -> build/testnet/vault-3.clar
pnpm run plan:testnet STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM
pnpm exec clarinet deployments apply --testnet \
  --manifest-path Clarinet-testnet.toml \
  --deployment-plan-path deployments/testnet-plan.yaml
```

That plan is the launch. It runs three batches, each confirmed before the next:

| batch | what |
| --- | --- |
| 0 | publishes `bond-treasury-3`, `vault-3`, `bond-bridge-3`, `esbee-dao-3`, in dependency order. The treasury and the bridge need no wiring: they identify each other through constants |
| 1 | `initialize(ST1B38…signer-manager, <deployer>)` — deployer-only, once. Also trusts that manager's code hash with no notice period, since nobody has deposited yet |
| 2 | `update-operator(<deployer>.esbee-dao-3, true)` — seats the DAO |

The deployer takes the operator seat in batch 1 rather than the DAO, because
the DAO cannot vote until the pool has staked: voting weight is committed
shares, and there are none before then. Batch 2 adds the DAO alongside it,
which is what puts the operator's powers — signer moves, the trusted list, who
the operators are, sweeps, and skipping a bond — in the members' hands.
`update-operator` refuses to change the caller's own entry, so the deployer
cannot retire itself here; doing that is a later call *from the DAO*, by vote.
Leaving both seated is the right state for a testnet run.

Then, once a bond with our grant exists — from anyone's key, since none of
these is operator-only:

| # | call | plan | note |
| --- | --- | --- | --- |
| 1 | `bind-next-bond()` | `deployments/testnet-bind-next-bond.yaml` | the step with a deadline: burn 13436 for bond 6. `find-next-bond` reports which bond it would take, `none` meaning the call would fail |
| 2 | `withdraw()` on `vault-2` | `deployments/testnet-withdraw-vault-2.yaml` | gets our 0.045 BTC and 2.25 STX back to deposit here |
| 3 | `deposit(u4500000)` | `deployments/deposit.testnet-plan.yaml` | moves both legs; the STX is pulled in the same call |
| 4 | `stake(ST1B38…signer-manager)` | — | permissionless, inside the window, once the notice has run |

Check before the last step with `get-stake-preview` — it reports `short-ustx`
and whether the pool is `stx-limited` or `allocation-limited`. Confirm
afterwards with pox-5's `get-total-sbtc-staked-for-bond`, or
`pnpm run probe:testnet`, which prints the pool's membership.

## Retiring `vault-2` (and `vault-1`)

`vault-2` holds 0.595 BTC queued from several depositors and `vault-1` a
further 0.05, none of it staked and none of it stakeable — both pools are
bound to bonds whose windows have closed, and a permissionless
`bind-next-bond` does not exist on either. Each deposit is its depositor's to
take back with `withdraw`, in full, for as long as the pool never stakes, which
is now forever. Ours is 0.045 BTC in `vault-2`; the rest belongs to whoever
tested alongside, and they should be told the pool moved.

Nothing else needs doing. An unbound pool is inert and costs nothing to leave
standing.

## Re-reading the chain

```bash
pnpm run probe:testnet             # vault-1, vault-2, vault-3
pnpm run probe:testnet vault-3     # any names to ask the grants about
```

It reads `get-pox-info`, `get-protocol-bond`, `bond-period-to-burn-height`,
`get-bond-allowance`, `get-total-sbtc-staked-for-bond` and
`get-bond-membership` off pox-5, and `get-pool`, `get-bound-bond` and
`get-config` off each published pool, all through the public API. The bind
deadlines it prints use the pool's own constants and pox-5's prepare length,
so they are the ones `bind-next-bond` will enforce.
