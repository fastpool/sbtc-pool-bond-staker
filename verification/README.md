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
  CAUGHT  overpay the withdrawn STX
          invariant-stx-covers-obligations on withdraw: HOLDS -> NOT PROVEN
```

This matters more than the pass count. The failure mode of `sym induct` is not
a wrong VIOLATED, it is a HOLDS that means nothing -- an invariant whose own
reads got abstracted away holds trivially, and a wall of those is
indistinguishable from success. Re-run this after touching the stubs or the
engine. The fourth mutation goes through `settle` and a payout, so it also
pins the engine behaviour the results below depend on: the post-state
invariant sees the mutator's STX transfer, and the amount paid is the amount
the mutator computed, not a re-read of a record it had since overwritten.

## Results

558 pairs, 18 invariants against 31 mutators, with the clairvoyance fork at
`905bfd0` (`--time-budget 120`, ~60 s and 1.9 GB per invariant):

| | plain | `--assume-all` |
| --- | --- | --- |
| HOLDS | 532 | 534 |
| VIOLATED | **0** | **0** |
| NOT PROVEN | 26 | 24 |
| UNFINISHED | 0 | 0 |

Every pair was decided, and no mutator was shown to break any invariant. The
per-invariant transcripts are in `results/` (and `results/assume-all/`);
`summarize.sh` collates them.

`--assume-all` checks each invariant assuming *all* of them held on entry.
That is conjunction inductiveness: sound as a set, because every invariant is
checked under the same assumption, and never weaker than the plain run (a
HOLDS never turns into anything else -- checked). It closes two pairs.

### The 26 that do not prove

None is a defect in the contract. They fall into two classes.

**Trusting the bridge (2).** `credit-bridged-deposit` against
`invariant-stx-covers-obligations` and `invariant-treasury-covers-its-books`.
The function only writes a deposit down; the sats are already in the
treasury and the bridge "has just handed the STX leg over" -- outside the
call. Taken alone, the mutator credits a liability and moves no asset, and no
invariant over the pool's own state can say otherwise. The proof obligation is
on `.bond-bridge`, which this repository does not contain.

**A per-member bound against a pool total (24).** Every remaining pair is an
`invariant-member-*` invariant (or `exits-fit-the-position`,
`paid-within-credited`, `rewards-only-after-staking`,
`sbtc-covers-unpaid-rewards`, which have the same shape) against a mutator
that moves the pool's total by *one* member's amount. The invariant bounds one
member's record by the total; the engine checks it for an arbitrary member
`m0`, and for `m0 != tx-sender` the pre-state bound `record(m0) <= total` says
nothing about `total - record(tx-sender)`. What is actually true is that the
*sum* over all members is at most the total, and that cannot be written as a
Clarity read-only function over an unbounded map. So the fact is true and the
invariants are the strongest statable approximation of it; they are not
inductive on their own, and no rewriting makes them so.

One strengthening does help at the margin. `invariant-member-principal-fits-the-pool`
bounds a member's `bonded` and `released` separately, but `harness-release`
and `unstake-sbtc` move the whole of `bonded` into `released` at once, and the
separate bounds do not add up. Replacing the two `bonded` conjuncts by

```clarity
(<= (+ (get bonded-sats record) (get released-sats record))
  (+ (var-get bonded-sats) (var-get released-sats)))
(<= (+ (get bonded-ustx record) (get released-ustx record))
  (+ (var-get bonded-ustx) (var-get released-ustx)))
```

is implied by nothing weaker, is true of the contract, and takes that
invariant from 10 to 8 unproven pairs. It is a change to the contract for the
benefit of the tool, so it is offered, not made.

### What the engine had to learn

The first run of this matrix reported 155 HOLDS, 2 NOT PROVEN and 401
UNFINISHED. Getting from there to 532/26/0 was engine work, not invariant
work; the invariants were right as written. In the order found:

- **`or` was evaluated as `and`** (`SymOp::or` built an `And`). Every
  invariant with a top-level `or` was mis-read. Fixed, with a test.
- **Path explosion in `settle`.** A ten-step fold that branches at every step
  was thousands of continuations. The engine now joins the branches of an
  `if` into one continuation over an `if` formula, and names big shared
  sub-formulas so they cost a name rather than a copy. UNFINISHED went to 0.
- **`contract-call?` arguments were evaluated in the callee's context.**
  `(contract-call? .sbtc-token get-balance current-contract)` read the token's
  balance of *itself*. Unsound -- it could produce a HOLDS for the wrong
  reason -- and it did, on every invariant stated against the pool's sBTC
  balance. Fixed, with a test; every result here post-dates the fix.
- **The pool's STX balance was invisible to a post-state invariant.**
  `(get unlocked (stx-account current-contract))` was never resolved against
  the mutator's transfers, so `invariant-stx-covers-obligations` held on
  `deposit` because it never saw the deposit. Fixed; the fourth mutation
  above pins it.
- **A callee re-read what its caller had already computed.** Binding a
  callee into its caller ran in three passes -- arguments, then data vars,
  then map reads -- and the later passes rewrote the reads *inside* the
  substituted arguments. `withdraw` reads a record, zeroes it, and pays out
  the amount it read; the engine paid out the amount re-read from the zeroed
  record. Binding is now one pass. This is what closed `withdraw` and
  `claim-principal` on `invariant-stx-covers-obligations`, and it also
  *opened* `harness-release` and `unstake-sbtc` on
  `invariant-member-principal-fits-the-pool`, which had been holding for the
  wrong reason.

The lesson for reading a HOLDS: three of the five were bugs that manifest as
a HOLDS, not as a failure. The mutation tests, and the fact that every
NOT PROVEN above has a story, are what make the 532 worth something.

## Reading a NOT PROVEN

Run one pair with `--full-conditions` to get the untruncated failing
condition with a `where` legend for every named sub-formula:

```sh
$CLV sym induct $DEPLOYER.bond-staker contracts/bond-staker.clar "${DEPS[@]}" \
  --invariant invariant-member-principal-fits-the-pool --mutator harness-release \
  --full-conditions
```

`(solver: sat; ...)` means z3 found an assignment of the leaves that breaks
the invariant; `(solver: unknown; ...)` means it gave up (five-second budget
per query, non-linear arithmetic). `CLAIRVOYANCE_SMT_DUMP=dir` writes each
query as `.smt2` for inspection.

## Known gaps

- The `signer-manager-trait` shape is invented. `bond-staker` only reads
  `contract-of` on a manager and forwards it, so nothing being proved depends
  on it.
- `sbtc-withdrawal` moves no sBTC, matching how `bond-treasury` uses it: the
  bridge locks the sats in place rather than moving them out.
- `.bond-bridge` is not modelled, so what it must do before calling
  `credit-bridged-deposit` is an assumption, not a result (see above).
