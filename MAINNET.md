# Mainnet run

What it takes to put this pool on mainnet as `esbee-dao-bond-staker-1` and into
the genesis bond. Unlike testnet, the grant is already there: the bond admin's
`setup-bond` for bond 1 allowlists
`SPFCGF789WX1B737VQYAQ6BG3QYVMJGPDKRKYK00.esbee-dao-bond-staker-1` for 5 BTC.
What is missing is the contract behind that name, and the clock on it is
short: the pool has to be published, initialized *and bound* by **burn height
965386**, or the genesis bond leaves without it and the next chance is bond 2,
which nobody has set up yet.

Everything below was re-read off mainnet at **burn height 965322**. Heights
move; re-check with `pnpm run probe:mainnet` before acting on any of them.

## What is already on chain

| | |
| --- | --- |
| pox-5 | `SP000000000000000000002Q6VF78.pox-5` — 2100-block cycles, 100-block prepare phase, bonds spaced two cycles (4200 blocks) apart |
| sBTC | `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4` |
| signer manager | `SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4.fastpool-max500-signer-manager` — the published Fast Pool manager, registered with pox-5, so `initialize` will accept it |
| bond admin | `SP72DMR3MJKS7RVBY33JVV7EEJSQ1PYDVKDP10FX` — the only principal `setup-bond` accepts |
| our address | `SPFCGF789WX1B737VQYAQ6BG3QYVMJGPDKRKYK00` — 99.56 STX, no sBTC |

| bond | starts (burn) | cycle | set up | allowlist | staked |
| --- | --- | --- | --- | --- | --- |
| 0 | 962150 | 141 | no | — | started without anyone |
| **1** | **966350** | **143** | **yes** | **`esbee-dao-bond-staker-1`: 5 BTC** | 450 000 sats, not ours |
| 2 | 970550 | 145 | no | — | — |
| 3–6 | 974750 … 987350 | 147 … 153 | no | — | — |

The genesis bond is index 1, not 0 — index 0 would have started a cycle
earlier and nobody set it up. Its terms are `target-rate = 300`,
`stx-value-ratio = 310237`, `min-ustx-ratio = 500`: the STX leg costs
**155.1185 STX per 0.01 BTC** (about 15 512 STX per whole BTC). The contract
reads all of this from pox-5 at run time; nothing is configured.

Twelve cycles long, it unlocks at burn 991550 — which is also where bond 7
would start, and bond 7 is the one the pool rolls into afterwards
(`NEXT_BOND_OFFSET` = 6). That needs a second grant, on a bond nobody can set
up before burn 987350. Not urgent; noted under [Later](#later).

## The clock

Derived from the pool's constants and pox-5's prepare length, at 10 minutes a
block from 965322:

| what | burn height | blocks away | roughly |
| --- | --- | --- | --- |
| **bind deadline** (`bind-next-bond` must have landed) | **965386** | **64** | **~11 h** |
| notice ends, stake window opens | 965962 | 640 | 4.4 days |
| stake window closes (prepare phase opens) | 966250 | 928 | 6.4 days |
| bond starts | 966350 | 1028 | 7.1 days |
| bond unlocks / bond 7 starts | 991550 | | ~6 months |

The bind deadline is start − prepare − `STAKE_WINDOW` − `BIND_NOTICE` =
966350 − 100 − 288 − 576. `find-next-bond` answers `none` one block later and
`bind-next-bond` fails with `ERR_BOND_NOT_FOUND (u103)`.

Deposits are open from the moment the bond is bound until `stake`; the pool
requires the STX leg to be paid alongside the sBTC (`get-required-ustx` says
how much), and every deposit can be withdrawn in full until `stake` is called.

## What was checked before this

- `pnpm test`: the full simnet suite, green.
- `pnpm run simulate:genesis` and `pnpm run simulate:bridge`: stxer dry runs
  against a fork of mainnet pinned at burn 965322, all steps clean. Deploy the
  six `-1` contracts, `initialize` with the real manager, `bind-next-bond`
  lands on bond 1 under the real grant (`max-sats u500000000`), a 0.01 BTC
  deposit asks for `u155118500` uSTX, and `stake` at 965964 goes into bond 1
  with pox-5 reporting 1 450 000 sats staked and our membership. Nothing was
  signed or broadcast.
- `pnpm run probe:mainnet`: the bond, grant and free names above.

## Runbook

Every step here is a real transaction paid by the deployer. Nothing in this
file runs one; each command below is to be run by hand once the numbers have
been re-read.

### 1. Build and plan

    pnpm run build:mainnet
    pnpm run plan:mainnet SPFCGF789WX1B737VQYAQ6BG3QYVMJGPDKRKYK00

`build/mainnet/` gets `esbee-dao-bond-staker-1.clar`, `bond-treasury-1.clar`,
`iou-bond-btc-1.clar`, `iou-bond-stx-1.clar`, `bond-bridge-1.clar` and
`esbee-dao-1.clar`: the simnet blocks stripped, the
pox-5 boot address left as mainnet's, every `.bond-staker` reference renamed.
The plan generator writes `deployments/mainnet-plan.yaml` with three batches:

1. publish the six contracts in dependency order (about 1.3 STX in fees at
   10 µSTX/byte);
2. `initialize('SPMPMA….fastpool-max500-signer-manager, 'SPFCGF…KRKYK00)` —
   manager and the deployer as first operator;
3. `update-operator('SPFCGF…KRKYK00.esbee-dao-1, true)` — seat the DAO.

`Clarinet-mainnet.toml` names the same six files. `settings/Mainnet.toml`
(gitignored) holds the deployer's encrypted mnemonic and points at
`https://api.hiro.so`.

### 2. Deploy

    clarinet deployments apply --mainnet \
      --manifest-path Clarinet-mainnet.toml \
      --deployment-plan-path deployments/mainnet-plan.yaml

Clarinet waits for each batch to confirm before sending the next. Expect three
Stacks blocks at the least; at the time of writing, allow an hour.

### 3. Bind — before 965386

    clarinet deployments apply --mainnet \
      --manifest-path Clarinet-mainnet.toml \
      --deployment-plan-path deployments/mainnet-bind-next-bond.yaml

Permissionless and argument-free; the pool walks to bond 1 on its own. Check
first that `find-next-bond` still says `(some u1)`:

    pnpm run probe:mainnet

and afterwards that `get-bound-bond` reads `bond-index u1, bound true,
max-sats u500000000, stake-closes-at u966250`. A bind that misses the deadline
does not fail loudly on chain — the pool just has nothing to bind to until
someone sets up bond 2 with our name on it.

### 4. Deposits — from the bind until `stake`

Deposits open in the block the bind confirms; the 576-block notice is a floor
under `stake`, not a gate on joining, so nobody has to wait for it. They close
when `stake` is called, which cannot happen before 965962 — at least four days
of guaranteed room, and up to 966249 if the operator waits.

`deposit(sats)` on `esbee-dao-bond-staker-1` moves `sats` of sBTC and
`get-required-ustx(sats)` of STX from the caller into the pool; both must be in
the caller's account. 0.01 BTC is 1 000 000 sats plus 155.1185 STX. Members
without sBTC can come in over bitcoin through `bond-bridge-1`
(`commit-btc-address` → two burn blocks → `reveal-btc-address` → send → the
sBTC signers sweep → `complete-btc-deposit`); see the README.

The deployer itself holds no sBTC and, after fees, about 97 STX — enough for
0.006 BTC's STX leg, none for the sBTC. A seed deposit needs funding first.

### 5. Stake — in 965962..966249

    stake('SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4.fastpool-max500-signer-manager)

Permissionless: anyone may call it once the window is open, and the manager
passed has to be the one `initialize` recorded. `stake` moves the pool's
queued sBTC and STX into pox-5 through the signer manager and opens epoch 0.
It runs once per bond — pox-5 refuses a second registration for the same bond
and there is no top-up — so it takes whatever is queued at that block, and
deposits after it fail with `ERR_NO_BOND_BOUND` until the next bond is bound.
Because anyone can call it, expect the book to close at 965962 unless every
depositor is in by then. A pool that has nothing queued when the window closes
has missed the bond.

## Later

- **Roll target.** Ask the bond admin to allowlist
  `SPFCGF789WX1B737VQYAQ6BG3QYVMJGPDKRKYK00.esbee-dao-bond-staker-1` on bond 7
  (starts 991550). `setup-bond` for it opens at burn 987350; the pool binds it
  by 990586. Without that grant the pool winds down when bond 1 unlocks, which
  is a clean exit, not a loss.
- **Retire the deployer's seat.** After `stake`, the DAO votes
  `update-operator('SPFCGF…KRKYK00, false)`. The deployer cannot do this to
  itself.
- **Bond 2** (starts 970550) is a second chance if the genesis bind is missed:
  it needs a `setup-bond` with our name, and the bind deadline for it is
  969586.

## Re-reading the chain

    pnpm run probe:mainnet                        # bonds, grants, our pool
    pnpm run probe:mainnet -- some-other-name     # grants for other names

`scripts/probe-chain.mjs mainnet` prints the burn height, pox-info, every bond
from the current one back by one and ahead by six with its set-up status,
staked sats, our grant and the bind-by / stake-window heights, then the pool's
`get-pool`, `get-bound-bond`, `get-config` and its pox-5 membership once it is
published.
