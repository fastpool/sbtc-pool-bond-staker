# sbtc-pool-bond-staker

A pooled staker for [pox-5 Bitcoin Staking Bonds](https://www.stacks.co/blog/the-genesis-bond-starts-at-bitcoin-block-966-350).

Depositors put in sBTC and the STX the bond requires alongside it. The pool is
the pox-5 *staker* — the principal on the bond's allowlist, whose sBTC pox-5
custodies and whose STX pox-5 locks — and it rolls from one bond to the next
without ever unwinding the position.

## Contracts

| contract | role |
| --- | --- |
| `bond-staker` | the pool: deposits, shares, the bond position, rewards |
| `bond-treasury` | holds the pooled sBTC principal; only `bond-staker` can move it |

Deploy the treasury first: `bond-staker` calls it, while the treasury's
reference back is only a principal value.

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
replaced it. An epoch therefore stays open for rewards until the next epoch has
a full reward cycle behind it, and `sync-rewards` credits the oldest open
epoch. That is what makes a leaver's final-cycle rewards reach them rather than
the new membership.

## Lifecycle

| call | who | when |
| --- | --- | --- |
| `initialize` | deployer, once | signer manager and operator |
| `bind-bond` | operator, once per bond | after the bond admin allowlists this contract. Opens deposits |
| `deposit` | anyone | while a bond is bound and has not started |
| `deposit-stx` | anyone | to raise the STX behind the pool's sats |
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

## Redeploying

Nothing about a specific bond is in the source — rate, ratio, start height,
unlock height and this contract's sats allowance are all read from pox-5 at
`bind-bond`. A new bond needs no code change, and neither does a fresh
deployment for a separate pool.

The one precondition the contract cannot arrange for itself is the allowlist:
the bond admin must have called `setup-bond` naming this contract, for the
first bond and for every roll.

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
