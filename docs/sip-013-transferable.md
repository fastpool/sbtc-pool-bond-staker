# Trading bond positions

**Shelved 2026-08-26, unbuilt.** The transferable version of
[the receipt token](sip-013-receipt-token.md). Read that first — the mint and
burn rule, the two constraints and the id question are settled there and none
of it is redone here. Against `bond-staker.clar` at `f7e4f11`.

## What carries over

Transferability changes who holds a position. It does not change when supply
moves.

The five sites from the first note are untouched: mint at `deposit` and
`credit-bridged-deposit`, burn at `withdraw`, `claim-principal` and
`settle-bridge-withdrawal`. A transfer moves a balance between holders and
leaves `overall-supply` exactly where it was. So the first note is a strict
prefix of this one — nothing built there is thrown away, and the supply
invariant it establishes becomes the thing that proves transfers are
conservative.

One answer does harden. The id question offered a cohort id as the cheap
option; here it stops being available. Two members holding economically
identical positions under different ids cannot trade against each other, and a
token that cannot be priced against its own kind is not tradeable in any useful
sense. **The id has to be the bond the position is currently in**, re-ided
lazily at the ten write sites.

## The wall

SIP-013 fixes the shape of a transfer:
`(transfer (uint uint principal principal) (response bool uint))`. It lives in
the token contract, and it takes no trait parameter — so the contract
implementing it can only reach another contract by naming it outright.

A transfer of a bond position has to move `shares`, three `ustx` legs and a
reward index, all of which live in `bond-staker`'s `members` map. And
`bond-staker` already calls `.bond-treasury payout`. Naming it back closes the
cycle Clarity refuses:

    error: CircularReference(["bb", "aa"])

Which is the whole reason this is a second note rather than a paragraph in the
first. Four ways out, and they are not close in cost.

**A. Bespoke `transfer-position` on the pool**, with the vault's SIP-013
`transfer` still refusing. Cheapest by far, and no wallet or marketplace can
move the token — only your own front end. Advertising the trait while refusing
its one mutator is worse than not advertising it. *Skip.*

**B. Invert the edge with a trait**: the vault names the pool, and the pool
reaches the vault only through `<vault-trait>`. Every pool entry point that
moves principal grows a trait argument — about eight, plus `bond-bridge`. The
ledger stays where it is. **Take this one.**

**C. Move the ledger into the vault**; the pool keeps pox-5 and the epochs.
Correct by construction and a genuine rewrite: `settle`, the `members` map, the
ten write sites and every member read-only change house, and epoch data has to
be pushed at `sync-rewards` and `stake`. *Later, if ever.*

**D. Merge the pool and the treasury into one contract.** No cycle at all, and
it costs the separation the treasury exists for: the pool becomes the address
bridged to, and "whatever sBTC is here is reward" stops being available. That
simplification is the one issue #1 was a hole in. *Skip.*

### Why B works

A trait parameter is dispatched dynamically and creates no dependency edge —
but `use-trait` creates one on whichever contract *defines* the trait. So the
trait cannot live in the vault. Put it in a third, definition-only contract and
the graph has no cycle in it:

    traits  <--  pool      pool calls the vault only through <vault-trait>
    traits  <--  vault
    pool    <--  vault     the vault names the pool outright, which is
                           the direction transfer needs

This was checked rather than reasoned about. Three contracts in that
arrangement give `3 contracts checked`; the two-contract version gives
`CircularReference`.

The pool-side idiom already exists in this codebase. `stake` takes
`(manager <signer-manager-trait>)` and asserts
`(is-eq (contract-of manager) (var-get signer-manager))`; the vault argument is
the same move, checked the same way. What changes is the surface: `deposit`,
`withdraw`, `stake`, `unstake-sbtc`, `unstake-sbtc-early`, `claim-principal`,
`sweep-unattributed-principal` and the bridge paths all grow an argument
callers have to pass and post-conditions have to account for.

## What a transfer actually moves

The token carries sats. A position is sats, STX, reward weight and two kinds of
claim, and a transfer that moves the first alone produces nonsense.

| moves with the sats | stays with the seller |
| --- | --- |
| `shares`, pro rata — reward weight follows the principal or the buyer earns nothing | `pending` — banked by settling first |
| `bonded-ustx` / `queued-ustx` / `released-ustx`, pro rata | `tail-shares` / `tail-index` — a claim on a *previous* epoch, which the buyer was never in |
| | `reward-index` — the buyer starts at the epoch's current index |

The sequence is: settle both parties, then move sats, shares and the STX legs
together, then reconcile the token. Settling first is what makes the rest
automatic — the seller's accrual is banked into `pending` where the transfer
cannot touch it, and the buyer starts at the current index, so they earn from
the moment they hold and not a block earlier.

## Hazards

The ones that bite, in rough order of how much they cost if missed.

**The STX leg.** Move sats alone and the seller is left collateralising the
buyer's position with STX they cannot get back until the bond unlocks. It is
not an asset move — pox-5 locks the *pool's* STX, so this is bookkeeping in the
members map — which is exactly why it is easy to forget.

**Rounding direction on a partial transfer.** Pro-rata `ustx` has to floor
toward the recipient with the remainder left on the sender. Round the other way
and the pool owes more STX than it holds, and the last member to claim finds it
short — the same failure the README already documents for `total-credited`.

**`transfer` is a new mutator, and it is callback-reachable.** pox-5 hands
control to the signer manager inside `register-for-bond`. Anything the manager
can call during that window can act on a pool mid-roll. `transfer` has to
refuse while `principal-in-transit` is set, for the same reason `sync-rewards`
does. Issue #1 is the worked example; do not make the auditor find the second
one.

**Post-conditions cannot see the position.** SIP-013 gives a buyer `ft` and
`nft` events to post-condition on. The shares and the STX move invisibly inside
the pool's map, so nothing a wallet can assert covers the part that matters.
Emit an explicit print carrying shares and ustx alongside `sft_transfer`, and
say loudly and in the README that the token is not the whole position.

**Whoever holds the position earns it.** A marketplace escrow holding the token
holds the shares, and `claim-rewards` pays the holder. Escrows written on the
assumption that tokens are inert will quietly accrue rewards they never
forward.

**The one-queue rule.** `credit-queue` allows a member one queued epoch at a
time (`ERR_QUEUE_PENDING`). A transfer of queued sats to someone queued for a
different bond has to fail — or `queued-epoch` becomes a map, which per-bond
ids make natural anyway. Decide which; do not let the transfer discover it.

**Exits and tails.** Refuse outright while the seller has `exit-epoch` set —
those sats are already promised to the next roll. Tail claims stay with the
seller and never transfer, which means a seller who exits fully still has
something to come.

**After the wind-down.** Once `unstake-sbtc` has run, every position is
released and a transfer is an IOU on principal already sitting in the vault,
with `claim-principal` paying the holder. That is probably fine. Decide it on
purpose rather than inheriting it.

## Invariants

The supply identity from the first note is what makes these cheap: with supply
already pinned to the books, a transfer only has to be shown to conserve.

- **A transfer conserves** pool-level `total-shares` for the epoch,
  `bonded-ustx + queued-ustx + released-ustx`, and `overall-supply`. Three
  equalities before and after.
- **Per-id supply** equals the sum of the positions in that bond — the check
  that catches a re-id that moved the balance but not the record, or the
  reverse.
- **No transfer while `principal-in-transit` is set.** Assert it, and let the
  fuzzer try.
- The fuzz harness needs a transfer action driving real principals against real
  positions, or none of the above is being exercised.

## Build order

1. **Ship the non-transferable version first.** Every stage of it is a
   prerequisite here and none of it is wasted. In particular do not skip its
   stage 4 — the supply invariant is what the conservation checks are written
   against.
2. **Extract the vault trait** into a definition-only contract and invert the
   edge: the vault names the pool, the pool holds `<vault-trait>`. Nothing else
   changes yet; the check is that all four contracts still deploy.
3. **Move the principal-moving entry points onto the trait argument**,
   asserting `contract-of` against the stored vault exactly as `stake` does for
   the signer manager. This is the invasive stage and it touches every caller
   and every test.
4. **Write `transfer` in the vault**: settle both, move sats, shares and the
   STX legs, then the guards above. `transfer-memo` is the same with the memo
   printed last, as the standard requires.
5. **Conservation invariants and a fuzz action**, before the metadata and
   before any front end.
6. **The explicit position-transfer event**, the metadata that says what the
   token does and does not carry, and the README section for integrators.

## Decide before starting

- **Does the STX move with the sats, or must the buyer bring their own?**
  Moving it is the only version where a partial transfer leaves both sides
  coherent. The alternative — the buyer tops up STX separately — makes a
  transfer a two-party, two-transaction dance, and there is no good failure
  mode for the half-done state.
- **Partial transfers?** Yes, it is a semi-fungible token and refusing them
  wastes the F. But every rounding hazard above is a partial-transfer hazard;
  whole-position-only is a real way to buy simplicity.
- **Transfers while a bond is live, or only between the roll and the next
  stake?** Live is the entire value — a position is locked for six months and
  that is what a buyer is pricing. Windowing it would leave the token tradeable
  exactly when nobody needs to trade it.
- **Does the DAO get a pause on transfers?** This is the first thing in the
  system with a real argument for one, and it is worth naming rather than
  smuggling. The README's case is that nothing the operator does can reach a
  deposit and nothing can stall the pool; a pausable `transfer` breaks neither,
  and it is still the first switch anyone has been given. Probably no — but if
  the answer is yes, it belongs in the README's trust section, not in a
  comment.
