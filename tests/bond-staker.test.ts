import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import {
  advanceToBurnHeight,
  ALLOWANCE_SATS,
  ALT_MANAGER,
  bindBond,
  BOND_INDEX,
  bondStartHeight,
  bootstrap,
  cancelExit,
  claimablePrincipal,
  claimableRewards,
  claimPrincipal,
  claimRewards,
  CYCLE_LENGTH,
  deployer,
  deposit,
  depositStx,
  epoch,
  initializePool,
  managerPrincipal,
  MAX_SATS,
  member,
  MIN_USTX_RATIO,
  NEXT_BOND_INDEX,
  num,
  payRewards,
  plain,
  POOL,
  poolConfig,
  poolPrincipal,
  poolTotals,
  POX5,
  boundBond,
  readPool,
  readPoxNum,
  registerSignerManager,
  requestExit,
  requiredUstx,
  rewardEpoch,
  sbtcBalance,
  setupBond,
  settledMember,
  stake,
  stakePreview,
  stxBalance,
  STX_VALUE_RATIO,
  syncRewards,
  treasuryBalance,
  treasuryPrincipal,
  TREASURY,
  unstakeSbtc,
  updateBondRegistration,
  withdraw,
} from "./helpers/bond-fixture";

const accounts = simnet.getAccounts();
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const carol = accounts.get("wallet_3")!;
const dave = accounts.get("wallet_4")!;

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
  return { bondStart, unlockHeight };
}

/** Bind the next bond and roll into it, inside its stake window. */
function rollInto(index = NEXT_BOND_INDEX, maxSats = MAX_SATS) {
  setupBond(index);
  expect(bindBond(index, maxSats).type).toBe("ok");
  advanceToBurnHeight(bondStartHeight(index) - 288);
  return stake();
}

describe("bond-staker: initialization and binding", () => {
  it("rejects deposits before a bond is bound", () => {
    expect(deposit(alice, ALICE_SATS)).toBeErr(Cl.uint(118)); // NO_BOND_BOUND
  });

  it("only lets the deployer initialize, once", () => {
    registerSignerManager();
    expect(initializePool(alice)).toBeErr(Cl.uint(100)); // UNAUTHORIZED
    expect(initializePool().type).toBe("ok");
    expect(initializePool()).toBeErr(Cl.uint(101)); // ALREADY_INITIALIZED
  });

  it("will not bind a bond that does not exist or does not want us", () => {
    registerSignerManager();
    initializePool();
    expect(bindBond(5)).toBeErr(Cl.uint(103)); // BOND_NOT_FOUND
    setupBond();
    expect(bindBond(BOND_INDEX, ALLOWANCE_SATS + 1)).toBeErr(Cl.uint(105));
    expect(bindBond(BOND_INDEX, MAX_SATS, alice)).toBeErr(Cl.uint(100));
  });

  it("copies the bond's parameters from pox-5", () => {
    const { bondStart } = bootstrap();
    const bond = boundBond();

    expect(bond.bound).toBe(true);
    expect(Number(bond["bond-index"])).toBe(BOND_INDEX);
    expect(Number(bond["max-sats"])).toBe(MAX_SATS);
    expect(Number(bond["stx-value-ratio"])).toBe(STX_VALUE_RATIO);
    expect(Number(bond["min-ustx-ratio"])).toBe(MIN_USTX_RATIO);
    expect(Number(bond["start-height"])).toBe(bondStart);
    // 12 cycles after the bond starts
    expect(Number(bond["unlock-burn-height"])).toBe(bondStart + 12 * CYCLE_LENGTH);
    // the stake window opens 288 burn blocks before the bond starts
    expect(Number(bond["stake-opens-at"])).toBe(bondStart - 288);

    expect(bindBond()).toBeErr(Cl.uint(119)); // BOND_ALREADY_BOUND
  });
});

describe("bond-staker: the 95/5 deposit split", () => {
  beforeEach(() => {
    bootstrap();
  });

  it("charges the STX leg pox-5 requires for the sats", () => {
    expect(requiredUstx(ALICE_SATS)).toBe(
      (ALICE_SATS / 100) * STX_VALUE_RATIO * (MIN_USTX_RATIO / 10_000),
    );
  });

  it("is never below what pox-5 demands, and rounds up", () => {
    for (const sats of [1, 3, 7, 999, 1_000_001, ALICE_SATS]) {
      const poxMinimum = readPoxNum("min-ustx-for-sats-amount", [
        Cl.uint(sats),
        Cl.uint(STX_VALUE_RATIO),
        Cl.uint(MIN_USTX_RATIO),
      ]);
      expect(requiredUstx(sats)).toBeGreaterThanOrEqual(poxMinimum);
    }
  });

  it("leaves the STX at ~5% of the sBTC value", () => {
    const ustx = requiredUstx(ALICE_SATS);
    const satsValue = (ALICE_SATS / 100) * STX_VALUE_RATIO;
    expect(ustx / satsValue).toBeCloseTo(0.05, 6);
    // as a share of the whole deposit: 4.76% STX / 95.24% sBTC
    expect(ustx / (satsValue + ustx)).toBeCloseTo(0.0476, 4);
  });

  it("sends the sBTC to the treasury and keeps the STX here", () => {
    const ustx = requiredUstx(ALICE_SATS);
    const sbtcBefore = sbtcBalance(alice);
    const stxBefore = stxBalance(alice);

    expect(deposit(alice, ALICE_SATS).type).toBe("ok");

    expect(sbtcBalance(alice)).toBe(sbtcBefore - ALICE_SATS);
    expect(stxBalance(alice)).toBe(stxBefore - ustx);
    expect(treasuryBalance()).toBe(ALICE_SATS);
    expect(sbtcBalance(poolPrincipal())).toBe(0);
    expect(stxBalance(poolPrincipal())).toBe(ustx);

    const pool = poolTotals();
    expect(Number(pool["queued-sats"])).toBe(ALICE_SATS);
    expect(Number(pool["queued-ustx"])).toBe(ustx);
    expect(Number(pool["bonded-sats"])).toBe(0);
  });

  it("queues, but does not yet grant shares", () => {
    deposit(alice, ALICE_SATS);
    const record = member(alice);
    expect(Number(record["queued-sats"])).toBe(ALICE_SATS);
    expect(Number(record.shares)).toBe(0);
    expect(Number(record["bonded-sats"])).toBe(0);
    expect(Number(record["queued-epoch"])).toBe(0);
  });

  it("accumulates repeat deposits", () => {
    deposit(alice, ALICE_SATS);
    deposit(alice, ALICE_SATS);
    expect(Number(member(alice)["queued-sats"])).toBe(2 * ALICE_SATS);
    expect(Number(member(alice)["queued-ustx"])).toBe(
      2 * requiredUstx(ALICE_SATS),
    );
  });

  it("rejects a zero deposit and caps the pool at its allocation", () => {
    expect(deposit(alice, 0)).toBeErr(Cl.uint(116)); // INVALID_AMOUNT
    expect(deposit(alice, MAX_SATS).type).toBe("ok");
    expect(deposit(bob, 1)).toBeErr(Cl.uint(105)); // ALLOCATION_EXCEEDED
  });
});

describe("bond-staker: withdrawing a queued deposit", () => {
  beforeEach(() => {
    bootstrap();
  });

  it("returns both legs in full", () => {
    const sbtcBefore = sbtcBalance(alice);
    const stxBefore = stxBalance(alice);

    deposit(alice, ALICE_SATS);
    expect(withdraw(alice).type).toBe("ok");

    expect(sbtcBalance(alice)).toBe(sbtcBefore);
    expect(stxBalance(alice)).toBe(stxBefore);
    expect(treasuryBalance()).toBe(0);
    expect(Number(poolTotals()["queued-sats"])).toBe(0);
  });

  it("only touches the caller's own deposit", () => {
    deposit(alice, ALICE_SATS);
    deposit(bob, BOB_SATS);
    withdraw(alice);
    expect(treasuryBalance()).toBe(BOB_SATS);
    expect(Number(member(bob)["queued-sats"])).toBe(BOB_SATS);
  });

  it("has nothing to give an account that never deposited", () => {
    expect(withdraw(carol)).toBeErr(Cl.uint(110)); // NOTHING_DEPOSITED
  });

  it("stays open if the pool never stakes", () => {
    deposit(alice, ALICE_SATS);
    advanceToBurnHeight(bondStartHeight(BOND_INDEX) + 10);
    expect(deposit(alice, 1)).toBeErr(Cl.uint(109)); // TOO_LATE
    expect(withdraw(alice).type).toBe("ok");
  });
});

describe("bond-staker: staking the first bond", () => {
  let bondStart: number;

  beforeEach(() => {
    ({ bondStart } = bootstrap());
    deposit(alice, ALICE_SATS);
    deposit(bob, BOB_SATS);
  });

  it("is closed until 288 burn blocks before the bond starts", () => {
    expect(stake()).toBeErr(Cl.uint(108)); // TOO_EARLY
    advanceToBurnHeight(bondStart - 289);
    expect(stake()).toBeErr(Cl.uint(108));
  });

  it("is closed once the bond has started", () => {
    advanceToBurnHeight(bondStart);
    expect(stake()).toBeErr(Cl.uint(109)); // TOO_LATE
  });

  it("only accepts the signer manager the pool was bound to", () => {
    advanceToBurnHeight(bondStart - 288);
    expect(stake(alice, ALT_MANAGER)).toBeErr(Cl.uint(111));
  });

  it("is permissionless inside the window", () => {
    advanceToBurnHeight(bondStart - 288);
    // carol has no position and no role -- she can still stake the pool
    expect(stake(carol).type).toBe("ok");
  });

  it("opens epoch 0 and registers the pooled deposit for the bond", () => {
    const ustx = Number(poolTotals()["queued-ustx"]);
    advanceToBurnHeight(bondStart - 288);
    expect(stake().type).toBe("ok");

    const record = epoch(0);
    expect(Number(record["bond-index"])).toBe(BOND_INDEX);
    expect(Number(record["total-shares"])).toBe(POOL_SATS);
    expect(Number(record["staked-sats"])).toBe(POOL_SATS);
    expect(Number(record["staked-ustx"])).toBe(ustx);
    expect(Number(record["unlock-burn-height"])).toBe(
      bondStart + 12 * CYCLE_LENGTH,
    );
    expect(Number(poolConfig()["epoch-count"])).toBe(1);

    // the sBTC moved from the treasury into pox-5's custody
    expect(treasuryBalance()).toBe(0);
    expect(sbtcBalance(poolPrincipal())).toBe(0);
    expect(sbtcBalance(POX5)).toBe(POOL_SATS);

    const membership = plain(
      simnet.callReadOnlyFn(
        POX5,
        "get-bond-membership",
        [Cl.principal(poolPrincipal())],
        deployer,
      ).result,
    );
    expect(Number(membership["amount-sats"])).toBe(POOL_SATS);
    expect(Number(membership["amount-ustx"])).toBe(ustx);
    expect(membership.signer).toBe(managerPrincipal());

    // ...and the pooled STX is locked
    expect(stxBalance(poolPrincipal())).toBe(ustx);
  });

  it("grants each member shares equal to their committed sats", () => {
    advanceToBurnHeight(bondStart - 288);
    stake();

    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
    expect(Number(settledMember(bob).shares)).toBe(BOB_SATS);
    // the epoch's shares are exactly the members' put together
    expect(Number(epoch(0)["total-shares"])).toBe(
      Number(settledMember(alice).shares) + Number(settledMember(bob).shares),
    );
    // and the deposit is now committed, not queued
    expect(Number(settledMember(alice)["bonded-sats"])).toBe(ALICE_SATS);
    expect(Number(settledMember(alice)["queued-sats"])).toBe(0);
  });

  it("closes the bond binding and locks members in", () => {
    advanceToBurnHeight(bondStart - 288);
    stake();
    expect(boundBond().bound).toBe(false);
    expect(deposit(carol, 1)).toBeErr(Cl.uint(118)); // NO_BOND_BOUND
    expect(stake()).toBeErr(Cl.uint(118));
    expect(withdraw(alice)).toBeErr(Cl.uint(110)); // nothing queued any more
    expect(claimPrincipal(alice)).toBeErr(Cl.uint(114)); // nothing released
  });

  it("refuses to stake an empty pool", () => {
    withdraw(alice);
    withdraw(bob);
    advanceToBurnHeight(bondStart - 288);
    expect(stake()).toBeErr(Cl.uint(110)); // NOTHING_DEPOSITED
  });
});

describe("bond-staker: rolling into the next bond", () => {
  let unlockHeight: number;

  beforeEach(() => {
    ({ unlockHeight } = stakeFirstBond());
  });

  it("will not bind a bond that overlaps the live one", () => {
    // bond 7 still runs inside bond 2's term; only 2 + 6 or later works
    setupBond(NEXT_BOND_INDEX - 1);
    expect(bindBond(NEXT_BOND_INDEX - 1)).toBeErr(Cl.uint(120));
  });

  it("carries the whole position across without unwinding it", () => {
    const custodiedBefore = sbtcBalance(POX5);
    expect(rollInto().type).toBe("ok");

    // pox-5 never gave the sBTC back: the same sats simply moved bonds
    expect(sbtcBalance(POX5)).toBe(custodiedBefore);
    expect(treasuryBalance()).toBe(0);
    expect(Number(poolConfig()["epoch-count"])).toBe(2);

    const one = epoch(1);
    expect(Number(one["bond-index"])).toBe(NEXT_BOND_INDEX);
    expect(Number(one["total-shares"])).toBe(POOL_SATS);
    expect(Number(one["unlock-burn-height"])).toBe(
      bondStartHeight(NEXT_BOND_INDEX) + 12 * CYCLE_LENGTH,
    );

    // epoch 1 starts exactly where epoch 0 ended -- no idle cycle
    expect(Number(one["first-reward-cycle"])).toBe(
      Number(epoch(0)["first-reward-cycle"]) + 12,
    );

    // members keep their shares and their deposit
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
    expect(Number(settledMember(alice)["bonded-sats"])).toBe(ALICE_SATS);
  });

  it("takes on new members at the roll", () => {
    setupBond(NEXT_BOND_INDEX);
    bindBond(NEXT_BOND_INDEX);
    expect(deposit(carol, ALICE_SATS).type).toBe("ok");
    // carol's sats sit in the treasury until the roll commits them
    expect(treasuryBalance()).toBe(ALICE_SATS);

    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");

    expect(Number(epoch(1)["total-shares"])).toBe(POOL_SATS + ALICE_SATS);
    expect(Number(settledMember(carol).shares)).toBe(ALICE_SATS);
    // pox-5 pulled only the difference out of the treasury
    expect(treasuryBalance()).toBe(0);
    expect(sbtcBalance(POX5)).toBe(POOL_SATS + ALICE_SATS);
  });

  it("keeps rolling, bond after bond", () => {
    expect(rollInto(NEXT_BOND_INDEX).type).toBe("ok");
    expect(rollInto(NEXT_BOND_INDEX + 6).type).toBe("ok");
    expect(Number(poolConfig()["epoch-count"])).toBe(3);
    expect(Number(epoch(2)["bond-index"])).toBe(NEXT_BOND_INDEX + 6);
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
    // epoch 1 only closes a cycle into epoch 2, so that is as far as a
    // settlement can carry her for now
    expect(Number(settledMember(alice)["settled-epoch"])).toBe(1);
  });

  it("stops at the wind-down", () => {
    setupBond(NEXT_BOND_INDEX); // create it while there is still time
    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc().type).toBe("ok");
    expect(bindBond(NEXT_BOND_INDEX)).toBeErr(Cl.uint(112)); // ALREADY_UNSTAKED
  });
});

describe("bond-staker: leaving at a roll", () => {
  beforeEach(() => {
    stakeFirstBond();
  });

  it("releases the member's principal and shares at the roll", () => {
    expect(requestExit(alice).type).toBe("ok");
    // nothing has moved yet -- the bond still holds it
    expect(claimPrincipal(alice)).toBeErr(Cl.uint(114)); // nothing released
    expect(Number(poolTotals()["exiting-sats"])).toBe(ALICE_SATS);

    expect(rollInto().type).toBe("ok");

    // the new bond is smaller by exactly alice's stake
    expect(Number(epoch(1)["total-shares"])).toBe(BOB_SATS);
    expect(sbtcBalance(POX5)).toBe(BOB_SATS);
    // ...and pox-5 refunded her sats, which went back to the treasury
    expect(treasuryBalance()).toBe(ALICE_SATS);
    expect(Number(poolTotals()["released-sats"])).toBe(ALICE_SATS);

    // her shares in epoch 0 outlive the roll -- that is what lets her
    // collect the bond's final cycle once it pays out
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
    advanceToBurnHeight(
      readPoxNum("reward-cycle-to-burn-height", [
        Cl.uint(Number(epoch(1)["first-reward-cycle"]) + 1),
      ]),
    );
    expect(Number(settledMember(alice).shares)).toBe(0);
    expect(Number(settledMember(bob).shares)).toBe(BOB_SATS);
  });

  it("pays the leaver back, both legs", () => {
    const ustx = requiredUstx(ALICE_SATS);
    requestExit(alice);
    rollInto();

    const sbtcBefore = sbtcBalance(alice);
    const stxBefore = stxBalance(alice);
    expect(claimablePrincipal(alice)).toEqual({
      "released-sats": String(ALICE_SATS),
      "released-ustx": String(ustx),
      "queued-sats": "0",
      "queued-ustx": "0",
    });
    expect(claimPrincipal(alice).type).toBe("ok");

    expect(sbtcBalance(alice)).toBe(sbtcBefore + ALICE_SATS);
    // pox-5 resized the STX lock down, so the STX is spendable again
    expect(stxBalance(alice)).toBe(stxBefore + ustx);
    expect(treasuryBalance()).toBe(0);
    expect(claimPrincipal(alice)).toBeErr(Cl.uint(114)); // NOTHING_TO_CLAIM
  });

  it("refunds a queued deposit immediately", () => {
    setupBond(NEXT_BOND_INDEX);
    bindBond(NEXT_BOND_INDEX);
    const sbtcBefore = sbtcBalance(alice);
    deposit(alice, ALICE_SATS);
    expect(requestExit(alice).type).toBe("ok");
    // the queued half never got committed, so it comes straight back
    expect(sbtcBalance(alice)).toBe(sbtcBefore);
    expect(Number(poolTotals()["queued-sats"])).toBe(0);
  });

  it("can be called off before the roll, but not after", () => {
    requestExit(alice);
    expect(cancelExit(alice).type).toBe("ok");
    expect(Number(poolTotals()["exiting-sats"])).toBe(0);

    rollInto();
    // alice stayed, so she is still in
    expect(Number(epoch(1)["total-shares"])).toBe(POOL_SATS);
    expect(cancelExit(alice)).toBeErr(Cl.uint(122)); // NOT_EXITING

    requestExit(bob);
    rollInto(NEXT_BOND_INDEX + 6);
    expect(cancelExit(bob)).toBeErr(Cl.uint(113)); // POSITION_ACTIVE
  });

  it("frees allocation room for someone else", () => {
    // fill the pool right up, then have alice leave
    setupBond(NEXT_BOND_INDEX);
    bindBond(NEXT_BOND_INDEX, POOL_SATS);
    expect(deposit(carol, 1)).toBeErr(Cl.uint(105)); // ALLOCATION_EXCEEDED
    requestExit(alice);
    expect(deposit(carol, ALICE_SATS).type).toBe("ok");
  });

  it("refuses an exit from someone with no committed position", () => {
    expect(requestExit(carol)).toBeErr(Cl.uint(110)); // NOTHING_DEPOSITED
    expect(requestExit(alice).type).toBe("ok");
    expect(requestExit(alice)).toBeErr(Cl.uint(123)); // ALREADY_EXITING
  });
});

describe("bond-staker: winding down", () => {
  let unlockHeight: number;

  beforeEach(() => {
    ({ unlockHeight } = stakeFirstBond());
  });

  it("holds the sBTC for the full 12 cycles", () => {
    expect(unstakeSbtc()).toBeErr(Cl.uint(108)); // TOO_EARLY
    advanceToBurnHeight(unlockHeight - 1);
    expect(unstakeSbtc()).toBeErr(Cl.uint(108));
  });

  it("returns the sBTC to the treasury and releases everyone", () => {
    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc(carol).type).toBe("ok"); // permissionless

    expect(treasuryBalance()).toBe(POOL_SATS);
    expect(sbtcBalance(poolPrincipal())).toBe(0);
    expect(poolConfig().finished).toBe(true);
    expect(unstakeSbtc()).toBeErr(Cl.uint(112)); // ALREADY_UNSTAKED
  });

  it("gives every member their deposit back, exactly", () => {
    const sbtcBefore = { alice: sbtcBalance(alice), bob: sbtcBalance(bob) };
    const stxBefore = { alice: stxBalance(alice), bob: stxBalance(bob) };

    advanceToBurnHeight(unlockHeight);
    unstakeSbtc();

    expect(claimPrincipal(alice).type).toBe("ok");
    expect(claimPrincipal(bob).type).toBe("ok");

    expect(sbtcBalance(alice)).toBe(sbtcBefore.alice + ALICE_SATS);
    expect(sbtcBalance(bob)).toBe(sbtcBefore.bob + BOB_SATS);
    expect(stxBalance(alice)).toBe(stxBefore.alice + requiredUstx(ALICE_SATS));
    expect(stxBalance(bob)).toBe(stxBefore.bob + requiredUstx(BOB_SATS));

    expect(treasuryBalance()).toBe(0);
    expect(Number(poolTotals()["released-sats"])).toBe(0);
    expect(claimPrincipal(alice)).toBeErr(Cl.uint(114)); // NOTHING_TO_CLAIM
  });
});

describe("bond-staker: per-bond reward accounting", () => {
  beforeEach(() => {
    stakeFirstBond();
  });

  it("splits a payout by the epoch's shares", () => {
    const pot = 4_000_000;
    payRewards(carol, pot);
    expect(syncRewards().type).toBe("ok");

    expect(claimableRewards(alice)).toBe((pot * ALICE_SATS) / POOL_SATS);
    expect(claimableRewards(bob)).toBe((pot * BOB_SATS) / POOL_SATS);
    expect(Number(epoch(0)["credited"])).toBe(pot);
  });

  it("pays rewards out and does not pay them twice", () => {
    payRewards(carol, 4_000_000);
    syncRewards();

    const before = sbtcBalance(alice);
    expect(claimRewards(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(
      before + (4_000_000 * ALICE_SATS) / POOL_SATS,
    );
    expect(claimRewards(alice)).toBeErr(Cl.uint(114)); // NOTHING_TO_CLAIM
  });

  it("keeps each bond's rewards in its own epoch", () => {
    // epoch 0 earns
    payRewards(carol, 4_000_000);
    syncRewards();
    claimRewards(alice);
    claimRewards(bob);

    // alice leaves at the roll; carol joins
    requestExit(alice);
    setupBond(NEXT_BOND_INDEX);
    bindBond(NEXT_BOND_INDEX);
    deposit(carol, ALICE_SATS);
    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");

    // epoch 0 stays open one more cycle, for its last cycle's rewards
    expect(rewardEpoch()).toBe(0);
    const tail = 1_200_000;
    payRewards(dave, tail);
    expect(Number(plain(syncRewards() as any).epoch)).toBe(0);
    // ...and that tail belongs to epoch 0's members, alice included
    expect(claimableRewards(alice)).toBe((tail * ALICE_SATS) / POOL_SATS);
    expect(claimableRewards(carol)).toBe(0);

    // once epoch 0 closes, everything lands in epoch 1
    advanceToBurnHeight(
      readPoxNum("reward-cycle-to-burn-height", [
        Cl.uint(Number(epoch(1)["first-reward-cycle"]) + 1),
      ]),
    );
    expect(rewardEpoch()).toBe(1);
    const second = 2_000_000;
    payRewards(dave, second);
    expect(Number(plain(syncRewards() as any).epoch)).toBe(1);

    // epoch 1's shares are bob's and carol's; alice earns nothing more
    const epochOneShares = BOB_SATS + ALICE_SATS;
    expect(claimableRewards(carol)).toBe((second * ALICE_SATS) / epochOneShares);
    expect(claimableRewards(alice)).toBe((tail * ALICE_SATS) / POOL_SATS);
  });

  it("lets a member who has left collect their last bond's rewards", () => {
    requestExit(alice);
    rollInto();
    // alice's principal is out, but her epoch-0 shares still earn
    expect(claimPrincipal(alice).type).toBe("ok");
    expect(Number(settledMember(alice)["bonded-sats"])).toBe(0);

    const tail = 1_200_000;
    payRewards(dave, tail);
    syncRewards();
    const before = sbtcBalance(alice);
    expect(claimRewards(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(before + (tail * ALICE_SATS) / POOL_SATS);
  });

  it("never hands out more than it took in", () => {
    const pot = 1_234_567; // does not divide evenly by the shares
    payRewards(carol, pot);
    syncRewards();

    const claimable = claimableRewards(alice) + claimableRewards(bob);
    expect(claimable).toBeLessThanOrEqual(pot);
    // the remainder stays for the next sync rather than vanishing
    expect(sbtcBalance(poolPrincipal())).toBe(pot);
  });

  it("never owes more than it has credited, across repeated syncs", () => {
    // Regression: crediting each sync's pot separately floored the pool's
    // credit once per sync, while a member's share is floored once against
    // the running index. floor(a) + floor(b) can be one short of
    // floor(a + b), so the last claimant's payout would abort. Found by the
    // rendezvous invariant `invariant-member-rewards-fit-the-pool`.
    let received = 0;
    for (const pot of [7, 13, 11, 1_234_567, 3]) {
      payRewards(carol, pot);
      received += pot;
      syncRewards();
    }

    const claimable = claimableRewards(alice) + claimableRewards(bob);
    expect(claimable).toBeLessThanOrEqual(
      Number(poolTotals()["unclaimed-rewards"]),
    );

    const before = sbtcBalance(alice) + sbtcBalance(bob);
    expect(claimRewards(alice).type).toBe("ok");
    expect(claimRewards(bob).type).toBe("ok");
    const paid = sbtcBalance(alice) + sbtcBalance(bob) - before;
    expect(paid).toBe(claimable);
    expect(paid).toBeLessThanOrEqual(received);
    expect(sbtcBalance(poolPrincipal())).toBe(received - paid);
  });

  it("has nothing to recognise without a payout", () => {
    expect(syncRewards()).toBeErr(Cl.uint(114)); // NOTHING_TO_CLAIM
  });
});

describe("bond-staker: rewards across many epochs", () => {
  it("settles a member who sat out several rolls", () => {
    stakeFirstBond();

    payRewards(carol, 4_000_000);
    syncRewards();
    rollInto(NEXT_BOND_INDEX);
    payRewards(carol, 4_000_000);
    syncRewards(); // still epoch 0's tail window
    advanceToBurnHeight(
      readPoxNum("reward-cycle-to-burn-height", [
        Cl.uint(Number(epoch(1)["first-reward-cycle"]) + 1),
      ]),
    );
    payRewards(carol, 8_000_000);
    syncRewards(); // epoch 1
    rollInto(NEXT_BOND_INDEX + 6);

    // alice has not touched the contract since epoch 0; one settlement
    // catches her up across every closed epoch
    expect(Number(member(alice)["settled-epoch"])).toBe(0);
    // epoch 0 paid 8m in two goes, epoch 1 another 8m; epoch 1 is still open
    // so its accrual settles in place rather than being closed out
    const expected =
      (8_000_000 * ALICE_SATS) / POOL_SATS + (8_000_000 * ALICE_SATS) / POOL_SATS;
    expect(claimableRewards(alice)).toBe(expected);

    const before = sbtcBalance(alice);
    expect(claimRewards(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(before + expected);
    expect(Number(member(alice)["settled-epoch"])).toBe(1);
  });
});

describe("bond-staker: moving to another signer", () => {
  const altPrincipal = () => managerPrincipal(ALT_MANAGER);

  beforeEach(() => {
    stakeFirstBond();
    registerSignerManager(ALT_MANAGER, 7);
  });

  it("is the operator's call, not anyone else's", () => {
    expect(
      updateBondRegistration(altPrincipal(), managerPrincipal(), alice),
    ).toBeErr(Cl.uint(100)); // UNAUTHORIZED
  });

  it("checks the current signer manager was named correctly", () => {
    expect(updateBondRegistration(altPrincipal(), altPrincipal())).toBeErr(
      Cl.uint(111),
    );
  });

  it("re-points the position and the pool's own pin", () => {
    expect(
      updateBondRegistration(altPrincipal(), managerPrincipal()).type,
    ).toBe("ok");

    const membership = plain(
      simnet.callReadOnlyFn(
        POX5,
        "get-bond-membership",
        [Cl.principal(poolPrincipal())],
        deployer,
      ).result,
    );
    expect(membership.signer).toBe(altPrincipal());
    expect(poolConfig()["signer-manager"]).toBe(altPrincipal());
    // the position is untouched
    expect(Number(membership["amount-sats"])).toBe(POOL_SATS);
  });
});

describe("bond-treasury", () => {
  it("takes orders from nobody but the bond staker", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    for (const who of [alice, deployer]) {
      expect(
        simnet.callPublicFn(
          TREASURY,
          "payout",
          [Cl.uint(ALICE_SATS), Cl.principal(who)],
          who,
        ).result,
      ).toBeErr(Cl.uint(200)); // UNAUTHORIZED
    }
    expect(treasuryBalance()).toBe(ALICE_SATS);
    expect(
      plain(
        simnet.callReadOnlyFn(TREASURY, "get-controller", [], deployer).result,
      ),
    ).toBe(poolPrincipal());
  });

  it("keeps the pool's own sBTC free of principal all the way through", () => {
    const { unlockHeight } = stakeFirstBond();
    expect(sbtcBalance(poolPrincipal())).toBe(0);

    // every satoshi the pool holds is reward, with no reserve to net off
    payRewards(carol, 4_000_000);
    expect(num(readPool("get-unrecognized-rewards"))).toBe(4_000_000);

    advanceToBurnHeight(unlockHeight);
    unstakeSbtc();
    // the returned principal went to the treasury, so it is not seen as reward
    expect(num(readPool("get-unrecognized-rewards"))).toBe(4_000_000);
    expect(treasuryBalance()).toBe(POOL_SATS);
  });

  it("holds exactly the queued and released principal", () => {
    stakeFirstBond();
    expect(treasuryBalance()).toBe(0);

    requestExit(alice);
    setupBond(NEXT_BOND_INDEX);
    bindBond(NEXT_BOND_INDEX);
    deposit(carol, ALICE_SATS);
    const pool = () => poolTotals();
    expect(treasuryBalance()).toBe(Number(pool()["queued-sats"]));

    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    stake();
    expect(treasuryBalance()).toBe(
      Number(pool()["queued-sats"]) + Number(pool()["released-sats"]),
    );
    expect(Number(pool()["released-sats"])).toBe(ALICE_SATS);
  });
});

describe("bond-staker: a roll that does not fit", () => {
  /**
   * Carry members out of the epoch that just ended. A position only moves
   * once the epoch it was in stops taking rewards, a cycle into the next one.
   */
  function closeOutgoingEpoch() {
    advanceToBurnHeight(
      readPoxNum("reward-cycle-to-burn-height", [
        Cl.uint(Number(epoch(1)["first-reward-cycle"]) + 1),
      ]),
    );
  }

  /** Bond 8, priced so the pool's STX carries only half its sats. */
  function bindDearerBond(ratio = STX_VALUE_RATIO * 2, maxSats = MAX_SATS) {
    setupBond(NEXT_BOND_INDEX, ALLOWANCE_SATS, ratio);
    expect(bindBond(NEXT_BOND_INDEX, maxSats).type).toBe("ok");
  }

  it("shows the shortfall before the window opens", () => {
    stakeFirstBond();
    bindDearerBond();

    const preview = stakePreview();
    expect(Number(preview["eligible-sats"])).toBe(POOL_SATS);
    // twice the STX per sat, so half the sats fit
    expect(Number(preview.sats)).toBe(POOL_SATS / 2);
    expect(preview.scaled).toBe(true);
    expect(preview["stx-limited"]).toBe(true);
    expect(preview["allocation-limited"]).toBe(false);
    // the STX the pool holds is exactly half of what carrying it all needs
    expect(Number(preview["short-ustx"])).toBe(Number(preview.ustx));
  });

  it("rolls what fits instead of failing", () => {
    stakeFirstBond();
    bindDearerBond();
    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");

    const one = epoch(1);
    expect(Number(one["eligible-sats"])).toBe(POOL_SATS);
    expect(Number(one["total-shares"])).toBe(POOL_SATS / 2);
    // pox-5 gave the other half back, and it is in the treasury
    expect(sbtcBalance(POX5)).toBe(POOL_SATS / 2);
    expect(treasuryBalance()).toBe(POOL_SATS / 2);
  });

  it("scales every member by the same fraction", () => {
    stakeFirstBond();
    bindDearerBond();
    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    stake();
    closeOutgoingEpoch();

    for (const [who, sats] of [
      [alice, ALICE_SATS],
      [bob, BOB_SATS],
    ] as const) {
      const record = settledMember(who);
      expect(Number(record.shares)).toBe(sats / 2);
      expect(Number(record["bonded-sats"])).toBe(sats / 2);
      // the half that did not fit is theirs to take back
      expect(Number(record["released-sats"])).toBe(sats / 2);
      // ...while all of their STX rides on
      expect(Number(record["bonded-ustx"])).toBe(requiredUstx(sats) / 2);
      expect(Number(record["released-ustx"])).toBe(0);
    }
    // the members' shares still add up to the epoch's
    expect(
      Number(settledMember(alice).shares) + Number(settledMember(bob).shares),
    ).toBe(Number(epoch(1)["total-shares"]));
  });

  it("pays the scaled-off principal out on demand", () => {
    stakeFirstBond();
    bindDearerBond();
    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    stake();
    closeOutgoingEpoch();

    const before = sbtcBalance(alice);
    expect(claimPrincipal(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(before + ALICE_SATS / 2);
    // the rest is still committed to the new bond
    expect(Number(settledMember(alice)["bonded-sats"])).toBe(ALICE_SATS / 2);
  });

  it("scales back to the allocation when that is what bites", () => {
    stakeFirstBond();
    // same pricing, but the bond only has room for a quarter of the pool
    setupBond(NEXT_BOND_INDEX);
    expect(bindBond(NEXT_BOND_INDEX, POOL_SATS / 4).type).toBe("ok");

    const preview = stakePreview();
    expect(preview["allocation-limited"]).toBe(true);
    expect(preview["stx-limited"]).toBe(false);

    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");
    expect(Number(epoch(1)["total-shares"])).toBe(POOL_SATS / 4);
    closeOutgoingEpoch();
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS / 4);
    // all the STX still rides, so the position is over-collateralised
    expect(Number(epoch(1)["staked-ustx"])).toBe(
      requiredUstx(ALICE_SATS) + requiredUstx(BOB_SATS),
    );
  });

  it("takes an STX top-up instead, if someone closes the gap", () => {
    stakeFirstBond();
    bindDearerBond();

    const short = Number(stakePreview()["short-ustx"]);
    expect(short).toBeGreaterThan(0);
    expect(depositStx(carol, short).type).toBe("ok");

    const preview = stakePreview();
    expect(preview.scaled).toBe(false);
    expect(Number(preview.sats)).toBe(POOL_SATS);

    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");
    // nobody was scaled back
    expect(Number(epoch(1)["total-shares"])).toBe(POOL_SATS);
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
    // and carol gets her STX back like any other deposit -- with no shares,
    // since she put in no sats
    expect(Number(settledMember(carol).shares)).toBe(0);
    expect(Number(settledMember(carol)["bonded-ustx"])).toBe(short);
  });

  it("still stakes something when the bond is priced absurdly", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    // a bond a million times dearer in STX terms
    setupBond(NEXT_BOND_INDEX, ALLOWANCE_SATS, STX_VALUE_RATIO * 1_000_000);
    // the first bond came and went unstaked, so bind can replace it
    expect(bindBond(NEXT_BOND_INDEX).type).toBe("ok");
    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");

    // a millionth of the sats fit; the rest is alice's to take back
    expect(Number(epoch(0)["total-shares"])).toBe(ALICE_SATS / 1_000_000);
    expect(Number(settledMember(alice)["released-sats"])).toBe(
      ALICE_SATS - ALICE_SATS / 1_000_000,
    );
  });
});

describe("bond-staker: a missed bond", () => {
  it("can be replaced instead of stranding the pool", () => {
    const { bondStart } = bootstrap();
    deposit(alice, ALICE_SATS);

    // the window comes and goes with nobody calling `stake`
    advanceToBurnHeight(bondStart + 1);
    expect(stake()).toBeErr(Cl.uint(109)); // TOO_LATE
    expect(boundBond().stakeable).toBe(false);

    // the pool is not stuck: the operator binds the next bond along
    setupBond(NEXT_BOND_INDEX);
    expect(bindBond(NEXT_BOND_INDEX).type).toBe("ok");
    expect(deposit(bob, BOB_SATS).type).toBe("ok");

    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");
    expect(Number(epoch(0)["bond-index"])).toBe(NEXT_BOND_INDEX);
    expect(Number(epoch(0)["total-shares"])).toBe(ALICE_SATS + BOB_SATS);
  });

  it("cannot be replaced while its window is still ahead", () => {
    bootstrap();
    expect(boundBond().stakeable).toBe(true);
    expect(bindBond(BOND_INDEX)).toBeErr(Cl.uint(119)); // ALREADY_BOUND
  });
});
