# Tokenising the bond treasury

**Shelved 2026-08-26, unbuilt.** Design notes for replacing `bond-treasury`
with a non-transferable [SIP-013][sip013] semi-fungible token, so that a
depositor holds something for their sats. Read against `bond-staker.clar` at
`f7e4f11`; line counts and call-site counts are from that revision and will
drift.

[sip013]: https://github.com/stacksgov/sips/blob/main/sips/sip-013/sip-013-semi-fungible-token-standard.md

## The short answer

Mint when sats become a member's claim on the pool. Burn when they leave the
pool to that member. Never mint or burn because the sats moved.

Five sites in total, and every other place sBTC moves in this codebase changes
*where the principal sits* or *which bucket it is in* rather than whose it is.
None of those touch supply.

That rule is what would make the token worth holding. A receipt that burned
when the pool staked would go dark for exactly the six months the position is
locked, which is the stretch you want a receipt for.

## What the treasury does today

Six obligations, and all six have to survive the swap. The fifth is the one
that is easy to drop.

- **It holds the pooled principal.** Its sBTC balance *is*
  `queued-sats + released-sats + withdrawing-sats`, plus whatever arrived
  unattributed.
- **It is the address to bridge to.** An sBTC deposit from L1 is a bare mint
  with no record of who sent it; it lands here and `bond-bridge` ties it to a
  member afterwards.
- **`payout` answers to `.bond-staker` alone** — to fund a bond, refund a
  withdrawal, or return principal.
- **`request-btc-withdrawal` answers to `.bond-bridge` alone**, and the
  treasury is the *requester* on purpose: the bridge refunds unspent fees to
  whoever asked, and that refund has to land as principal rather than reward.
- **It keeps the pool's own sBTC balance meaning "reward and nothing else".**
  That separation is what lets `get-unrecognized-rewards` be a subtraction
  instead of a reconciliation. Issue #1 was a hole in it, one call wide.
- **It is inert.** No admin, no upgrade path, no discretion.

A token contract that holds the sBTC and issues receipts against it keeps all
six. Folding the principal back into `bond-staker` to save a contract would
not: it reintroduces the issue #1 class of bug at every call site rather than
at one.

## Two constraints that shape everything

### The pool never iterates members

`stake` rolls the whole pool in constant work. It writes the pool totals and
one `epochs` entry, and it touches not one member record. Members are
reconciled lazily by `settle` the next time they are looked at, and there is no
member list to iterate anywhere in the contract.

So **no token operation may be required at a roll**. Anything per-member has to
be lazy and permissionless — the shape `settle-member`, `claim-rewards` and
`claim-principal` already have, where anyone may do it on anyone's behalf.

What that does *not* mean is that the work belongs inside `settle`. `settle` is
a `define-read-only`, and four read-only functions lean on it —
`get-settled-member`, `get-claimable-rewards`, `get-claimable-principal`,
`get-early-unstake-preview` — along with one invariant. It cannot become
state-changing without taking all five with it.

The work belongs at the **ten `map-set members` sites** instead, each of which
already holds the settled record at the moment it writes it. A private
`sync-position` called from each is mechanical, and `settle` stays pure.

### The vault cannot read the pool back

There is a tempting shape that does not exist: leave the ledger where it is,
and have the vault's `get-balance` call `bond-staker` for the settled truth, so
the token never lags. Clarity refuses it. `bond-staker` already calls
`.bond-treasury payout`, and the return call closes a cycle:

    error: CircularReference(["bb", "aa"])

A `define-constant` holding a principal is fine — that is why the current
three-contract wiring deploys at all. It is `contract-call?` that creates the
edge.

So the token state is **pushed, never pulled**. The vault keeps its own
balances, written only by the controller; the pool works out the truth and
tells it. Every figure the vault serves is exactly as fresh as the last time
that member was touched, and no fresher — which is why the sync above has to
sit at all ten write sites rather than the two or three that look sufficient.

## Mint and burn

| | site | why |
| --- | --- | --- |
| mint | `deposit` | sBTC arrives from the depositor and is credited to them. The first moment the sats are a member's claim |
| mint | `credit-bridged-deposit` | the L1 path's equivalent, once the signers have swept and the transaction is matched to its announcement |
| burn | `withdraw` | a queued deposit taken back before its bond opened |
| burn | `claim-principal` | released principal going out to the member |
| burn | `settle-bridge-withdrawal` | the same, leaving over the bridge to bitcoin instead |

**Not `reserve-bridged-deposit`.** An announced bridge deposit holds allocation
room and has already paid its STX leg, but no sBTC has arrived for it. Minting
there would overstate supply for as long as the sweep takes, and would mint
against a deposit that may never be broadcast. Mint on the credit, not the
announcement.

And none of these:

| site | what actually happens |
| --- | --- |
| `stake`, growing roll | treasury → pox-5. Custody moves; ownership does not |
| `stake`, shrinking roll | pox-5 → treasury. Same, in reverse |
| `stake`, the haircut | sats a roll could not carry go `bonded` → `released`. Still the member's; burnt later, at the claim |
| `unstake-sbtc` | wind-down. Every position becomes claimable, and nothing has left yet |
| `unstake-sbtc-early` | forfeits future rewards, not principal. `bonded` → `released`, same owner |
| `request-exit` / `cancel-exit` | a request. Nothing moves at all |

### What it buys

A single identity, checkable in one line and strictly stronger than the
treasury invariant it replaces:

    overall-supply == queued-sats + bonded-sats + released-sats + withdrawing-sats

Supply is the pool's total member principal *wherever it sits*. Today's
`invariant-treasury-covers-its-books` can only see the part that is not staked.

Rewards are never minted. They arrive at `bond-staker`, are split by shares,
and are paid out in sBTC. The token would be principal and only principal —
which is the same separation the treasury protects, restated.

### The other fungible part

SIP-013 wants a fungible token for balances *and* a non-fungible
`{token-id, owner}` tag alongside it, so wallets can write post-conditions on
identity as well as quantity. That tag is mechanical and unrelated to the
lifecycle above: mint it when a holder's balance for an id goes from zero, burn
it when it returns to zero, on every mint, burn and transfer. The reference
implementation's `tag-nft-token-id` is the whole of it.

## What the token id can mean

Id as the bound bond is right for most of a position's life, and for a reason
worth naming: the id's own lifecycle carries the position's for free.

- tokens under id N while bond N is unstaked — queued, withdrawable
- tokens under id N while bond N is live — committed
- tokens under id N once bond N is over — released, claimable

Queued becoming committed needs no transition at all: the deposit was minted
under the bond that was bound, and `stake` opens that same bond. The bond
starts; the id does not move.

It breaks at exactly one point. **The roll.** A member carried from bond N into
bond N+6 holds id-N tokens describing a position that now lives in bond N+6 —
and re-iding is per-member, which the constraint above says cannot happen at a
roll.

**A. The id is the cohort.** An id-2 token means "entered at bond 2, still in".
Never re-ided. Free, but two members with identical positions hold different
ids forever, ids proliferate with every bond, and the F in SFT stops meaning
anything.

**B. The id is the current bond.** Re-ided lazily: when `settled-epoch`
advances, burn the old id and mint the new. Costs the private sync at ten write
sites — `settle` itself is untouched. A holder nobody has touched since the
roll shows a stale id until someone settles them, which anyone may do,
permissionlessly.

**C. Normalise only on touch.** As B, but only on the claim paths. Staleness is
the resting state and nothing pretends otherwise. Cheaper than B, and the
read-onlys stop being trustworthy — hard to document honestly.

**Take B.** It is the only one where `get-balance(u8, alice)` means what a
reader assumes it means, and that assumption is the entire value of putting the
bond in the id.

One edge case for all three, worth a test either way: a bond that is bound,
takes deposits, and then goes unstaked because the window was missed. Those
depositors hold tokens for a bond that never ran. Under B, `settle` re-ids them
when the pool binds the next one; under A they sit on a dead id until they
withdraw.

## Non-transferable

`transfer` and `transfer-memo` refuse. Every existing rule in the pool holds
unchanged, and the job is the mint and burn sites plus the id work.

SIP-013 does not address non-transferable or restricted tokens at all. It
defines eight functions, and it pins four error codes for the transfer path —
`u1` insufficient balance, `u2` sender equals recipient, `u3` zero amount, `u4`
sender not authorised. So there are two things to get right rather than one.

- **Do not return `u4`.** It means "you are not the owner", and a caller who
  *is* the owner would read it as a bug in their own code. Use a dedicated
  error in the token's own range — each contract here owns a thousand
  (`iou-bond-btc` u6000, `iou-bond-stx` u7000), so `ERR_NOT_TRANSFERABLE`
  is `u6001` and `u7001`.
- **Implement the trait anyway.** Being listed is the entire point of minting a
  receipt. Say "non-transferable" in the SIP-016 metadata so a client that
  reads it can grey out the control rather than discovering the refusal on
  submit.

Keep the non-fungible `{token-id, owner}` tag even though its stated purpose is
post-condition coverage on transfers. With no transfers it earns its place
differently: it is what makes "this principal holds a position in bond 8"
visible as an object rather than as a number under an id nobody renders.

The transferable version is [its own note](sip-013-transferable.md), because
the standard's `transfer` turns out to be unable to reach the ledger it would
have to move.

## Invariants

- **Replace** `invariant-treasury-covers-its-books` with the supply identity
  above. Strictly stronger, and one line.
- **Keep** `invariant-sweep-cannot-reach-principal`, rewritten against supply
  rather than the books.
- **Add**, under option B: per-id supply for a live bond equals that epoch's
  `staked-sats`, less whatever has not been settled across yet.
- **Add**: `get-overall-balance(member)` equals their
  `queued + bonded + released` once settled.

And the lesson from issue #1 twice over: the fuzz harness has to mint and burn
wherever the real path does, or the new invariants are vacuous. `harness-lock`
needed `principal-in-transit` for exactly this reason.

## Build order

1. **Vendor the trait.** SIP-013 gives the eight signatures in its own text,
   and it could not be found deployed at any mainnet address tried — so define
   it in-tree, the way this repo already vendors pox-5's
   `signer-manager-trait`. Confirm it is genuinely absent before settling for
   that.
2. **Write the vault with the treasury's surface unchanged.** Same
   `get-balance`, `payout`, `request-btc-withdrawal`, same guards. Add its own
   `balances` map, the SIP-013 read-onlys over it, controller-only `mint` and
   `burn`, and `transfer` / `transfer-memo` returning `ERR_NOT_TRANSFERABLE`.
   Get it green against the existing treasury tests before touching the pool.
3. **Wire the five ownership sites.** No id semantics yet — a single hardcoded
   id is fine. The only goal of this stage is that supply matches the books.
4. **Add the supply invariant and let the fuzzer run.** Before the id work, not
   after: this is the stage that finds the site you missed.
5. **Then the id semantics.** Option B: a private `sync-position` at the ten
   `map-set members` sites, reconciling the token to the record being written.
   `settle` is not touched.
6. **Then the metadata** — `get-token-uri` per id, and the non-transferable
   flag a client can read.

One deployment consequence to plan around: `CONTROLLER` and `BRIDGE` are
constants, and the pool's own name is fixed by pox-5's allowlist. Replacing the
treasury means a fresh set of all four contracts — on testnet that is
`vault-3`, and the grant has to name it before anything can bind.

## Left open

- **Decimals.** Zero — the balance is satoshis, and a receipt that reports
  0.001 of a bond helps nobody. SIP-013 says decimals are "purely for display"
  and may vary per id, so nothing downstream depends on the answer.
- **Token URI per id.** The bond's terms already live in pox-5 and are read at
  the bind. Serving them as SIP-016 metadata would make each bond
  self-describing in a wallet, and is where the non-transferable flag goes.
- **Does the DAO get any power over the token?** Probably none. The treasury is
  inert today and that is a feature, not an omission — a mintable receipt with
  an admin is a different security model from the one the README argues for.
- **Does the vault keep the name `bond-treasury`?** It is a fresh deployment
  either way. A new name says the contract does a new thing; the old one keeps
  the README, the tests and the audit trail pointing at something
  recognisable.
