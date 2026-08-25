// `bond-staker`: the early unstake.
//
// `bond-staker.test.ts` covers deposit, the roll, the reward index and the
// wind-down. This file is about the one power the pool has that the design
// under `v1/` does not, and the four places it touches:
//
//   - the sats really leave pox-5 and land in the treasury, mid-bond
//   - the STX leg does *not*, and comes back at the roll instead
//   - `total-shares` shrinks, so the remaining members take the whole of what
//     arrives next -- and nothing that arrived before is lost or double-paid
//   - `staked-sats` keeps the roll's scaling fraction, so a member who settles
//     after someone else has left is still scaled by the roll they were in
//   - `credit-offset` keeps the epoch's running credit flat, so `sync-rewards`
//     cannot run backwards over an exit
//
// plus a short section asserting none of it moved anything else.
import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import {
  ALLOWANCE_SATS,
  ALT_MANAGER,
  advanceToBurnHeight,
  avoidPreparePhase,
  bindNextBond,
  boundBond,
  BOND_INDEX,
  bondStartHeight,
  bootstrap,
  cancelExit,
  claimablePrincipal,
  claimableRewards,
  claimPrincipal,
  claimRewards,
  custodiedSats,
  deployer,
  deposit,
  earlyUnstakePreview,
  epoch,
  inPreparePhase,
  MAX_SATS,
  member,
  NEXT_BOND_INDEX,
  payRewards,
  poolTotals,
  requestExit,
  requiredUstx,
  sbtcBalance,
  setupBond,
  STX_VALUE_RATIO,
  settledMember,
  settleMember,
  stake,
  stxBalance,
  syncRewards,
  treasuryBalance,
  treasuryPrincipal,
  unstakeEarly,
  unstakeSbtc,
  withdraw,
} from "./helpers/bond-fixture";

const accounts = simnet.getAccounts();
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const carol = accounts.get("wallet_3")!;

const ALICE_SATS = 10_000_000; // 0.1 BTC
const BOB_SATS = 30_000_000; // 0.3 BTC
const POOL_SATS = ALICE_SATS + BOB_SATS;

/** Deposit for both, then commit the pool to its first bond. */
function stakeFirstBond() {
  const { bondStart, unlockHeight } = bootstrap();
  deposit(alice, ALICE_SATS);
  deposit(bob, BOB_SATS);
  advanceToBurnHeight(bondStart - 288);
  expect(stake().type).toBe("ok");
  avoidPreparePhase();
  return { bondStart, unlockHeight };
}

/** Bind the next bond and roll into it, inside its stake window. */
function rollInto(index = NEXT_BOND_INDEX, allowanceSats = ALLOWANCE_SATS) {
  setupBond(index, allowanceSats);
  expect(bindNextBond().type).toBe("ok");
  expect(Number(boundBond()["bond-index"])).toBe(index);
  advanceToBurnHeight(bondStartHeight(index) - 288);
  return stake();
}

describe("bond-staker: taking sBTC back mid-bond", () => {
  beforeEach(() => {
    stakeFirstBond();
  });

  it("really unstakes from pox-5, not just from the ledger", () => {
    expect(custodiedSats()).toBe(POOL_SATS);

    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");

    // pox-5's own view of what it holds for the pool has moved.
    expect(custodiedSats()).toBe(BOB_SATS);
  });

  it("hands the sats to the treasury, claimable at once", () => {
    const treasuryBefore = treasuryBalance();
    const aliceBefore = sbtcBalance(alice);

    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");

    // The principal lands in the treasury, where the rest of it lives -- what
    // the pool itself holds has to stay reward and nothing else.
    expect(treasuryBalance()).toBe(treasuryBefore + ALICE_SATS);
    expect(Number(claimablePrincipal(alice)["released-sats"])).toBe(ALICE_SATS);

    expect(claimPrincipal(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(aliceBefore + ALICE_SATS);
    expect(treasuryBalance()).toBe(treasuryBefore);
  });

  it("takes the leaver's shares out of the live epoch", () => {
    expect(Number(epoch(0)["total-shares"])).toBe(POOL_SATS);

    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");

    const record = epoch(0);
    expect(Number(record["total-shares"])).toBe(BOB_SATS);
    // ...but not out of what the roll committed, which never moves.
    expect(Number(record["staked-sats"])).toBe(POOL_SATS);
    expect(Number(record["eligible-sats"])).toBe(POOL_SATS);
    // The pool's committed sats and the epoch's shares stay in step, which is
    // what the fuzzer's `invariant-live-epoch-matches-the-pool` asserts.
    expect(Number(poolTotals()["bonded-sats"])).toBe(BOB_SATS);
  });

  it("does not hand back the STX leg -- pox-5 still has it locked", () => {
    const ustx = Number(member(alice)["queued-ustx"]) || requiredUstx(ALICE_SATS);
    const stxBefore = stxBalance(alice);

    const result = unstakeEarly(alice, ALICE_SATS);
    expect(result.type).toBe("ok");

    // Nothing on the STX side moved, and none of it is claimable.
    expect(stxBalance(alice)).toBe(stxBefore);
    expect(Number(claimablePrincipal(alice)["released-ustx"])).toBe(0);
    // It is booked as on its way out, so the next roll frees it.
    expect(Number(poolTotals()["exiting-ustx"])).toBe(ustx);
    expect(Number(poolTotals()["exiting-sats"])).toBe(0);
  });

  it("frees the STX at the next roll, and carries no shares across", () => {
    const ustx = Number(settledMember(alice)["bonded-ustx"]);
    expect(ustx).toBeGreaterThan(0);

    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
    expect(claimPrincipal(alice).type).toBe("ok"); // the sats, now

    expect(rollInto().type).toBe("ok");

    const record = settledMember(alice);
    expect(Number(record["released-ustx"])).toBe(ustx);
    expect(Number(record.shares)).toBe(0);
    expect(Number(record["bonded-sats"])).toBe(0);
    expect(Number(record["bonded-ustx"])).toBe(0);
    // The exit request is spent by the roll, so they may come back.
    expect(record["exit-epoch"]).toBe(null);

    const stxBefore = stxBalance(alice);
    expect(claimPrincipal(alice).type).toBe("ok");
    expect(stxBalance(alice)).toBe(stxBefore + ustx);

    // Only bob is carried into epoch 1.
    expect(Number(epoch(1)["total-shares"])).toBe(BOB_SATS);
  });

  it("takes part of a position and leaves the member in", () => {
    const half = ALICE_SATS / 2;

    expect(unstakeEarly(alice, half).type).toBe("ok");

    const record = settledMember(alice);
    expect(Number(record["bonded-sats"])).toBe(half);
    expect(Number(record.shares)).toBe(half);
    expect(Number(record["released-sats"])).toBe(half);
    // A partial exit is not an exit: the STX rides on with what is left.
    expect(record["exit-epoch"]).toBe(null);
    expect(Number(poolTotals()["exiting-ustx"])).toBe(0);
    expect(Number(epoch(0)["total-shares"])).toBe(POOL_SATS - half);

    // ...and they are still a member at the roll.
    expect(rollInto().type).toBe("ok");
    expect(Number(settledMember(alice).shares)).toBe(half);
  });
});

describe("bond-staker: what leaving early costs", () => {
  beforeEach(() => {
    stakeFirstBond();
  });

  it("keeps rewards already recognised and forfeits the rest", () => {
    // A first payout, recognised while both are in.
    payRewards(deployer, 4_000_000);
    expect(syncRewards().type).toBe("ok");

    const aliceEarned = claimableRewards(alice);
    const bobEarned = claimableRewards(bob);
    expect(aliceEarned).toBe(1_000_000); // 10/40 of the pot
    expect(bobEarned).toBe(3_000_000); // 30/40

    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");

    // What she had accrued survives the exit and is still payable.
    expect(claimableRewards(alice)).toBe(aliceEarned);
    const before = sbtcBalance(alice);
    expect(claimRewards(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(before + aliceEarned);

    // A second payout, after she has gone: all of it is bob's. Chosen to
    // divide by the 30,000,000 shares now live, so the pool's usual
    // sub-satoshi dust does not muddy the figure being asserted.
    payRewards(deployer, 3_000_000);
    expect(syncRewards().type).toBe("ok");
    expect(claimableRewards(alice)).toBe(0);
    expect(claimableRewards(bob)).toBe(bobEarned + 3_000_000);
  });

  it("forfeits a pot that arrived but had not been recognised yet", () => {
    // The sBTC is sitting in the pool, unrecognised, when she leaves.
    payRewards(deployer, 3_000_000);
    expect(claimableRewards(alice)).toBe(0);
    expect(Number(earlyUnstakePreview(alice)["at-risk-rewards"])).toBe(750_000);

    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
    expect(syncRewards().type).toBe("ok");

    // Her share of it went to the members still in, not to her.
    expect(claimableRewards(alice)).toBe(0);
    expect(claimableRewards(bob)).toBe(3_000_000);
  });

  it("does not forfeit it if `sync-rewards` is called first", () => {
    payRewards(deployer, 4_000_000);

    // Which anyone may do, on anyone's behalf.
    expect(syncRewards(carol).type).toBe("ok");
    expect(Number(earlyUnstakePreview(alice)["at-risk-rewards"])).toBe(0);

    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
    expect(claimableRewards(alice)).toBe(1_000_000);
    expect(claimableRewards(bob)).toBe(3_000_000);
  });

  it("previews the sats, the held-back STX and both reward figures", () => {
    payRewards(deployer, 4_000_000);
    expect(syncRewards().type).toBe("ok");
    payRewards(deployer, 400_000); // arrived, not yet recognised

    const preview = earlyUnstakePreview(alice);
    expect(Number(preview.sats)).toBe(ALICE_SATS);
    expect(Number(preview["ustx-at-roll"])).toBe(
      Number(settledMember(alice)["bonded-ustx"]),
    );
    expect(Number(preview["banked-rewards"])).toBe(1_000_000);
    expect(Number(preview["at-risk-rewards"])).toBe(100_000); // 10/40

    // A stranger has nothing to preview and the call still answers.
    const empty = earlyUnstakePreview(carol);
    expect(Number(empty.sats)).toBe(0);
    expect(Number(empty["at-risk-rewards"])).toBe(0);
  });

  it("never pays out more reward than it recognised, across an exit", () => {
    payRewards(deployer, 3_333_333);
    expect(syncRewards().type).toBe("ok");
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
    payRewards(deployer, 7_777_777);
    expect(syncRewards().type).toBe("ok");
    payRewards(deployer, 11);
    expect(syncRewards().type).toBe("ok");

    const totals = poolTotals();
    const credited = Number(totals["total-credited"]);
    expect(claimableRewards(alice) + claimableRewards(bob)).toBeLessThanOrEqual(
      credited - Number(totals["total-paid"]),
    );

    expect(claimRewards(alice).type).toBe("ok");
    expect(claimRewards(bob).type).toBe("ok");
    expect(Number(poolTotals()["total-paid"])).toBeLessThanOrEqual(credited);
  });

  it("does not let the epoch's credit run backwards over an exit", () => {
    // The regression `credit-offset` exists for: `credited` is recomputed from
    // `total-shares * reward-index`, and without the offset it would drop the
    // moment shares do -- so the next sync would underflow on `recognized`.
    payRewards(deployer, 4_000_000);
    expect(syncRewards().type).toBe("ok");

    const creditedBefore = Number(epoch(0).credited);
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");

    // The epoch's running total is exactly where it was.
    expect(Number(epoch(0).credited)).toBe(creditedBefore);
    expect(Number(epoch(0)["credit-offset"])).toBeGreaterThan(0);

    // With nothing new in, a sync is a no-op rather than an abort.
    expect(syncRewards()).toBeErr(Cl.uint(114)); // NOTHING_TO_CLAIM

    // And the next real payout still credits cleanly, on top of the offset
    // rather than instead of it.
    payRewards(deployer, 3_000_000);
    expect(syncRewards().type).toBe("ok");
    expect(Number(epoch(0).credited)).toBe(creditedBefore + 3_000_000);
  });
});

describe("bond-staker: an exit does not disturb a scaled roll", () => {
  it("scales a late-settling member by the roll, not by the live shares", () => {
    stakeFirstBond();

    // A dearer bond -- twice the STX per sat -- so the pool's STX carries only
    // part of what wants in and every member is scaled back by one fraction.
    setupBond(NEXT_BOND_INDEX, ALLOWANCE_SATS, STX_VALUE_RATIO * 2);
    expect(bindNextBond().type).toBe("ok");
    const carolSats = ALICE_SATS;
    expect(deposit(carol, carolSats).type).toBe("ok");

    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");
    avoidPreparePhase();

    const one = epoch(1);
    const staked = Number(one["staked-sats"]);
    const eligible = Number(one["eligible-sats"]);
    expect(staked).toBeLessThan(eligible);

    // What the roll owes carol, worked out from the roll's own numbers.
    const carolCarried = Math.floor((carolSats * staked) / eligible);
    expect(carolCarried).toBeGreaterThan(0);

    // Nothing has touched carol since the roll, so her deposit is still
    // sitting in the queue waiting to be settled.
    expect(Number(member(carol)["queued-sats"])).toBe(carolSats);

    // Alice settles and leaves, which takes her shares out of epoch 1.
    const aliceCarried = Number(settledMember(alice)["bonded-sats"]);
    expect(aliceCarried).toBeGreaterThan(0);
    expect(unstakeEarly(alice, aliceCarried).type).toBe("ok");
    expect(Number(epoch(1)["total-shares"])).toBeLessThan(staked);

    // Carol is still scaled by `staked-sats / eligible-sats`, which the exit
    // did not move. Scaling by the live `total-shares` -- which is what the
    // single field would have become -- would short-change her here.
    expect(Number(settledMember(carol)["bonded-sats"])).toBe(carolCarried);
    expect(settleMember(carol).type).toBe("ok");
    expect(Number(member(carol)["bonded-sats"])).toBe(carolCarried);
  });
});

describe("bond-staker: what it refuses", () => {
  it("refuses before the pool has ever staked", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    expect(unstakeEarly(alice, ALICE_SATS)).toBeErr(Cl.uint(107)); // NOT_STAKED
    // ...where `withdraw` is the right call, and still free.
    expect(withdraw(alice).type).toBe("ok");
  });

  it("refuses a non-member, a zero amount and more than is held", () => {
    stakeFirstBond();
    expect(unstakeEarly(carol, 1)).toBeErr(Cl.uint(110)); // NOTHING_DEPOSITED
    expect(unstakeEarly(alice, 0)).toBeErr(Cl.uint(116)); // INVALID_AMOUNT
    expect(unstakeEarly(alice, ALICE_SATS + 1)).toBeErr(Cl.uint(116));
  });

  it("refuses the wrong signer manager", () => {
    stakeFirstBond();
    expect(unstakeEarly(alice, ALICE_SATS, ALT_MANAGER)).toBeErr(Cl.uint(111));
  });

  it("refuses a member already on their way out", () => {
    stakeFirstBond();
    expect(requestExit(alice).type).toBe("ok");
    expect(unstakeEarly(alice, ALICE_SATS)).toBeErr(Cl.uint(123)); // ALREADY_EXITING
  });

  it("refuses once the pool has wound down", () => {
    const { unlockHeight } = stakeFirstBond();
    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc().type).toBe("ok");
    expect(unstakeEarly(alice, ALICE_SATS)).toBeErr(Cl.uint(112)); // ALREADY_UNSTAKED
  });

  it("refuses a second bite once the whole position is gone", () => {
    stakeFirstBond();
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
    // The exit flag is set, so this bounces before the amount is even read.
    expect(unstakeEarly(alice, 1)).toBeErr(Cl.uint(123)); // ALREADY_EXITING
  });

  it("will not let a full early exit be cancelled", () => {
    stakeFirstBond();
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
    // There is no position to come back to: the sats are paid out and the
    // shares are gone. Only the STX is still waiting on the roll.
    expect(cancelExit(alice)).toBeErr(Cl.uint(110)); // NOTHING_DEPOSITED
  });

  it("still lets an ordinary `request-exit` be cancelled", () => {
    stakeFirstBond();
    expect(requestExit(alice).type).toBe("ok");
    expect(cancelExit(alice).type).toBe("ok");
    expect(Number(poolTotals()["exiting-sats"])).toBe(0);
  });

  it("is refused by pox-5 during a cycle's prepare phase", () => {
    const { bondStart } = bootstrap();
    deposit(alice, ALICE_SATS);
    deposit(bob, BOB_SATS);
    advanceToBurnHeight(bondStart - 288);
    expect(stake().type).toBe("ok");

    // Walk into the prepare phase of whatever cycle we are in.
    for (let guard = 0; !inPreparePhase() && guard < 400; guard++) {
      simnet.mineEmptyBurnBlocks(5);
    }
    expect(inPreparePhase()).toBe(true);

    const refused = unstakeEarly(alice, ALICE_SATS);
    expect(refused.type).toBe("err");

    // ...and it is only timing: out of the prepare phase it goes through.
    avoidPreparePhase();
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
  });
});

describe("bond-staker: the rest of the pool is undisturbed", () => {
  it("leaves the books balanced after an exit", () => {
    stakeFirstBond();
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");

    const totals = poolTotals();
    // The treasury covers everything the ledger says it is holding.
    expect(treasuryBalance()).toBeGreaterThanOrEqual(
      Number(totals["queued-sats"]) +
        Number(totals["released-sats"]) +
        Number(totals["withdrawing-sats"]),
    );
    // Nothing was conjured: the exit moved principal between buckets only.
    expect(Number(totals["bonded-sats"]) + Number(totals["released-sats"])).toBe(
      POOL_SATS,
    );
    // ...and none of it reads as unattributed, so no sweep can reach it.
    expect(Number(totals["unclaimed-rewards"])).toBe(0);
  });

  it("stamps a fresh epoch with a zero credit offset", () => {
    stakeFirstBond();
    expect(Number(epoch(0)["credit-offset"])).toBe(0);
    // Before any early exit the two share fields agree, which is why one
    // field once did for both.
    expect(Number(epoch(0)["total-shares"])).toBe(
      Number(epoch(0)["staked-sats"]),
    );
  });

  it("still rolls, still winds down, still pays out", () => {
    const { unlockHeight } = stakeFirstBond();
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");

    expect(rollInto().type).toBe("ok");
    expect(Number(epoch(1)["total-shares"])).toBe(BOB_SATS);

    advanceToBurnHeight(unlockHeight + 12 * 1050);
    expect(unstakeSbtc().type).toBe("ok");

    // Both members can take everything back: alice's sats came early, her STX
    // at the roll; bob's whole position at the wind-down.
    expect(claimPrincipal(alice).type).toBe("ok");
    expect(claimPrincipal(bob).type).toBe("ok");
    expect(sbtcBalance(treasuryPrincipal())).toBe(0);
  });
});
