import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import {
  advanceToBurnHeight,
  BRIDGE,
  canUseSigner,
  isOperator,
  updateOperator,
  distrustSigner,
  signerHash,
  trustedSigner,
  trustSigner,
  bridgePrincipal,
  btcRecipient,
  readBridge,
  readTreasury,
  announceBtcDeposit,
  btcDeposit,
  btcWithdrawal,
  cancelBtcCommitment,
  cancelBtcDeposit,
  commitBtcDeposit,
  depositDigest,
  revealBtcDeposit,
  SALT,
  REVEAL_DELAY,
  COMMIT_TTL,
  ANNOUNCE_TTL,
  claimPrincipalToBtc,
  confirmBtcDeposit,
  reclaimBtcWithdrawal,
  SBTC_REGISTRY,
  settleBtcWithdrawal,
  sweepBtcDeposit,
  sweepUnattributed,
  unattributedPrincipal,
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
  settleMember,
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
    // positions move with the pool, so she is carried all the way
    expect(Number(settledMember(alice)["settled-epoch"])).toBe(2);
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

    // the roll carries her out: no shares in the new bond, and her principal
    // is claimable at once
    expect(Number(settledMember(alice).shares)).toBe(0);
    expect(Number(settledMember(alice)["released-sats"])).toBe(ALICE_SATS);
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
    // the roll spent the request, so there is nothing left to call off
    expect(cancelExit(bob)).toBeErr(Cl.uint(122)); // NOT_EXITING
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

  it("clears the exit flag at the roll, so a leaver can come back", () => {
    requestExit(alice);
    expect(rollInto().type).toBe("ok");
    // the roll spent the request: nothing is left asking to leave
    expect(settledMember(alice)["exit-epoch"]).toBeNull();
    expect(claimPrincipal(alice).type).toBe("ok");

    // and she can join the bond after next like anyone else
    const next = NEXT_BOND_INDEX + 6;
    setupBond(next);
    expect(bindBond(next, MAX_SATS).type).toBe("ok");
    expect(deposit(alice, ALICE_SATS).type).toBe("ok");
    expect(Number(settledMember(alice)["queued-sats"])).toBe(ALICE_SATS);

    // re-entry restores a normal position, the right to leave included
    advanceToBurnHeight(bondStartHeight(next) - 288);
    expect(stake().type).toBe("ok");
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
    expect(requestExit(alice).type).toBe("ok");
  });

  it("keeps the exit flag set until the roll actually realises it", () => {
    setupBond(NEXT_BOND_INDEX);
    expect(bindBond(NEXT_BOND_INDEX, MAX_SATS).type).toBe("ok");

    requestExit(alice);
    // still pending: the pool has not rolled, so it must still bar deposits
    expect(settledMember(alice)["exit-epoch"]).not.toBeNull();
    expect(deposit(alice, ALICE_SATS)).toBeErr(Cl.uint(123)); // ALREADY_EXITING

    expect(cancelExit(alice).type).toBe("ok");
    expect(settledMember(alice)["exit-epoch"]).toBeNull();
    expect(deposit(alice, ALICE_SATS).type).toBe("ok");
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

    // pox-5 settles a cycle after it ends, so epoch 0's last cycle pays out
    // now -- and it is still epoch 0's money
    expect(rewardEpoch()).toBe(0);
    const tail = 1_200_000;
    payRewards(dave, tail);
    expect(Number(plain(syncRewards() as any).epoch)).toBe(0);

    expect(claimableRewards(alice)).toBe((tail * ALICE_SATS) / POOL_SATS);
    expect(claimableRewards(bob)).toBe((tail * BOB_SATS) / POOL_SATS);
    // carol was not in that bond
    expect(claimableRewards(carol)).toBe(0);

    // once epoch 0 has settled, everything lands in epoch 1
    advanceToBurnHeight(
      readPoxNum("reward-cycle-to-burn-height", [
        Cl.uint(Number(epoch(1)["first-reward-cycle"]) + 1),
      ]),
    );
    expect(rewardEpoch()).toBe(1);
    const second = 2_000_000;
    payRewards(dave, second);
    expect(Number(plain(syncRewards() as any).epoch)).toBe(1);

    const epochOneShares = BOB_SATS + ALICE_SATS;
    expect(claimableRewards(carol)).toBe((second * ALICE_SATS) / epochOneShares);
    // alice's claim stopped growing when epoch 0 settled
    expect(claimableRewards(alice)).toBe((tail * ALICE_SATS) / POOL_SATS);
    expect(Number(epoch(0)["credited"])).toBe(4_000_000 + tail);
    expect(Number(epoch(1)["credited"])).toBe(second);
  });

  it("hands a leaver their principal at the roll, and their last rewards after", () => {
    requestExit(alice);
    rollInto();

    // her position is out of the bond and claimable straight away
    expect(Number(settledMember(alice)["released-sats"])).toBe(ALICE_SATS);
    expect(Number(settledMember(alice).shares)).toBe(0);
    const before = sbtcBalance(alice);
    expect(claimPrincipal(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(before + ALICE_SATS);

    // her claim on the bond she was in is stashed, and still pays out
    expect(Number(settledMember(alice)["tail-shares"])).toBe(ALICE_SATS);
    const tail = 1_200_000;
    payRewards(dave, tail);
    syncRewards();
    expect(claimableRewards(alice)).toBe((tail * ALICE_SATS) / POOL_SATS);

    const paid = sbtcBalance(alice);
    expect(claimRewards(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(paid + (tail * ALICE_SATS) / POOL_SATS);

    // and once that epoch settles the stash is let go
    advanceToBurnHeight(
      readPoxNum("reward-cycle-to-burn-height", [
        Cl.uint(Number(epoch(1)["first-reward-cycle"]) + 1),
      ]),
    );
    expect(settleMember(alice).type).toBe("ok");
    expect(member(alice)["tail-epoch"]).toBeNull();
    expect(Number(member(alice)["tail-shares"])).toBe(0);
    // later rewards are epoch 1's, and she has no shares there
    payRewards(dave, 2_000_000);
    syncRewards();
    expect(claimableRewards(alice)).toBe(0);
  });

  it("counts the epoch either side of the roll exactly once", () => {
    // accrue and claim part of epoch 0 before the roll...
    payRewards(carol, 4_000_000);
    syncRewards();
    expect(claimRewards(alice).type).toBe("ok");
    expect(claimRewards(bob).type).toBe("ok");

    // ...roll, which stashes what is left of their claim on it...
    rollInto();

    // ...and pay the rest of epoch 0 afterwards
    payRewards(dave, 1_200_000);
    syncRewards();

    const total = 5_200_000;
    const paidBefore = 4_000_000;
    expect(claimableRewards(alice)).toBe(
      (total * ALICE_SATS) / POOL_SATS - (paidBefore * ALICE_SATS) / POOL_SATS,
    );
    expect(claimableRewards(bob)).toBe(
      (total * BOB_SATS) / POOL_SATS - (paidBefore * BOB_SATS) / POOL_SATS,
    );
    // between them they are owed exactly what epoch 0 was credited, no more
    expect(
      claimableRewards(alice) + claimableRewards(bob) + paidBefore,
    ).toBe(Number(epoch(0)["credited"]));
    expect(
      claimableRewards(alice) + claimableRewards(bob),
    ).toBeLessThanOrEqual(Number(poolTotals()["unclaimed-rewards"]));
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
    syncRewards(); // epoch 0
    rollInto(NEXT_BOND_INDEX);
    payRewards(carol, 4_000_000);
    syncRewards(); // still epoch 0: its last cycle
    advanceToBurnHeight(
      readPoxNum("reward-cycle-to-burn-height", [
        Cl.uint(Number(epoch(1)["first-reward-cycle"]) + 1),
      ]),
    );
    payRewards(carol, 8_000_000);
    syncRewards(); // epoch 1
    rollInto(NEXT_BOND_INDEX + 6);

    // alice has not touched the contract since epoch 0; one settlement
    // catches her up across every epoch she was part of
    expect(Number(member(alice)["settled-epoch"])).toBe(0);
    // 8m to epoch 0 across two syncs, 8m to epoch 1
    const expected = (16_000_000 * ALICE_SATS) / POOL_SATS;
    expect(claimableRewards(alice)).toBe(expected);

    const before = sbtcBalance(alice);
    expect(claimRewards(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(before + expected);
    expect(Number(member(alice)["settled-epoch"])).toBe(2);
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

  it("will not move onto a signer manager nobody vetted", () => {
    expect(canUseSigner(altPrincipal())).toBe(false);
    expect(updateBondRegistration(altPrincipal(), managerPrincipal())).toBeErr(
      Cl.uint(126), // SIGNER_NOT_TRUSTED
    );
  });

  it("holds a newly trusted hash until the pool rolls", () => {
    const hash = signerHash(altPrincipal());
    expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(trustSigner(hash, alice)).toBeErr(Cl.uint(100)); // operator only

    expect(trustSigner(hash).type).toBe("ok");
    // on chain from the moment it is added, so members can see it coming
    expect(Number(trustedSigner(hash))).toBe(1);
    expect(canUseSigner(altPrincipal())).toBe(false);
    expect(updateBondRegistration(altPrincipal(), managerPrincipal())).toBeErr(
      Cl.uint(126),
    );
    // ...and re-adding must not restart the clock
    expect(trustSigner(hash)).toBeErr(Cl.uint(127)); // ALREADY_TRUSTED

    // time alone does not unlock it -- only the roll does, because the roll is
    // the one moment a member who objects can be gone
    advanceToBurnHeight(simnet.burnBlockHeight + 4 * CYCLE_LENGTH);
    expect(canUseSigner(altPrincipal())).toBe(false);

    expect(rollInto().type).toBe("ok");
    expect(canUseSigner(altPrincipal())).toBe(true);
    expect(
      updateBondRegistration(altPrincipal(), managerPrincipal()).type,
    ).toBe("ok");
  });

  it("keeps an emergency switch open to an already-vetted manager", () => {
    // trusted before the epoch was staked, so it needs no further wait
    const hash = signerHash(altPrincipal());
    trustSigner(hash);
    rollInto();
    // mid-bond, with no roll in sight, the operator can still move onto it
    expect(
      updateBondRegistration(altPrincipal(), managerPrincipal()).type,
    ).toBe("ok");
    expect(poolConfig()["signer-manager"]).toBe(altPrincipal());
  });

  it("drops a hash at once, with no delay to wait out", () => {
    const hash = signerHash(altPrincipal());
    trustSigner(hash);
    rollInto();
    expect(canUseSigner(altPrincipal())).toBe(true);

    expect(distrustSigner(hash, alice)).toBeErr(Cl.uint(100)); // operator only
    expect(distrustSigner(hash).type).toBe("ok");
    expect(canUseSigner(altPrincipal())).toBe(false);
    expect(updateBondRegistration(altPrincipal(), managerPrincipal())).toBeErr(
      Cl.uint(126),
    );
    expect(distrustSigner(hash)).toBeErr(Cl.uint(126)); // nothing to remove
  });

  it("re-points the position and the pool's own pin", () => {
    trustSigner(signerHash(altPrincipal()));
    rollInto();
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

  it("trusts the manager it was initialized with, from the start", () => {
    expect(canUseSigner(managerPrincipal())).toBe(true);
    expect(Number(trustedSigner(signerHash(managerPrincipal())))).toBe(0);
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

describe("bond-staker: joining with L1 bitcoin", () => {
  const TXID = "a1".repeat(32);

  it("names the treasury as the address to bridge to", () => {
    bootstrap();
    const result = plain(announceBtcDeposit(alice, TXID, ALICE_SATS) as any);
    expect(result["deposit-to"]).toBe(treasuryPrincipal());
    expect(plain(readBridge("get-deposit-address"))).toBe(treasuryPrincipal());
  });

  it("takes the STX leg up front and holds the allocation", () => {
    bootstrap();
    const ustx = requiredUstx(ALICE_SATS);
    const stxBefore = stxBalance(alice);

    expect(announceBtcDeposit(alice, TXID, ALICE_SATS).type).toBe("ok");

    // the STX is paid now; the sats are still on bitcoin. The bridge holds the
    // STX until the deposit lands -- the ledger only counts what it has.
    expect(stxBalance(alice)).toBe(stxBefore - ustx);
    expect(stxBalance(bridgePrincipal())).toBe(ustx);
    expect(stxBalance(poolPrincipal())).toBe(0);
    expect(treasuryBalance()).toBe(0);
    expect(Number(poolTotals()["announced-sats"])).toBe(ALICE_SATS);
    expect(Number(poolTotals()["queued-sats"])).toBe(0);
    // ...and it counts against the pool's room
    expect(num(readPool("get-committing-sats"))).toBe(ALICE_SATS);
    expect(Number(btcDeposit(TXID).sats)).toBe(ALICE_SATS);
  });

  it("queues the sats once the signers sweep the deposit", () => {
    bootstrap();
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    expect(confirmBtcDeposit(TXID)).toBeErr(Cl.uint(304)); // NOT_SWEPT

    expect(sweepBtcDeposit(TXID, ALICE_SATS).type).toBe("ok");
    expect(treasuryBalance()).toBe(ALICE_SATS);
    // permissionless: a keeper can finish the job
    expect(confirmBtcDeposit(TXID, 0, carol).type).toBe("ok");

    expect(Number(poolTotals()["announced-sats"])).toBe(0);
    expect(Number(poolTotals()["queued-sats"])).toBe(ALICE_SATS);
    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
    expect(Number(member(alice)["queued-ustx"])).toBe(requiredUstx(ALICE_SATS));
    // the STX leg moved from the bridge to the ledger with the sats
    expect(stxBalance(bridgePrincipal())).toBe(0);
    expect(stxBalance(poolPrincipal())).toBe(requiredUstx(ALICE_SATS));
    expect(btcDeposit(TXID)).toBeNull();
    // alice never touched sBTC
    expect(sbtcBalance(alice)).toBe(1_000_000_000);
  });

  it("credits what arrived when the signers' fee eats into the deposit", () => {
    bootstrap();
    const SWEEP_FEE = 20_000;
    const arrived = ALICE_SATS - SWEEP_FEE;
    const ustx = requiredUstx(ALICE_SATS);

    expect(announceBtcDeposit(alice, TXID, ALICE_SATS).type).toBe("ok");
    expect(sweepBtcDeposit(TXID, arrived).type).toBe("ok");
    expect(confirmBtcDeposit(TXID).type).toBe("ok");

    // the position is what the treasury actually holds, not what was announced
    expect(treasuryBalance()).toBe(arrived);
    expect(Number(member(alice)["queued-sats"])).toBe(arrived);
    expect(Number(poolTotals()["queued-sats"])).toBe(arrived);
    // the STX leg follows the announcement, and is the member's to reclaim
    expect(Number(member(alice)["queued-ustx"])).toBe(ustx);
    expect(stxBalance(bridgePrincipal())).toBe(0);
    // the room the shortfall was holding is released, not left reserved
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
    expect(num(readPool("get-committing-sats"))).toBe(arrived);
    expect(btcDeposit(TXID)).toBeNull();
  });

  it("does not strand a short deposit: it can never be left unconfirmable", () => {
    bootstrap();
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    expect(sweepBtcDeposit(TXID, ALICE_SATS - 1).type).toBe("ok");
    // cancelling is barred once swept, so confirm has to be the way out
    expect(cancelBtcDeposit(TXID, 0, alice)).toBeErr(Cl.uint(307)); // SWEPT
    expect(confirmBtcDeposit(TXID).type).toBe("ok");
    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS - 1);
  });

  it("credits only what was announced when more arrives than expected", () => {
    bootstrap();
    const extra = 5_000;
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    expect(sweepBtcDeposit(TXID, ALICE_SATS + extra).type).toBe("ok");
    expect(confirmBtcDeposit(TXID).type).toBe("ok");

    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
    // the overpayment is in the treasury attributed to nobody
    expect(treasuryBalance()).toBe(ALICE_SATS + extra);
    expect(Number(unattributedPrincipal())).toBe(extra);
  });

  it("carries an L1 joiner into the bond like any other member", () => {
    const { bondStart } = bootstrap();
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    sweepBtcDeposit(TXID, ALICE_SATS);
    confirmBtcDeposit(TXID);

    advanceToBurnHeight(bondStart - 288);
    expect(stake().type).toBe("ok");
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
    expect(sbtcBalance(POX5)).toBe(ALICE_SATS);
  });

  it("will not confirm a deposit the bridge sent somewhere else", () => {
    bootstrap();
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    // swept to the pool instead of the treasury
    sweepBtcDeposit(TXID, ALICE_SATS, poolPrincipal());
    expect(confirmBtcDeposit(TXID)).toBeErr(Cl.uint(305)); // MISDIRECTED
  });

  it("cannot be announced twice, or after the sweep", () => {
    bootstrap();
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    expect(announceBtcDeposit(bob, TXID, ALICE_SATS)).toBeErr(Cl.uint(303));

    const other = "a2".repeat(32);
    sweepBtcDeposit(other, ALICE_SATS);
    expect(announceBtcDeposit(bob, other, ALICE_SATS)).toBeErr(Cl.uint(307));
  });

  it("hands the STX back when an announcement is called off", () => {
    bootstrap();
    const stxBefore = stxBalance(alice);
    announceBtcDeposit(alice, TXID, ALICE_SATS);

    // nobody else can cancel it while it is live
    expect(cancelBtcDeposit(TXID, 0, bob)).toBeErr(Cl.uint(308));
    expect(cancelBtcDeposit(TXID, 0, alice).type).toBe("ok");

    expect(stxBalance(alice)).toBe(stxBefore);
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
    expect(btcDeposit(TXID)).toBeNull();
  });

  it("lets anyone free the room once the announcement has gone stale", () => {
    bootstrap();
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    simnet.mineEmptyBurnBlocks(1000);
    expect(cancelBtcDeposit(TXID, 0, bob).type).toBe("ok");
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
  });

  it("cannot be cancelled once the sats have landed", () => {
    bootstrap();
    announceBtcDeposit(alice, TXID, ALICE_SATS);
    sweepBtcDeposit(TXID, ALICE_SATS);
    expect(cancelBtcDeposit(TXID, 0, alice)).toBeErr(Cl.uint(307));
  });

  it("counts announcements against the allocation", () => {
    bootstrap();
    announceBtcDeposit(alice, TXID, MAX_SATS);
    expect(deposit(bob, 1)).toBeErr(Cl.uint(105)); // ALLOCATION_EXCEEDED
    cancelBtcDeposit(TXID, 0, alice);
    expect(deposit(bob, 1).type).toBe("ok");
  });
});

describe("bond-staker: committing and revealing an L1 deposit", () => {
  const TXID = "ab".repeat(32);
  const digest = () => depositDigest(TXID, 0, SALT);

  beforeEach(() => {
    bootstrap();
  });

  it("will not reveal in the same block as the commit", () => {
    expect(commitBtcDeposit(alice, digest(), ALICE_SATS).type).toBe("ok");
    expect(revealBtcDeposit(alice, TXID)).toBeErr(Cl.uint(314)); // TOO_SOON
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcDeposit(alice, TXID).type).toBe("ok");
  });

  it("will not reveal a txid nobody committed to", () => {
    expect(revealBtcDeposit(alice, TXID)).toBeErr(Cl.uint(312)); // UNKNOWN
  });

  it("gives the txid to the first reveal, so a watcher is always late", () => {
    // Alice commits and reveals. Only now is the txid public anywhere.
    expect(commitBtcDeposit(alice, digest(), ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcDeposit(alice, TXID).type).toBe("ok");

    // Carol reads it off the reveal and races the rest of the flow. Even
    // knowing the salt, the txid is already spoken for.
    expect(commitBtcDeposit(carol, digest(), ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcDeposit(carol, TXID)).toBeErr(Cl.uint(303)); // ANNOUNCED

    // The sats go where the first reveal said they would.
    expect(sweepBtcDeposit(TXID, ALICE_SATS).type).toBe("ok");
    expect(confirmBtcDeposit(TXID).type).toBe("ok");
    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
    expect(member(carol)).toBeNull();
  });

  it("lets a copied digest block nobody: commitments are keyed by member", () => {
    // Carol lifts alice's digest out of the mempool and commits it first.
    expect(commitBtcDeposit(carol, digest(), ALICE_SATS).type).toBe("ok");
    // Alice's own commit is unaffected.
    expect(commitBtcDeposit(alice, digest(), ALICE_SATS).type).toBe("ok");
    // ...and she cannot commit the same one twice.
    expect(commitBtcDeposit(alice, digest(), ALICE_SATS)).toBeErr(Cl.uint(313));

    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcDeposit(alice, TXID).type).toBe("ok");
  });

  it("will not reveal a transaction the signers have already swept", () => {
    expect(commitBtcDeposit(alice, digest(), ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    // Someone deposited to the treasury without announcing; those sats are
    // unattributed and a reveal must not be able to pick them up.
    expect(sweepBtcDeposit(TXID, ALICE_SATS).type).toBe("ok");
    expect(revealBtcDeposit(alice, TXID)).toBeErr(Cl.uint(307)); // SWEPT
  });

  it("hands back the STX and the room when a commitment is abandoned", () => {
    const ustx = requiredUstx(ALICE_SATS);
    const stxBefore = stxBalance(alice);
    expect(commitBtcDeposit(alice, digest(), ALICE_SATS).type).toBe("ok");
    expect(stxBalance(alice)).toBe(stxBefore - ustx);
    expect(num(readPool("get-committing-sats"))).toBe(ALICE_SATS);

    // A stranger cannot cancel it while it is live...
    expect(cancelBtcCommitment(alice, digest(), carol)).toBeErr(Cl.uint(308));
    // ...but the member can, whenever.
    expect(cancelBtcCommitment(alice, digest()).type).toBe("ok");
    expect(stxBalance(alice)).toBe(stxBefore);
    expect(num(readPool("get-committing-sats"))).toBe(0);
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
  });

  it("lets anyone clear a commitment that has gone stale", () => {
    const stxBefore = stxBalance(alice);
    expect(commitBtcDeposit(alice, digest(), ALICE_SATS).type).toBe("ok");

    // not a moment before COMMIT_TTL...
    simnet.mineEmptyBurnBlocks(COMMIT_TTL - 1);
    expect(cancelBtcCommitment(alice, digest(), carol)).toBeErr(Cl.uint(308));

    simnet.mineEmptyBurnBlocks(1);
    expect(cancelBtcCommitment(alice, digest(), carol).type).toBe("ok");
    expect(num(readPool("get-committing-sats"))).toBe(0);
    // the STX goes back to the member, not to whoever cleared it
    expect(stxBalance(alice)).toBe(stxBefore);
  });

  it("clears a commitment far sooner than a revealed deposit", () => {
    // A commitment is not a deposit in flight: nothing has been broadcast, so
    // it does not get the week that a revealed one does.
    expect(COMMIT_TTL).toBeLessThan(ANNOUNCE_TTL);

    expect(commitBtcDeposit(alice, digest(), ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcDeposit(alice, TXID).type).toBe("ok");

    // past COMMIT_TTL, but this one is revealed and holds its week
    simnet.mineEmptyBurnBlocks(COMMIT_TTL);
    expect(cancelBtcDeposit(TXID, 0, carol)).toBeErr(Cl.uint(308)); // LIVE
    expect(cancelBtcDeposit(TXID, 0, alice).type).toBe("ok"); // its owner may
  });
});

describe("bond-staker: leaving over the sBTC bridge", () => {
  const MAX_FEE = 10_000;

  /** A member with released principal, ready to be paid out. */
  function readyToLeave() {
    const { unlockHeight } = stakeFirstBond();
    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc().type).toBe("ok");
    return unlockHeight;
  }

  it("asks the bridge to pay a bitcoin address", () => {
    readyToLeave();
    const result = plain(claimPrincipalToBtc(alice, MAX_FEE) as any);

    expect(Number(result.sats)).toBe(ALICE_SATS);
    expect(Number(result.amount)).toBe(ALICE_SATS - MAX_FEE);
    expect(Number(result["max-fee"])).toBe(MAX_FEE);

    // the request is the treasury's, so a refund cannot be read as reward
    const request = plain(
      simnet.callReadOnlyFn(
        SBTC_REGISTRY,
        "get-withdrawal-request",
        [Cl.uint(Number(result["request-id"]))],
        deployer,
      ).result,
    );
    expect(request.sender).toBe(treasuryPrincipal());
    expect(Number(request.amount)).toBe(ALICE_SATS - MAX_FEE);

    // the sats moved from "released" to "withdrawing" and are still on the
    // treasury's balance, locked by the bridge
    const pool = poolTotals();
    expect(Number(pool["released-sats"])).toBe(BOB_SATS);
    expect(Number(pool["withdrawing-sats"])).toBe(ALICE_SATS);
    expect(treasuryBalance()).toBe(POOL_SATS);
    expect(Number(settledMember(alice)["released-sats"])).toBe(0);
  });

  it("is the member's call alone, and only for what they hold", () => {
    readyToLeave();
    // nobody can spend someone else's sats on a fee
    expect(claimPrincipalToBtc(carol, MAX_FEE)).toBeErr(Cl.uint(110));
    // a fee bigger than the position is not a withdrawal
    expect(claimPrincipalToBtc(alice, ALICE_SATS)).toBeErr(Cl.uint(116));
  });

  it("burns the sats and pays out bitcoin when the signers accept", () => {
    readyToLeave();
    const id = Number(plain(claimPrincipalToBtc(alice, MAX_FEE) as any)["request-id"]);
    const fee = 1_000;
    expect(settleBtcWithdrawal(id, true, fee).type).toBe("ok");

    // the amount plus the fee actually spent has left sBTC for good
    expect(treasuryBalance()).toBe(POOL_SATS - (ALICE_SATS - MAX_FEE) - fee);
    expect(reclaimBtcWithdrawal(id).type).toBe("ok");

    expect(Number(poolTotals()["withdrawing-sats"])).toBe(0);
    // alice has nothing left to claim on the sBTC side
    expect(Number(settledMember(alice)["released-sats"])).toBe(0);
    // the unspent fee is unattributed principal, not anybody's reward
    expect(unattributedPrincipal()).toBe(MAX_FEE - fee);
    expect(sbtcBalance(poolPrincipal())).toBe(0);
    expect(btcWithdrawal(id)).toBeNull();
  });

  it("puts the whole amount back when the signers reject", () => {
    readyToLeave();
    const id = Number(plain(claimPrincipalToBtc(alice, MAX_FEE) as any)["request-id"]);
    expect(reclaimBtcWithdrawal(id)).toBeErr(Cl.uint(310)); // still pending

    expect(settleBtcWithdrawal(id, false).type).toBe("ok");
    expect(reclaimBtcWithdrawal(id, carol).type).toBe("ok"); // permissionless

    expect(Number(settledMember(alice)["released-sats"])).toBe(ALICE_SATS);
    expect(Number(poolTotals()["withdrawing-sats"])).toBe(0);
    expect(unattributedPrincipal()).toBe(0);

    // and she can take it on Stacks after all
    const before = sbtcBalance(alice);
    expect(claimPrincipal(alice).type).toBe("ok");
    expect(sbtcBalance(alice)).toBe(before + ALICE_SATS);
  });

  it("leaves the STX leg to be claimed on Stacks", () => {
    readyToLeave();
    const ustx = requiredUstx(ALICE_SATS);
    claimPrincipalToBtc(alice, MAX_FEE);
    const before = stxBalance(alice);
    // the sBTC leg is gone to the bridge, the STX leg is still hers
    expect(claimPrincipal(alice).type).toBe("ok");
    expect(stxBalance(alice)).toBe(before + ustx);
  });
});

describe("bond-staker: unattributed principal", () => {
  it("can only be swept by the operator, and never touches member funds", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    expect(unattributedPrincipal()).toBe(0);
    expect(sweepUnattributed(deployer)).toBeErr(Cl.uint(114)); // nothing to take

    // someone bridges to the treasury without announcing it
    sweepBtcDeposit("ff".repeat(32), 750_000);
    expect(unattributedPrincipal()).toBe(750_000);
    expect(sweepUnattributed(carol, alice)).toBeErr(Cl.uint(100)); // UNAUTHORIZED

    const before = sbtcBalance(carol);
    expect(sweepUnattributed(carol).type).toBe("ok");
    expect(sbtcBalance(carol)).toBe(before + 750_000);
    // alice's deposit is untouched
    expect(treasuryBalance()).toBe(ALICE_SATS);
    expect(unattributedPrincipal()).toBe(0);
  });
});

describe("bond-staker: the ledger's bridge hooks", () => {
  it("answer to the bridge contract and nobody else", () => {
    bootstrap();
    const calls: Array<[string, any[]]> = [
      ["reserve-bridged-deposit", [Cl.principal(alice), Cl.uint(ALICE_SATS)]],
      ["abandon-bridged-deposit", [Cl.uint(ALICE_SATS)]],
      [
        "credit-bridged-deposit",
        [Cl.principal(alice), Cl.uint(ALICE_SATS), Cl.uint(1)],
      ],
      ["debit-released-for-bridge", [Cl.principal(alice), Cl.uint(1)]],
      [
        "settle-bridge-withdrawal",
        [Cl.principal(alice), Cl.uint(1), Cl.bool(false)],
      ],
    ];
    for (const [fn, args] of calls) {
      for (const who of [alice, deployer]) {
        expect(simnet.callPublicFn(POOL, fn, args, who).result).toBeErr(
          Cl.uint(100), // UNAUTHORIZED
        );
      }
    }
  });

  it("only let the bridge put principal into the sBTC bridge", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    for (const who of [alice, deployer]) {
      expect(
        simnet.callPublicFn(
          TREASURY,
          "request-btc-withdrawal",
          [Cl.uint(1000), btcRecipient(), Cl.uint(10)],
          who,
        ).result,
      ).toBeErr(Cl.uint(200)); // treasury UNAUTHORIZED
    }
    expect(plain(readTreasury("get-bridge"))).toBe(bridgePrincipal());
  });
});

describe("bond-staker: notice on a bound bond", () => {
  it("will not stake a bond the members have had no time to read", () => {
    registerSignerManager();
    initializePool();
    setupBond(); // advances to two cycles before the bond starts
    const bondStart = bondStartHeight(BOND_INDEX);

    // bound late, deep inside the stake window
    advanceToBurnHeight(bondStart - 300);
    expect(bindBond().type).toBe("ok");
    const bond = boundBond();
    expect(Number(bond["notice-ends-at"])).toBe(bondStart - 300 + 576);

    deposit(alice, ALICE_SATS);
    advanceToBurnHeight(bondStart - 288);
    // inside the window, but the notice has not run out
    expect(stake()).toBeErr(Cl.uint(108)); // TOO_EARLY

    // and it never will: the notice outlasts the bond's start, so a bond bound
    // this late simply cannot be staked. The deposit is not stuck -- it stays
    // withdrawable, and the operator can bind the next bond along.
    advanceToBurnHeight(bondStart);
    expect(stake()).toBeErr(Cl.uint(109)); // TOO_LATE
    expect(withdraw(alice).type).toBe("ok");
  });

  it("stakes normally when the bond was bound in good time", () => {
    const { bondStart } = bootstrap();
    const bond = boundBond();
    // bound two cycles out, so the notice is long gone by the window
    expect(Number(bond["notice-ends-at"])).toBeLessThan(bondStart - 288);
    deposit(alice, ALICE_SATS);
    advanceToBurnHeight(bondStart - 288);
    expect(stake().type).toBe("ok");
  });
});

describe("bond-staker: rotating the operator", () => {
  beforeEach(() => {
    bootstrap();
  });

  it("starts with the operator named at initialize", () => {
    expect(isOperator(deployer)).toBe(true);
    expect(isOperator(alice)).toBe(false);
  });

  it("is only for operators, and never for your own entry", () => {
    expect(updateOperator(bob, true, alice)).toBeErr(Cl.uint(100));
    // an operator cannot disable themselves, so the seat cannot be dropped by
    // one key acting alone
    expect(updateOperator(deployer, false, deployer)).toBeErr(Cl.uint(100));
  });

  it("hands the seat over in two moves", () => {
    expect(updateOperator(alice, true).type).toBe("ok");
    expect(isOperator(alice)).toBe(true);
    // both hold it in the meantime, so there is no gap
    expect(isOperator(deployer)).toBe(true);

    // the newcomer retires the old key
    expect(updateOperator(deployer, false, alice).type).toBe("ok");
    expect(isOperator(deployer)).toBe(false);
    expect(bindBond(NEXT_BOND_INDEX)).toBeErr(Cl.uint(100)); // old key is out

    // and the new one can do the job
    setupBond(NEXT_BOND_INDEX);
    expect(bindBond(NEXT_BOND_INDEX, MAX_SATS, alice).type).toBe("ok");
  });

  it("cannot stop members getting their money back", () => {
    // whatever happens to the seat, every path out of the pool is open to
    // anyone: staking, unwinding, syncing and both claims take no operator
    updateOperator(alice, true);
    expect(updateOperator(deployer, false, alice).type).toBe("ok");

    deposit(bob, BOB_SATS);
    const bondStart = Number(boundBond()["start-height"]);
    advanceToBurnHeight(bondStart - 288);
    expect(stake(carol).type).toBe("ok"); // carol is nobody

    const unlockHeight = Number(epoch(0)["unlock-burn-height"]);
    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc(carol).type).toBe("ok");
    expect(claimPrincipal(bob, carol).type).toBe("ok");
  });
});


describe("bond-staker: the genesis launch floor", () => {
  // The floor is only accepted on pox-5 bond 0, and bond 0 began at burn
  // height 0 -- `setup-bond` for it is already too late in simnet, and always
  // will be. So what is testable here is that the restriction holds; the
  // enforcement itself is exercised by the rendezvous harness, which sets the
  // floor directly and mirrors `stake`'s checks.
  it("refuses a floor on any bond but the genesis one", () => {
    registerSignerManager();
    initializePool();
    setupBond();
    expect(bindBond(BOND_INDEX, MAX_SATS, deployer, MAX_SATS / 2)).toBeErr(
      Cl.uint(116), // INVALID_AMOUNT -- a floor here would be a trap on rolls
    );
  });

  it("refuses a floor above the allocation it could never reach", () => {
    registerSignerManager();
    initializePool();
    setupBond();
    // rejected on both counts: above the ceiling, and not the genesis bond
    expect(bindBond(BOND_INDEX, MAX_SATS, deployer, MAX_SATS + 1)).toBeErr(
      Cl.uint(116),
    );
  });

  it("binds with no floor, and starts on whatever has gathered", () => {
    const { bondStart } = bootstrap();
    expect(Number(boundBond()["min-sats"])).toBe(0);
    expect(stakePreview()["meets-floor"]).toBe(true);
    deposit(alice, 1);
    advanceToBurnHeight(bondStart - 288);
    expect(stake().type).toBe("ok");
  });
});
