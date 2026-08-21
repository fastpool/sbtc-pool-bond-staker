# sbtc-pool-bond-staker

A pooled staker for [pox-5 Bitcoin Staking Bonds](https://www.stacks.co/blog/the-genesis-bond-starts-at-bitcoin-block-966-350).

Depositors put in sBTC and the STX the bond requires alongside it. The pool is
the pox-5 *staker* — the principal on the bond's allowlist, whose sBTC pox-5
custodies and whose STX pox-5 locks — and it rolls from one bond to the next
without ever unwinding the position.

## Audit scope

Pinned to **`0f8219cc`** (*feat: remove trust from operator*, 2026-08-17), and
the three contracts under `contracts/` at that commit:

    bond-treasury.clar
    bond-staker.clar
    bond-bridge.clar

Not in scope, and not deployed: `tests/`, `rendezvous/` (the escrow stand-in
the fuzzer uses), the `Simnet-only` section at the foot of `bond-staker.clar`
(stripped from every build — see
[rendezvous/README.md](rendezvous/README.md)), `scripts/`, `lib/` (bitcoin
encoding helpers the tests and the mainnet simulation share), and `v1/` (a
separate archived project with its own manifest and its own README; nothing
here reads it).

`contracts/` holds the simnet flavour of the two protocol addresses — see
[Networks](#networks). A deployment is byte-identical apart from those
rewrites, so audit the source and re-run `pnpm run build:<network>` to check
the built artefact against it.

## Contracts

| contract | role |
| --- | --- |
| `bond-treasury` | holds the pooled sBTC principal |
| `bond-staker` | the ledger: deposits, shares, the bond position, rewards |
| `bond-bridge` | the L1 bitcoin on-ramp and off-ramp |
| `esbee-dao` | optional: the operator seat, held by the members |

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
from the deposit because the two come apart, and they come apart in opposite
directions depending on how a member leaves.

**Leaving at a roll** — `request-exit`, or a position a roll could not carry —
keeps the shares. Their sats stayed staked for the whole of that bond's term,
so pox-5 pays on them to the end; the member holds their shares in the epoch
they were part of until it settles, and collects that bond's final rewards when
they arrive, while their sats and STX are already claimable.

**Leaving early** — `unstake-sbtc-early` — does not. pox-5 drops the unstaked
sats from the current reward cycle as well as every later one, so nothing more
is earned on them by anyone; the member's shares are struck out of the epoch in
the same call, and the epoch's `total-shares` with them. Nothing accrues to a
share that is no longer backed by staked sats.

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
| `bond-bridge.commit-btc-address` / `reveal-btc-address` | anyone | to join with L1 bitcoin, naming the address it will come from and paying the STX leg |
| `bond-bridge.complete-btc-deposit` | anyone | once the sBTC signers have swept it |
| `bond-bridge.claim-principal-to-btc` | a member | to take released principal out as bitcoin |
| `withdraw` | a depositor | until their deposit is staked |
| `stake` | **permissionless** | 288 burn blocks before the bound bond starts. First call opens epoch 0, later calls roll |
| `request-exit` / `cancel-exit` | a member | released at the next roll |
| `unstake-sbtc-early` | a member | committed sBTC back now, at a cost — see [Leaving before the term is up](#leaving-before-the-term-is-up) |
| `unstake-sbtc` | **permissionless** | once the live bond's 12 cycles are up. Winds the pool down |
| `sync-rewards` | anyone | recognises sBTC that has arrived |
| `claim-rewards` / `claim-principal` | anyone, paid to the member | as rewards settle / as principal is released |

`stake` and `unstake-sbtc` being permissionless is deliberate: the operator
chooses bonds and signers, but cannot strand the pool by doing nothing.

## Leaving before the term is up

`request-exit` settles at the next roll, and `unstake-sbtc` waits for the bond
to run out. `unstake-sbtc-early` does neither: it calls pox-5's own
`unstake-sbtc`, which takes any amount at any point in a bond, and the sats are
in the treasury and claimable in the same transaction. Partial or whole.

Three things follow from that, and `get-early-unstake-preview` reports all of
them before the fact:

- **The STX leg does not come with it.** pox-5 leaves locked STX alone on an
  unstake and frees it on the bond's normal unlock cycle. A member taking their
  whole position out is marked as exiting, and the roll releases their STX the
  way it would have released both legs.
- **Rewards the pool has not recognised yet are forfeited.** sBTC is split by
  shares at the moment `sync-rewards` recognises it, and the shares are gone the
  moment the call returns. `sync-rewards` is permissionless, so calling it first
  banks everything that has actually arrived.
- **The rest of the bond is forfeited outright**, because pox-5 drops the
  unstaked sats from the current reward cycle as well as every later one.

Nobody else pays for it: the pool's reward stream shrinks by exactly the shares
that left, and the remaining members' slice of what still arrives grows to
match. No member is diluted by someone else's exit, and none subsidises one.

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
themselves, in advance — by naming the **address** the bitcoin will come from:

1. `commit-btc-address(digest, sats)` — `digest` is
   `get-address-digest(address, salt)`, a hash of the address they will send
   from, with a salt they keep. This takes the STX leg — the one Stacks
   transaction they were always going to have to send, since the STX cannot come
   from bitcoin — and holds the pool's room.
2. `reveal-btc-address(address, salt)` — names the address and takes it, one
   bitcoin block after the commit at the earliest.
3. They send to `bond-treasury`, **from that address and no other**.
4. The sBTC signers sweep it and mint to the treasury.
5. `complete-btc-deposit(txid, vout, tx, parents)` — permissionless. `tx` is the
   deposit transaction as bitcoin hashes it (no witnesses) and `parents` is the
   transaction behind each of its inputs, in order. Checks the sats landed in
   the treasury, proves which address funded them, and has the ledger queue
   them.

**The order is the security argument**, and it is the same one version 1 made
about a txid. A claim made in the clear is exposed in the Stacks mempool before
it confirms: an onlooker could resend the same announcement with a higher fee,
take the address, and be credited for the bitcoin that followed. The commit
closes that window — a salted digest names nothing — and the reveal closes the
copy of it, since a commitment made after seeing a reveal is behind that reveal
and first reveal takes the address. The `REVEAL_DELAY` of one block stops a
commit and its reveal sharing a block, which would let an onlooker pair their
own commit with the reveal they just saw.

What the commitment cannot do is make an address secret that already is not: one
seen anywhere on bitcoin can be committed to by anyone at any time and revealed
first. That costs its owner nothing but the attempt — their reveal fails, they
have sent no bitcoin, and any other address will do; a fresh one is not knowable
at all. It costs the squatter the STX leg for as long as they hold it.

So the member has one rule: do not send until the reveal has confirmed, and then
send only from the address it revealed.

Commitments are keyed by member as well as digest, so lifting someone's digest
out of the mempool cannot stop them committing it themselves.

**Why an address rather than a transaction.** A txid only exists once the
transaction is built and signed, so version 1 needed a wallet that would sign
without broadcasting and a member who could drive it in two halves. An address
is something they already have, so steps 1 and 2 need nothing built and step 3
can be any wallet, any route, a plain "send" button.

### Proving whose bitcoin it was

`complete-btc-deposit` decides from the bytes alone, on a chain of txids:

- the sBTC registry names a txid it swept, which the signers vouch for;
- `tx` has to deserialize to that txid, so those are its real inputs;
- each parent has to deserialize to the txid its input names, so those are its
  real outputs — and the one being spent carries the scriptPubKey that locked it.

The deserializing is Clarity 6's `get-bitcoin-tx-output?`, which returns an
output's `scriptPubKey` and the transaction's canonical txid, so every link in
that chain is the node's own reading of the bytes rather than a hand-rolled
parser's. No merkle proof and no block header: the deposit is already anchored
by the registry, and everything else is anchored to it.

Every input has to be locked to the revealed address, not merely one of them. A
transaction funded from two addresses would otherwise be claimable by either,
and an onlooker who saw it on bitcoin could commit to whichever of the two was
still free. Requiring all of them leaves exactly one address that can claim a
transaction — and the member fixed which before they sent it.

Announcements are keyed by the scriptPubKey the address locks to rather than by
the address, so the three p2sh-shaped versions of one address are one
announcement rather than three that different members could hold.

Two further rules close what an address being public would otherwise open:

- an announcement must **predate the sweep** of the deposit it claims, so a
  watcher cannot read a funding address off a swept transaction and claim it
  after the fact;
- a `(txid, vout)` is credited **once**, whatever is announced afterwards.

What it costs is the bytes: a deposit may have at most 8 inputs, and each one
means handing its parent over too. Nothing bounds the parents — an output three
hundred down an exchange payout batch is read as readily as the first — and
either serialization will do, witnesses or not, so a client can pass an
explorer's hex through untouched. `get-funding-script` answers what a `complete`
would make of its arguments before anyone pays for it, and `get-txid` says which
transaction it read.

### Cancelling, and what a deposit is credited

Either state can be cancelled for its STX back — a commitment before the reveal
(`cancel-btc-commitment`), an announcement afterwards (`cancel-btc-deposit`) —
by the member at any time, by anyone once it has gone stale. The two wait
different lengths, and deliberately:

| | stale after | why |
| --- | --- | --- |
| commitment | `COMMIT_TTL`, 36 blocks (~6h) | nothing is in flight. Nothing has been sent, and the reveal normally follows one block later |
| announcement | `ANNOUNCE_TTL`, 1000 blocks (~1 week) | the bitcoin may be sent and waiting on the signers, and must never be cancelled from under its owner |

Both squat on allocation room while they stand, and both cost the squatter the
STX leg for the duration — but a week of that per unrevealed commit would be a
lot of leverage for the price.

Do not cancel a deposit already sent. Until the sweep the address can be
committed to again, but between the two it is anyone's to take, and after it
nothing can attribute those sats.

`complete` credits **what arrived**, not what was announced. The sBTC signers
take their bitcoin fee out of the deposit, so the mint is normally a little
smaller than the amount sent; the shortfall's allocation room goes back to the
pool and the member keeps the STX leg they paid, which returns to them as
released principal when they leave. An overpayment is not credited — the excess
is unattributed principal.

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

## Launching

The pool is started by whoever turns up, not by whoever deployed it. `stake` is
permissionless and always was, so there is no launch button for anyone to hold
— the only question is whether enough of a pool gathered to be worth starting,
and that is a number rather than a vote.

`bind-bond(index, allocation-sats, min-sats)` sets it. Below the floor, `stake`
returns `ERR_BELOW_LAUNCH_FLOOR (u129)`, nothing is committed, and every deposit
stays withdrawable. Half the allocation is a reasonable floor; zero starts on
whatever has gathered.

A floor is only accepted for **bond 0, the genesis bond** — everywhere else
`min-sats` must be zero, or `bind-bond` returns `ERR_INVALID_AMOUNT`. A launch
is the one moment where refusing to start is the better outcome. A floor on a
roll is not: miss it and the pool winds down at term, which is worse than
rolling light. Confining it to bond 0 also makes the check in `stake` inert
everywhere else without `stake` having to know which bond it is looking at.

    a. deploy the four contracts
    b. trust-signer-manager(hash) for each vetted signer manager
    c. update-operator(.esbee-dao, true)
    d. bind-bond(index, allocation, allocation / 2)
    e. members deposit; anyone calls stake once the floor is met
    f. the DAO votes the deployer key out

Note the ordering of (c) and (f). The DAO cannot vote before the pool has
staked — voting weight is committed shares, and there are none until then — so
the deployer necessarily holds the operator seat through the launch window and
the DAO retires it afterwards. During that window the deployer can bind a bond,
but `BIND_NOTICE` and the floor both apply, and members can withdraw right up
until `stake`. It is a real trust window, and it is bounded by the fact that
nothing the operator does can reach a deposit.

On testnet, see [TESTNET.md](TESTNET.md) — the allowlist grant is keyed on the
staker's principal, which decides what the contract has to be *named*.

## Esbee DAO

The operator seat can be held by a contract instead of a key. `esbee-dao` puts
five of the operator's powers behind a vote of the pool's own members — see
[brand/](brand/) for where the name comes from.

Binding is not among them, and deliberately so. `bind-bond` has to land inside
a window pox-5 fixes — after the bond is set up, and `BIND_NOTICE` before the
stake window closes — and a vote that takes a voting period plus an execution
delay to clear cannot be relied on to hit it. The seat can hold both: a key
that binds, and the DAO for everything a vote can be trusted to time.

    bond-staker.update-operator(.esbee-dao, true)   # sitting operator hands over
    bond-staker.update-operator(<old key>, false)   # ...and retires

A member's weight is the **square root of their committed sats**, so a holder
ten thousand times larger has a hundred times the say rather than ten thousand.
Only committed shares count: a queued deposit is withdrawable on demand, and
counting it would let anyone rent a majority for one transaction — deposit,
vote, withdraw.

Every proposal is a set of parameters for one operator call, raised through a
typed entry point (`propose-trust-signer`, `propose-signer-change`, …) so a
mandate for one power can never be spent on another. To land, it has to clear
all of:

| line | why |
| --- | --- |
| voting period (~2 days) | cannot be raised and settled before anyone looks |
| quorum (30% of turnout) | an empty room does not decide |
| supermajority (60% of votes cast) | a bare majority is not a mandate |
| execution delay (~1 day) | members who dislike the outcome can `request-exit` first |
| execution window (~1 week) | a stale mandate cannot be dusted off later |
| same epoch throughout | if the pool rolls, the membership that voted is not the one that would live with it |

`get-status(id)` returns every one of those as a field, so a UI can show which
line a proposal is still behind rather than a bare pass/fail. Proposing, voting
and executing all `print` a topic for indexers.

Execution is permissionless — the mandate is the vote, not the executor. Two
things the DAO cannot do: touch deposits, and remove itself from the operator
seat, since `bond-staker` refuses to change the caller's own entry.

## Simulating against mainnet

The test suite runs against simnet stand-ins. `stxer` runs the same steps
against a fork of real mainnet state — the pox-5 and sBTC that are actually
deployed — and lets steps be sent from principals we hold no key for, which is
the only way to model the bond admin's side of a launch. Nothing is signed or
broadcast.

    pnpm run simulate:genesis    # deploy -> allowlist -> bind -> deposit -> stake
    pnpm run simulate:bridge     # the same, joining over L1 instead

Each prints a per-step report and a stxer URL. The report matters: a failed
contract deploy still comes back as an `Ok` transaction whose result is
`(err none)`, with the reason only in `vm_error`, so a URL alone can look like
success.

The genesis run ends by reading pox-5 back — `get-total-sbtc-staked-for-bond`
and `get-bond-membership` — so the pool's registration is confirmed by the
protocol rather than by our own accounting.

**The bond does not exist yet.** `setup-bond` has not been called for any index,
so the simulation creates it, and every parameter under `BOND` in
`scripts/simulate-mainnet.mjs` is *our assumption*, not the protocol's. What is
being tested is the shape of the run, not the yields it implies.

**The genesis bond is index 1, not 0.** The bond starting at burn height 966,350
(reward cycle 143, [announced here][genesis]) is index 1; index 0 starts a cycle
earlier, at 962,150. The script resolves the index from the height rather than
assuming it. This matters beyond naming: a launch floor is only accepted on bond
0, so a pool binding the genesis bond starts on whatever turned up.

[genesis]: https://www.stacks.co/blog/the-genesis-bond-starts-at-bitcoin-block-966-350

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

The plan is three batches, each confirmed before the next: publish
`bond-treasury`, the pool, `bond-bridge` and `esbee-dao` in dependency order;
call `initialize`; then `update-operator(.esbee-dao, true)` to seat the DAO. The deployer takes the operator seat at `initialize` rather than the DAO,
because `bind-bond` is deliberately not behind a vote — see the launch sequence
above, where the DAO retires the key afterwards.

The deployer address is a required argument because it appears throughout and
`initialize` only accepts the contract's own deployer — a half-substituted plan
would deploy under one identity and initialize under another. Publish fees are
sized from the contract bytes at the fee rate in `settings/Testnet.toml`, and
come to about 1.24 STX for the whole plan.

### The pool's name is per network

**On testnet the pool is published as `vault-2`, not `bond-staker`.** pox-5 keys
a bond's allowlist on the staker's *principal*, and a grant is only ever
inserted by `setup-bond` — so a pool published under a name no grant mentions
can never stake. The testnet grants spell `<deployer>.vault-1` and
`<deployer>.vault-2`, and `vault-1` is taken, so `vault-2` is the name this
build targets. Its three siblings take a `-2` for the same reason: a contract
name cannot be reused at an address.

`build:testnet` therefore emits `build/testnet/vault-2.clar`, rewriting every
`.bond-staker` reference in the sibling contracts along with the file name; the
plan generator and `Clarinet-testnet.toml` agree. `build:mainnet` keeps
`bond-staker`. Nothing in `contracts/` changes, and the tests are unaffected.

To publish under some other name again, pass `--staker-name` to both commands
and rename the matching section in `Clarinet-testnet.toml`:

    pnpm run build:testnet -- --staker-name vault-3
    pnpm run plan:testnet ST3YOUR…DEPLOYER -- --staker-name vault-3

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
the fuzzing surface is put together and what it has caught.

`v1/` is a separate archived project with its own manifest, tests and scripts
(`pnpm run test:v1`, `pnpm run fuzz:invariant:v1`). It is not part of this one.

The signer-manager contracts the tests stake through come from the sibling
`fastpool-pox-5` project, referenced by relative path in `Clarinet.toml`.
