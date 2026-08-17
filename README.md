# sbtc-pool-bond-staker

A pooled staker for [pox-5 Bitcoin Staking Bonds](https://www.stacks.co/blog/the-genesis-bond-starts-at-bitcoin-block-966-350).

Depositors put in sBTC and the STX the bond requires alongside it. The pool is
the pox-5 *staker* — the principal on the bond's allowlist, whose sBTC pox-5
custodies and whose STX pox-5 locks — and it rolls from one bond to the next
without ever unwinding the position.

## Contracts

| contract | role |
| --- | --- |
| `bond-treasury` | holds the pooled sBTC principal |
| `bond-staker` | the ledger: deposits, shares, the bond position, rewards |
| `bond-bridge` | the L1 bitcoin on-ramp and off-ramp |

Deploy in that order — each calls the ones above it and is called by none of
them, so there is no cycle to break. `bond-treasury` names its two callers as
principal values, which do not have to exist yet.

Because the principal lives in the treasury, any sBTC `bond-staker` holds is
reward — there is no reserve to net off before splitting a payout. The STX leg
is the exception: pox-5 locks the *staker's* STX, so the pool holds it.

## The three quantities

    sats    the sBTC a member deposited   -- what they get back
    ustx    the STX a member deposited    -- what they get back
    shares  their weight in an epoch      -- what their rewards are split by

Shares are struck when a bond is staked or rolled, one share per committed
satoshi, mirroring how pox-5 weights bond rewards. They are held separately
from the deposit because the two come apart: a member who has left keeps their
shares in the epoch they were part of — and so still collects that bond's final
rewards when they arrive — while their sats and STX are already claimable.

## Epochs

Each bond the pool stakes into is an *epoch*: which bond, when it ran, how many
shares it carried, and its own reward pot.

    bond N            bond N+6           bond N+12
    |----- epoch 0 ----|----- epoch 1 ----|----- epoch 2 ----|
                       ^ roll             ^ roll

pox-5 makes rolling seamless — bond N's term ends at exactly the cycle bond N+6
begins, and registering for the new bond while still in the old one moves only
the *net difference* in sBTC and resizes the STX lock in place. A roll adds the
queued deposits, releases the members who asked to leave, and carries the rest
across untouched.

Rewards arrive as a bare sBTC transfer, and pox-5 settles a reward cycle only
once it has ended, so a bond's final cycle pays out *after* the roll that
replaced it. The pool therefore runs two clocks:

- **positions** move when the pool rolls, so a member's record never describes a
  position the pool has already moved on from;
- **rewards** move when an epoch settles — a cycle into the next bond — so the
  bond a member was actually in is the one that pays them.

The gap is bridged by a *stash*: when the roll carries a member out of an epoch
that is still paying, their claim on it is set aside and keeps drawing down
until that epoch settles. A member who leaves at the roll gets their principal
back immediately *and* their share of the bond's final cycle when it arrives.
There is only ever one stash to hold — an epoch settles a cycle into the next
one, and the roll after that is a whole bond term further on.

## Lifecycle

| call | who | when |
| --- | --- | --- |
| `initialize` | deployer, once | signer manager and operator |
| `bind-bond` | operator, once per bond | after the bond admin allowlists this contract. Opens deposits |
| `deposit` | anyone | while a bond is bound and has not started |
| `deposit-stx` | anyone | to raise the STX behind the pool's sats |
| `bond-bridge.announce-btc-deposit` | anyone | to join with L1 bitcoin, paying the STX leg |
| `bond-bridge.confirm-btc-deposit` | anyone | once the sBTC signers have swept it |
| `bond-bridge.claim-principal-to-btc` | a member | to take released principal out as bitcoin |
| `withdraw` | a depositor | until their deposit is staked |
| `stake` | **permissionless** | 288 burn blocks before the bound bond starts. First call opens epoch 0, later calls roll |
| `request-exit` / `cancel-exit` | a member | released at the next roll |
| `unstake-sbtc` | **permissionless** | once the live bond's 12 cycles are up. Winds the pool down |
| `sync-rewards` | anyone | recognises sBTC that has arrived |
| `claim-rewards` / `claim-principal` | anyone, paid to the member | as rewards settle / as principal is released |

`stake` and `unstake-sbtc` being permissionless is deliberate: the operator
chooses bonds and signers, but cannot strand the pool by doing nothing.

## A roll that does not fit

Two things can make a bond too small for everything queued up for it: the
allocation the bond admin granted, and the STX floor — every bond prices sats
in STX for itself, so one that opens after Bitcoin has gained on STX demands
more STX for the same sats than the pool was funded with.

Neither fails the roll. Missing the window is far worse than rolling light:
the position would have to run to term and wind down, and it can be missed
over a shortfall of a single satoshi. `stake` commits
`min(queued up, the allocation, what the STX supports)`, scales every member's
sats by the same fraction, and releases the remainder to them. `deposit-stx`
closes the gap beforehand if anyone would rather avoid the haircut, and
`get-stake-preview` shows what the roll would do before its window opens:

    eligible-sats  everything that wants in
    sats           what actually fits
    short-ustx     what would have to be deposited to carry it all
    scaled / stx-limited / allocation-limited

The STX is not scaled — it is the binding side, so all of it rides on. A
member scaled back comes out over-collateralised in STX rather than short, and
can `request-exit` if they would rather not.

The pool has the remainder back from pox-5 the moment it rolls, but a member
only sees it once the epoch they were in stops taking rewards, a cycle into
the new bond: a position is not carried out of an epoch while that epoch can
still pay. Asking to leave is the one exception — an exit is settled at the
roll, since it does not depend on what the epoch does next.

A bond that comes and goes unstaked can be replaced by `bind-bond`, so a
missed window costs one bond period rather than the pool's whole future.

## Joining and leaving with L1 bitcoin

An sBTC deposit is a bare mint: the signers credit whichever principal the
bitcoin transaction named and call nothing, so a deposit addressed to the pool
arrives with no record of who sent it. `bond-bridge` has the member tie it
themselves, in advance:

1. `announce-btc-deposit(txid, vout, sats)` — records the transaction they are
   about to broadcast and takes its STX leg. This is the one Stacks transaction
   they were always going to have to send, since the STX cannot come from
   bitcoin.
2. They broadcast, addressing the bitcoin to `bond-treasury`.
3. `confirm-btc-deposit(txid, vout)` — permissionless. Reads the sBTC registry,
   checks the sats landed in the treasury, and has the ledger queue them.

Announcing *before* broadcasting is what makes this safe: until the transaction
is out, nobody else can know its txid to announce it first. An announcement
holds allocation room and can be cancelled for its STX back until the sweep
lands — by the member at any time, by anyone after a week.

Going the other way, `claim-principal-to-btc(recipient, max-fee)` hands a
member's released principal to the sBTC signers to pay out on bitcoin. The
request is made by `bond-treasury`, not the bridge: a rejected request unlocks
sBTC back to the *requester*, and that has to land somewhere the pool counts as
principal rather than as reward. `reclaim-btc-withdrawal(request-id)` settles
the outcome — putting the full amount back on the member's claim if the signers
rejected it. The STX leg is unaffected and still comes back on Stacks.

Never bridge to `bond-staker` itself: sBTC arriving there is taken for reward
and split among the members. Anything that reaches the treasury without an
announcement is unattributed, and only the operator's
`sweep-unattributed-principal` can move it — an amount measured as the balance
*above* everything owed, so it can never reach member principal.

## Redeploying

Nothing about a specific bond is in the source — rate, ratio, start height,
unlock height and this contract's sats allowance are all read from pox-5 at
`bind-bond`. A new bond needs no code change, and neither does a fresh
deployment for a separate pool.

The one precondition the contract cannot arrange for itself is the allowlist:
the bond admin must have called `setup-bond` naming this contract, for the
first bond and for every roll.

## UI

    pnpm run ui        # http://localhost:8080

A buildless page for the whole flow — deposit with sBTC or with L1 bitcoin,
watch the pool, claim, leave. See [ui/README.md](ui/README.md).

## Networks

Two protocol addresses are baked into the source, because a Clarity
`contract-call?` target is fixed at deploy time and cannot be configured:

| | mainnet | testnet |
| --- | --- | --- |
| sBTC | `SM3VDXK3…` | `SN3VMHXE…` (same hash, other version byte) |
| pox-5 | `SP000000000000000000002Q6VF78` | `ST000000000000000000002AMW42H` |

Both are plain literals at every call site, and the build script rewrites them:

    pnpm run build:testnet     # -> build/testnet/
    pnpm run build:mainnet     # -> build/mainnet/

A `define-constant` would have worked for the calls made from public and
private functions — but *a read-only function may not call through a constant*,
and half the read-only API here reaches pox-5 for reward-cycle arithmetic.
Splitting the source between two mechanisms bought nothing, so everything is a
literal. The script fails rather than emit a build with an address left on the
wrong network.

`contracts/` holds the simnet flavour, which is what the tests run against:
mainnet-encoded sBTC, since simnet mirrors mainnet's deployment, and the
testnet-encoded boot address. Nothing else changes between networks — cycle
lengths, bond start heights and the bond's pricing are all read from pox-5 at
run time, and testnet's are 900-block cycles rather than simnet's 1050.

## Trusting the operator with as little as possible

The operator binds each bond and picks the signer manager. It never touches
deposits, and it cannot stall the pool: `stake`, `unstake-sbtc`, `sync-rewards`
and both claims are permissionless, so members can always get out without it.

The sharp edge is the signer manager, because that is where rewards flow —
pox-5 pays the manager, the manager pays the pool. A manager that simply never
pays costs the members a bond's rewards. So the operator cannot name one
freely:

| call | who | when it takes effect |
| --- | --- | --- |
| `trust-signer-manager(code-hash)` | operator | once the pool rolls into its next bond |
| `distrust-signer-manager(code-hash)` | operator | at once |
| `update-bond-registration(new, old)` | operator | only onto a hash trusted before the live epoch was staked |
| `update-operator(who, enabled)` | operator | at once, but never on your own entry |

Adoption is pinned to the **roll**, not to a number of blocks, because the roll
is the only moment a member can leave. A delay measured in cycles would give
notice a member could not act on: `request-exit` is honoured at the next roll,
which may be six months out. A hash that was already on the list when the epoch
was staked can be moved onto at once — that is the emergency switch, for a
manager that stops signing.

`bind-bond` carries the same idea: `stake` will not run until `BIND_NOTICE`
(576 burn blocks, ~4 days) has passed since the bond was bound, so nobody is
carried into terms they had no chance to read and exit over. Bind too late and
the bond simply cannot be staked — deposits stay withdrawable and the operator
binds the next one along.

The operator is a set with an enabled flag, following the signer manager's
convention down to refusing to change your own entry. Handing over is two
moves: the sitting operator enables the newcomer, the newcomer retires the old
key. No single key can lock itself out, or lock everyone else out.

`get-signer-manager-hash(principal)` reads the hash off chain state, so what is
vetted and what is committed to are the same bytes. `trust-signer-manager`
takes a hash rather than a principal, so a contract can be vetted before it is
deployed. The manager chosen at `initialize` is trusted from cycle 0 — nobody
has deposited yet, so there is nothing to give notice about.

Adding is slow and removing is instant, which is the right way round: removal
only ever narrows what the operator can do.

## Deploying

    pnpm run build:testnet
    pnpm run plan:testnet ST3YOUR…DEPLOYER      # -> deployments/testnet-plan.yaml
    clarinet deployments apply --testnet \
      --manifest-path Clarinet-testnet.toml \
      --deployment-plan-path deployments/testnet-plan.yaml

Needs a funded seed phrase in `settings/Testnet.toml` (gitignored;
`clarinet deployments encrypt` keeps it out of plaintext).

`deployments/testnet-plan.yaml` is checked in as a template with `<DEPLOYER>`
placeholders, so the syntax is there to read before you have an address;
regenerating overwrites it in place (`--template` puts it back).

The plan is two batches: publish `bond-treasury`, `bond-staker`, `bond-bridge`,
then call `initialize` once those are confirmed. The deployer address is a
required argument because it appears in six places and `initialize` only
accepts the contract's own deployer — a half-substituted plan would deploy
under one identity and initialize under another. Publish fees are sized from
the contract bytes at the fee rate in `settings/Testnet.toml`.

`initialize` binds the pool to a signer manager, which must already be
registered with pox-5. The default is
`ST1B38CGQRPXEMRH7B66VXTS22DQTNMSW4YJJ7QK1.signer-manager` — of the three in
testnet's signer set it has the largest delegation and stays in through cycle
10. Pass a different one as the second argument if that changes.

Deploying gets you an address, not a working pool: `bind-bond` returns
`ERR_NOT_ALLOWLISTED (u104)` until the bond admin names this contract in a
`setup-bond`, and pox-5 only writes allowances there, so it has to be a bond
that has not been created yet.

## Tests

    pnpm test                # unit tests, driving the real pox-5 in simnet
    pnpm run fuzz:invariant  # rendezvous, invariant mode
    pnpm run fuzz:test       # rendezvous, property mode

The unit tests stand up real pox-5 bonds: simnet's bond admin is the boot
address the pox-5 source names, so the fixture can call `setup-bond` and
allowlist the pool. See [rendezvous/README.md](rendezvous/README.md) for how
the fuzzing harness is put together and what it has caught.

The signer-manager contracts the tests stake through come from the sibling
`fastpool-pox-5` project, referenced by relative path in `Clarinet.toml`.
