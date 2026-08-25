// A signer manager that calls the pool back mid-roll.
//
// pox-5 hands control to the configured signer manager inside
// `register-for-bond`, and it does so *before* it takes the staker's sBTC:
// `signer-manager-validate-stake` at pox-5.clar:754, `roll-sbtc` at 784. A
// growing roll has topped this contract up out of the treasury by then, so for
// the length of that callback the pool's own sBTC balance is not all reward.
//
// If the pool measured its unrecognised rewards as balance-minus-liabilities
// there, a manager that called `sync-rewards` would credit member principal as
// reward, return success, and leave the pool owing rewards it does not hold.
// pox-5's reentrancy guard does not help: it protects pox-5's entry points,
// not `bond-staker`'s state.
//
// Reported as fastpool/sbtc-pool-bond-staker#1. What these tests pin is that
// the principal in transit is subtracted from every reading of the balance,
// and that `sync-rewards` refuses outright for those few lines rather than
// answering about a pool that is mid-move.
//
// `callback-signer-manager` is the manager that does it. No real one does;
// the point is that nothing in the trait stops one.
import { Cl } from "@stacks/transactions";
import { describe, expect, it } from "vitest";
import {
  advanceToBurnHeight,
  ALLOWANCE_SATS,
  bindNextBond,
  bondStartHeight,
  boundBond,
  BOND_INDEX,
  CALLBACK_MANAGER,
  deployer,
  deposit,
  epoch,
  initializePool,
  lastSyncResponse,
  lastUnrecognized,
  NEXT_BOND_INDEX,
  num,
  payRewards,
  poolConfig,
  poolPrincipal,
  poolTotals,
  readPool,
  registerSignerManager,
  sbtcBalance,
  setCallbackPropagate,
  setupBond,
  stake,
  syncRewards,
  treasuryBalance,
} from "./helpers/bond-fixture";

const accounts = simnet.getAccounts();
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const carol = accounts.get("wallet_3")!;

const ALICE_SATS = 10_000_000; // 0.1 BTC
const BOB_SATS = 2_000_000; // the 0.02 BTC that makes the roll grow

const IN_TRANSIT = Cl.uint(130); // ERR_PRINCIPAL_IN_TRANSIT
const NOT_STAKED = Cl.uint(107); // ERR_NOT_STAKED

/** Stand the pool up on the callback manager and open its first epoch. */
function stakeFirstBond() {
  registerSignerManager(CALLBACK_MANAGER);
  expect(initializePool(deployer, CALLBACK_MANAGER).type).toBe("ok");
  setupBond(BOND_INDEX, ALLOWANCE_SATS);
  expect(bindNextBond().type).toBe("ok");

  deposit(alice, ALICE_SATS);
  advanceToBurnHeight(Number(boundBond()["start-height"]) - 288);
  expect(stake(deployer, CALLBACK_MANAGER).type).toBe("ok");
}

/**
 * Bind the next bond, which is what reopens deposits: until a bond is bound
 * there is nothing to join, so anyone growing the roll has to deposit between
 * this and `rollInto`.
 */
function bindNext(index = NEXT_BOND_INDEX) {
  setupBond(index, ALLOWANCE_SATS);
  expect(bindNextBond().type).toBe("ok");
}

/** Roll into the bound bond, inside its stake window. */
function rollInto(index = NEXT_BOND_INDEX) {
  advanceToBurnHeight(bondStartHeight(index) - 288);
  return stake(deployer, CALLBACK_MANAGER);
}

describe("bond-staker: a signer manager that calls back mid-roll", () => {
  it("has nothing to sync on the first stake", () => {
    // The pool has no epoch yet, so the callback's `sync-rewards` bounces on
    // that rather than on the guard -- the first stake was never the exposed
    // one. It is here so the sequence below starts from a known answer.
    stakeFirstBond();
    expect(lastSyncResponse()).toBeErr(NOT_STAKED);
    expect(Number(epoch(0)["staked-sats"])).toBe(ALICE_SATS);
  });

  it("shows a growing roll no principal to mistake for reward", () => {
    stakeFirstBond();
    bindNext();
    // bob joins, so the roll grows from 10M to 12M and 2M of member principal
    // passes through the pool on its way to pox-5
    expect(deposit(bob, BOB_SATS).type).toBe("ok");
    expect(treasuryBalance()).toBe(BOB_SATS);

    expect(rollInto().type).toBe("ok");

    // seen from inside the callback, with 2M sitting in the contract
    expect(lastUnrecognized()).toBe(0);
    expect(lastSyncResponse()).toBeErr(IN_TRANSIT);

    // pox-5 has the principal, and the pool's books know of no reward
    expect(Number(epoch(1)["staked-sats"])).toBe(ALICE_SATS + BOB_SATS);
    expect(num(readPool("get-unclaimed-rewards"))).toBe(0);
    expect(sbtcBalance(poolPrincipal())).toBe(0);
    expect(Number(poolTotals()["total-credited"])).toBe(0);
  });

  it("still shows it the rewards that really are there", () => {
    stakeFirstBond();
    // 500k of genuine reward arrives, and 2M of principal is about to pass
    // through on top of it. Only the reward is the pool's to recognise.
    payRewards(carol, 500_000);
    bindNext();
    expect(deposit(bob, BOB_SATS).type).toBe("ok");

    expect(rollInto().type).toBe("ok");
    expect(lastUnrecognized()).toBe(500_000);
    // and it is still refused, because a split taken mid-roll is a split of a
    // pool that is mid-move
    expect(lastSyncResponse()).toBeErr(IN_TRANSIT);

    // the reward survives the roll untouched and syncs normally afterwards
    expect(sbtcBalance(poolPrincipal())).toBe(500_000);
    expect(syncRewards().type).toBe("ok");
    expect(num(readPool("get-unclaimed-rewards"))).toBe(500_000);
  });

  it("lets the callback sync when the roll does not grow", () => {
    stakeFirstBond();
    payRewards(carol, 500_000);
    bindNext();
    // nobody joins, so the roll is the same size and nothing is in transit
    expect(rollInto().type).toBe("ok");

    expect(lastUnrecognized()).toBe(500_000);
    expect(lastSyncResponse().type).toBe("ok");
    // credited inside the roll, to the epoch that earned it
    expect(num(readPool("get-unclaimed-rewards"))).toBe(500_000);
    expect(Number(epoch(0)["credited"])).toBe(500_000);
  });

  it("takes the whole roll down if the manager passes the refusal on", () => {
    stakeFirstBond();
    bindNext();
    expect(deposit(bob, BOB_SATS).type).toBe("ok");
    expect(setCallbackPropagate(true).type).toBe("ok");

    const before = {
      treasury: treasuryBalance(),
      queued: Number(poolTotals()["queued-sats"]),
      bonded: Number(poolTotals()["bonded-sats"]),
      epochs: Number(poolConfig()["epoch-count"]),
    };

    expect(rollInto()).toBeErr(IN_TRANSIT);

    // nothing moved: the treasury still holds bob's deposit, no epoch opened,
    // and the position is the one the first bond took
    expect(treasuryBalance()).toBe(before.treasury);
    expect(Number(poolTotals()["queued-sats"])).toBe(before.queued);
    expect(Number(poolTotals()["bonded-sats"])).toBe(before.bonded);
    expect(Number(poolConfig()["epoch-count"])).toBe(before.epochs);
    // the bond is still bound, so the roll can simply be retried
    expect(boundBond().bound).toBe(true);
  });

  it("leaves nothing in transit behind, either way", () => {
    stakeFirstBond();
    bindNext();
    expect(deposit(bob, BOB_SATS).type).toBe("ok");

    // a roll that failed inside the callback rolls the flag back with it
    expect(setCallbackPropagate(true).type).toBe("ok");
    expect(rollInto()).toBeErr(IN_TRANSIT);
    // NOTHING_TO_CLAIM, not IN_TRANSIT: the flag came back with the rollback,
    // and what is left is an ordinary empty sync
    expect(syncRewards()).toBeErr(Cl.uint(114));

    // and so does one that succeeded
    expect(setCallbackPropagate(false).type).toBe("ok");
    expect(stake(deployer, CALLBACK_MANAGER).type).toBe("ok");
    payRewards(carol, 500_000);
    expect(syncRewards().type).toBe("ok");
  });
});
