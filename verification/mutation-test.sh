#!/usr/bin/env bash
# Does this setup actually catch a bug?
#
# A wall of HOLDS proves nothing on its own -- an invariant whose reads get
# abstracted away holds for no reason, and that looks identical to success. So
# break the contract on purpose and require the invariant it breaks to stop
# holding. Run this after any change to the stubs or the engine.
#
# Three mutations sit in a cheap mutator; the fourth goes through `settle`
# and a payout, so it also checks that the engine sees a mutator's STX
# transfer and pays what the mutator computed, not a re-read of it.
set -uo pipefail
cd "$(dirname "$0")/.."
. verification/deps.sh

verdict() { # verdict <file> <invariant> <mutator>
  STACKS_LOG_CRITONLY=1 timeout 300 $CLV sym induct $DEPLOYER.bond-staker "$1" \
    "${DEPS[@]}" --invariant "$2" --mutator "$3" --time-budget 120 2>&1 \
    | grep -oE "HOLDS|NOT PROVEN|VIOLATED|UNFINISHED|SKIP" | head -1
}

fail=0
check() { # check <description> <perl-script> <invariant> <mutator>
  local desc="$1" script="$2" inv="$3" mut="$4" before after
  before=$(verdict contracts/bond-staker.clar "$inv" "$mut")
  perl -0pe "$script" contracts/bond-staker.clar > /tmp/mutant.clar
  if cmp -s /tmp/mutant.clar contracts/bond-staker.clar; then
    echo "  ERROR   $desc: the mutation changed nothing"; fail=1; return
  fi
  after=$(verdict /tmp/mutant.clar "$inv" "$mut")
  if [ "$before" = "HOLDS" ] && [ "$after" != "HOLDS" ]; then
    echo "  CAUGHT  $desc"
    echo "          $inv on $mut: $before -> $after"
  else
    echo "  MISSED  $desc"
    echo "          $inv on $mut: $before -> ${after:-<nothing>} (wanted HOLDS -> not HOLDS)"
    fail=1
  fi
}

echo "Mutation tests (each must go HOLDS -> something else):"

# Leave principal flagged as in transit between calls.
check "strand principal in transit" \
  's/\(map-set operators who enabled\)/(var-set principal-in-transit u1) (map-set operators who enabled)/' \
  invariant-no-principal-left-in-transit update-operator

# Pay out reward that was never credited.
check "pay reward that was never credited" \
  's/\(map-set operators who enabled\)/(var-set total-paid (+ (var-get total-paid) u1)) (map-set operators who enabled)/' \
  invariant-paid-within-credited update-operator

# Claim more of the position is leaving than the position holds.
check "let exits exceed the position" \
  's/\(map-set operators who enabled\)/(var-set exiting-sats (+ (var-get bonded-sats) u1)) (map-set operators who enabled)/' \
  invariant-exits-fit-the-position update-operator

# Pay out twice the STX that was written off the books.
check "overpay the withdrawn STX" \
  's/\(try! \(pay-principal depositor sats ustx\)\)/(try! (pay-principal depositor sats (* u2 ustx)))/' \
  invariant-stx-covers-obligations withdraw

exit $fail
