# Testnet run

What it takes to put this pool on public testnet, and the one thing that is
currently in the way.

Everything below was read off testnet at **burn height 6839**. Heights move;
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

**So `bond-staker` has to be deployed under the name `vault-1`.** That is a
rename in the testnet build, not a code change — see
[What has to change](#what-has-to-change-in-the-repo).

## The blocker: bond 2 is already out of reach

`stake` will only run once `BIND_NOTICE` (576 burn blocks) has elapsed since
`bind-bond`, and only inside the `STAKE_WINDOW` (288 blocks) before the bond
starts. For bond 2 those two windows no longer overlap:

```
bond 2 starts            7200
stake window             6912 .. 7199
latest useful bind-bond  7199 - 576 = 6623
now                      6839          <- already past
```

Binding today, the notice expires at 7415 — 215 blocks after the bond has
already started. Bond 1 started at 5400 and is live. **Neither existing grant
can be staked with the audited constants.**

This is the same trap `bind-bond` warns about in its comment, and it is the
contract behaving correctly: the notice exists so members can leave before an
operator's choice of signer manager binds them.

### Two ways out

**A. Ask for a grant on a later bond — preferred.** Whoever ran `setup-bond`
for bonds 1 and 2 creates bond 3 (or any later index) with `vault-1` on its
allowlist. Bond 3 would start at 9000, opening a window at 8712 and leaving
until 8136 to bind — comfortable. No code change, audited constants intact,
and it is the only path that tests what will actually be deployed.

**B. Lower `BIND_NOTICE` in a testnet-only build.** Reaches bond 2 with the
grants already in hand, at the cost of running something the audit did not
cover, in a race: four deploys, `initialize`, `bind-bond` and the deposits all
have to land before 7200, and `stake` inside `[6912, 7200)`. Fine as a
rehearsal of the mechanics; not evidence about the real contract.

Worth knowing either way: **the roll target must exist before the roll.** A
pool on bond 2 rolls to bond 8 (`NEXT_BOND_OFFSET` = 6), which does not exist
and has no grant. Unless it is created with `vault-1` allowlisted, the pool
winds down at the end of its term instead of rolling. Same for bond 3 → bond 9.

## What has to change in the repo

1. **Deploy `bond-staker` as `vault-1`.** `.bond-staker` is referenced by
   `bond-treasury.clar` (the `CONTROLLER` constant), `bond-bridge.clar` (6
   call sites) and `esbee-dao.clar` (7 call sites), plus `Clarinet-testnet.toml`,
   the deployment plan and `ui/app.js`. Best done by teaching
   `scripts/build-network.mjs` a `--staker-name` flag, alongside the address
   rewriting it already does — same mechanism, same fail-if-anything-is-left
   check.
2. Nothing else. The pox-5 boot address in the source is already the testnet
   one; `build:testnet` only has to swap sBTC.

## Prerequisites

- **`settings/Testnet.toml` holds a five-word placeholder mnemonic.** It needs
  the real seed phrase for `STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM`. Nothing
  can be signed until then.
- **STX at that address: currently 0.** Needed for fees and for the STX leg
  (0.5 STX per 0.01 BTC deposited).
- **sBTC at that address: currently none.** Mint some through the testnet sBTC
  bridge.

## The runbook

```bash
pnpm run build:testnet          # + the --staker-name vault-1 flag from step 1
pnpm exec clarinet deployments apply --testnet
```

Deploy in dependency order — `bond-treasury`, `vault-1`, `bond-bridge`,
`esbee-dao` — which is the order `Clarinet.toml` already lists. The treasury
and the bridge need no wiring: they identify each other through constants.

Then, as the deployer:

| # | call | note |
| --- | --- | --- |
| 1 | `initialize(ST1B38…signer-manager, <operator>)` | deployer-only, once. Also trusts that manager's code hash with no notice period, since nobody has deposited yet. Pass our own address as operator for a trial, or `.esbee-dao` for a community launch |
| 2 | `bind-bond(<index>, u100000000, u0)` | operator-only. `min-sats` **must** be `u0` — the launch floor is only accepted for bond 0 |
| 3 | `deposit(<sats>)` | moves both legs; the STX is pulled in the same call |
| 4 | `stake(ST1B38…signer-manager)` | permissionless, inside the window, once the notice has run |

Check before step 4 with `get-stake-preview` — it reports `meets-floor`,
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
