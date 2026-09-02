# Verifying `bond-staker`

This directory holds what `clairvoyance sym induct` needs to check
`contracts/bond-staker.clar`'s own invariants: stand-ins for the contracts the
pool calls but this repository does not contain.

```sh
. verification/deps.sh
$CLV sym induct $DEPLOYER.bond-staker contracts/bond-staker.clar "${DEPS[@]}"
```

`sym induct` reads every `invariant-*` read-only function as an invariant and
every public function as a mutator, and for each pair asks: assuming the
invariant held on entry, does it still hold after the mutator ran?

## What a HOLDS is worth

A HOLDS is only as strong as the weakest thing it was checked against, so the
stubs are built to a rule: **be the weakest contract that still type-checks.**

Every value the `pox-5` stub returns is unconstrained — reads come from maps
and vars nothing writes, which the engine treats as fresh symbols. Nothing in
it says a bond exists, that a height is positive, or that cycles increase,
because pox-5 saying so is not something the pool's invariants may lean on.
Anything argument-dependent is keyed by that argument, so two bond indices can
disagree; a stub returning one symbol regardless of its arguments would be
quietly asserting they agree. Whether a call succeeds is unconstrained too, so
the failure paths get explored rather than assumed away.

Two dependencies are modelled rather than approximated, because an invariant is
stated directly against them:

- **`sbtc-token`** is a real token — balances are per-principal and a transfer
  actually moves them. `invariant-sbtc-covers-unpaid-rewards` is stated against
  the pool's own sBTC balance, so a `transfer` that did not move it would let
  that invariant hold no matter what the pool did with the money.
- **`pox-5`'s sBTC custody.** `register-for-bond` moves the difference between
  what pox-5 already holds for a staker and what the new bond needs, and
  `unstake-sbtc` gives it back, because that is what the pool's balance
  accounting is written against. A stub that skipped those transfers would
  leave sats sitting in the pool and make the same invariant hold for the wrong
  reason.

Where a stub is weaker than the real contract, the result is an invariant that
does not prove — never one that proves when it should not.

## The stubs

| file | stands in for | kind |
| --- | --- | --- |
| `pox-5.clar` | `ST000000000000000000002AMW42H.pox-5` | oracle, except sBTC custody |
| `sbtc-token.clar` | `SM3VDXK…CTSG82JFQ4.sbtc-token` | modelled |
| `bond-escrow.clar` | `.bond-escrow` | modelled (real transfer) |
| `sbtc-withdrawal.clar` | `SM3VDXK…CTSG82JFQ4.sbtc-withdrawal` | oracle |
| `signer-manager.clar` | a `signer-manager-trait` implementation | inert |

`bond-treasury.clar` is the real contract from `contracts/`. `.bond-bridge` is
never called by `bond-staker` — only named as a principal in an authorization
check — so it is not needed here.

## Does this actually catch anything?

`mutation-test.sh` breaks the contract on purpose and requires the invariant it
breaks to stop holding:

```
$ ./verification/mutation-test.sh
Mutation tests (each must go HOLDS -> something else):
  CAUGHT  strand principal in transit
          invariant-no-principal-left-in-transit on update-operator: HOLDS -> NOT PROVEN
  CAUGHT  pay reward that was never credited
          invariant-paid-within-credited on update-operator: HOLDS -> NOT PROVEN
  CAUGHT  let exits exceed the position
          invariant-exits-fit-the-position on update-operator: HOLDS -> NOT PROVEN
```

This matters more than the pass count. The failure mode of `sym induct` is not
a wrong VIOLATED, it is a HOLDS that means nothing -- an invariant whose own
reads got abstracted away holds trivially, and a wall of those is
indistinguishable from success. Re-run this after touching the stubs.

## Results

558 pairs, 18 invariants against 31 mutators:

| | count |
| --- | --- |
| HOLDS | 155 |
| VIOLATED | **0** |
| NOT PROVEN | 2 |
| UNFINISHED | 401 |

No mutator was shown to break any invariant. Read that as what it is: 155 of
558 pairs were decided and every one of them held, and the rest were not
reached. It is evidence, not a clean bill of health.

The two NOT PROVEN results are both on `invariant-finished-is-final`, which is
an `or` -- see the caveat below. Reading `unstake-sbtc` directly, it sets
`finished`, `bond-bound` and `bonded-sats` together in one `begin` before
anything fallible, so the post-state does satisfy the invariant. Neither
result is a defect in the contract.

### Five invariants are written as `or`

`invariant-live-epoch-matches-the-pool`, `invariant-rewards-only-after-staking`,
`invariant-finished-is-final`, `invariant-member-shares-need-an-epoch` and
`invariant-signer-manager-is-a-contract` all have a bare `(or ...)` at the top
of their body, and the engine does not re-evaluate that shape against what the
mutator wrote (`examples/known-gap-or-invariant.clar` in the clairvoyance fork
is the reproducer).

It fails safe -- the wrong answer is always NOT PROVEN, never HOLDS -- so their
HOLDS results are still sound: a mutator that touches none of the invariant's
state cannot break it, which is what those verdicts say. What is worthless is a
NOT PROVEN on one of these five: it carries no information about the mutator.

Rewriting them as `(if C X true)` or `(not (and C (not X)))` would make them
decidable today. That is a change to the contract for the benefit of the tool,
so it is offered, not made.

## What does not finish

`settle` folds `advance-epoch` over a ten-element list, and every step
branches. Inlined -- which inductive checking requires, since the invariant has
to see what the mutator wrote -- that is thousands of paths, and the engine has
no state merging to collapse them.

So anything that reaches `settle` reports UNFINISHED rather than a verdict:

- the five `invariant-member-*` invariants, which all call `get-settled-member`,
  against every mutator;
- the mutators that settle a member: `claim-rewards`, `settle-member`,
  `deposit`, `withdraw`, `stake` and their neighbours.

UNFINISHED is counted with the not-proven, because that is what it is. It is a
result the tool cannot reach, not a result. Raising `--time-budget` does not
help at this branching factor; collapsing it needs continuation merging in the
engine, which is not written yet.

## Known gaps

- The `signer-manager-trait` shape is invented. `bond-staker` only reads
  `contract-of` on a manager and forwards it, so nothing being proved depends
  on it.
- `sbtc-withdrawal` moves no sBTC, matching how `bond-treasury` uses it: the
  bridge locks the sats in place rather than moving them out.
- A pair reported UNFINISHED hit the engine's step budget. That counts against
  the proof, not for it; raise `--max-steps` to push further.
