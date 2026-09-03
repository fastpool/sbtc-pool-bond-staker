// `iou-bond-btc` and `iou-bond-stx`: non-transferable receipts that mirror a
// member's principal on the pool's books. bondBTC = queued + bonded + released
// sats, bondSTX the same in ustx, and bondBTC-locked = sats sitting in an sBTC
// withdrawal request. Only `bond-staker` moves them.
import { Cl } from "@stacks/transactions";
import { describe, expect, it } from "vitest";
import {
  advanceToBurnHeight,
  ALLOWANCE_SATS,
  announceBtcAddress,
  bindNextBond,
  bondStartHeight,
  bootstrap,
  btcAddress,
  claimPrincipal,
  claimPrincipalToBtc,
  completeBtcDeposit,
  deployer,
  deposit,
  depositStx,
  NEXT_BOND_INDEX,
  plain,
  poolTotals,
  readPool,
  reclaimBtcWithdrawal,
  requestExit,
  requiredUstx,
  settledMember,
  settleBtcWithdrawal,
  setupBond,
  stake,
  STX_VALUE_RATIO,
  sweepBtcDeposit,
  unstakeEarly,
  unstakeSbtc,
  withdraw,
} from "./helpers/bond-fixture";
import { fundedDeposit } from "./helpers/btc-tx";

const accounts = simnet.getAccounts();
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const carol = accounts.get("wallet_3")!;

const ALICE_SATS = 10_000_000;
const BOB_SATS = 30_000_000;

const BTC = "iou-bond-btc";
const STX = "iou-bond-stx";

const read = (contract: string, fn: string, args: any[] = []) =>
  Number(plain(simnet.callReadOnlyFn(contract, fn, args, deployer).result));

/** The three receipt balances a wallet would show for `who`. */
const receipts = (who: string) => ({
  btc: read(BTC, "get-balance", [Cl.principal(who)]),
  locked: read(BTC, "get-locked-balance", [Cl.principal(who)]),
  stx: read(STX, "get-balance", [Cl.principal(who)]),
});

const supplies = () => ({
  btc: read(BTC, "get-total-supply"),
  locked: read(BTC, "get-locked-supply"),
  stx: read(STX, "get-total-supply"),
});

/** The pool's own check: receipts equal principal on the books. */
const receiptsMatch = () =>
  expect(readPool("invariant-receipts-match-principal")).toBeBool(true);

function stakeFirstBond() {
  const { bondStart, unlockHeight } = bootstrap();
  deposit(alice, ALICE_SATS);
  deposit(bob, BOB_SATS);
  advanceToBurnHeight(bondStart - 288);
  expect(stake().type).toBe("ok");
  return { bondStart, unlockHeight };
}

describe("receipts: joining and leaving on Stacks", () => {
  it("mints a receipt for each leg of a deposit", () => {
    bootstrap();
    expect(deposit(alice, ALICE_SATS).type).toBe("ok");

    expect(receipts(alice)).toEqual({
      btc: ALICE_SATS,
      locked: 0,
      stx: requiredUstx(ALICE_SATS),
    });
    expect(supplies()).toEqual({
      btc: ALICE_SATS,
      locked: 0,
      stx: requiredUstx(ALICE_SATS),
    });
    receiptsMatch();
  });

  it("mints only bondSTX for a bare STX deposit", () => {
    bootstrap();
    expect(depositStx(alice, 5_000_000).type).toBe("ok");
    expect(receipts(alice)).toEqual({ btc: 0, locked: 0, stx: 5_000_000 });
    receiptsMatch();
  });

  it("burns both legs when a queued deposit is withdrawn", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    expect(withdraw(alice).type).toBe("ok");
    expect(receipts(alice)).toEqual({ btc: 0, locked: 0, stx: 0 });
    expect(supplies()).toEqual({ btc: 0, locked: 0, stx: 0 });
    receiptsMatch();
  });

  it("keeps the receipts through stake: bonded principal is still a claim", () => {
    const { unlockHeight } = stakeFirstBond();
    expect(receipts(alice).btc).toBe(ALICE_SATS);
    expect(receipts(bob).btc).toBe(BOB_SATS);
    expect(Number(poolTotals()["bonded-sats"])).toBe(ALICE_SATS + BOB_SATS);
    receiptsMatch();

    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc().type).toBe("ok");
    // released, not yet paid: still a claim
    expect(receipts(alice).btc).toBe(ALICE_SATS);
    receiptsMatch();

    // anyone may pay alice out; the burn is from alice, not the caller
    expect(claimPrincipal(alice, carol).type).toBe("ok");
    expect(receipts(alice)).toEqual({ btc: 0, locked: 0, stx: 0 });
    expect(receipts(carol)).toEqual({ btc: 0, locked: 0, stx: 0 });
    expect(supplies().btc).toBe(BOB_SATS);
    receiptsMatch();
  });

  it("burns the sBTC receipt on an early exit only once it is paid", () => {
    stakeFirstBond();
    expect(unstakeEarly(alice, ALICE_SATS).type).toBe("ok");
    // sats moved to released, STX still locked in pox-5: nothing paid yet
    expect(receipts(alice)).toEqual({
      btc: ALICE_SATS,
      locked: 0,
      stx: requiredUstx(ALICE_SATS),
    });
    receiptsMatch();

    expect(claimPrincipal(alice).type).toBe("ok");
    expect(receipts(alice)).toEqual({
      btc: 0,
      locked: 0,
      stx: requiredUstx(ALICE_SATS),
    });
    receiptsMatch();
  });

  it("burns the queued part that request-exit refunds", () => {
    stakeFirstBond();
    setupBond(NEXT_BOND_INDEX);
    expect(bindNextBond().type).toBe("ok");
    expect(deposit(alice, ALICE_SATS).type).toBe("ok");
    expect(receipts(alice).btc).toBe(2 * ALICE_SATS);

    expect(requestExit(alice).type).toBe("ok");
    expect(receipts(alice).btc).toBe(ALICE_SATS);
    expect(receipts(alice).stx).toBe(requiredUstx(ALICE_SATS));
    receiptsMatch();
  });

  it("is untouched by a roll haircut, which only moves principal between books", () => {
    stakeFirstBond();
    const ustx = requiredUstx(ALICE_SATS);
    // twice the STX per sat: half the sats fit the next bond
    setupBond(NEXT_BOND_INDEX, ALLOWANCE_SATS, STX_VALUE_RATIO * 2);
    expect(bindNextBond().type).toBe("ok");
    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");

    expect(receipts(alice).btc).toBe(ALICE_SATS);
    expect(Number(settledMember(alice)["released-sats"])).toBe(ALICE_SATS / 2);
    receiptsMatch();

    expect(claimPrincipal(alice).type).toBe("ok");
    expect(receipts(alice).btc).toBe(ALICE_SATS / 2);
    // priced at deposit; all of it rides on into the dearer bond
    expect(receipts(alice).stx).toBe(ustx);
    receiptsMatch();
  });
});

describe("receipts: joining and leaving over the sBTC bridge", () => {
  const MAX_FEE = 10_000;
  const ALICE_HASH = "a1".repeat(20);

  it("mints to the member an L1 deposit is credited to, whoever completes it", () => {
    bootstrap();
    expect(
      announceBtcAddress(alice, ALICE_SATS, btcAddress(ALICE_HASH)).type,
    ).toBe("ok");
    // the STX leg is paid at the announcement, the sats are not here yet
    expect(receipts(alice)).toEqual({ btc: 0, locked: 0, stx: 0 });

    const funded = fundedDeposit([{ version: "04", hashbytes: ALICE_HASH }]);
    simnet.mineEmptyBurnBlocks(2);
    expect(sweepBtcDeposit(funded.txid, ALICE_SATS).type).toBe("ok");
    expect(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents, 0, carol).type,
    ).toBe("ok");

    expect(receipts(alice)).toEqual({
      btc: ALICE_SATS,
      locked: 0,
      stx: requiredUstx(ALICE_SATS),
    });
    expect(receipts(carol)).toEqual({ btc: 0, locked: 0, stx: 0 });
    receiptsMatch();
  });

  function readyToLeave() {
    const { unlockHeight } = stakeFirstBond();
    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc().type).toBe("ok");
  }

  it("locks the sats while the signers rule, and burns them when they pay", () => {
    readyToLeave();
    const result = plain(claimPrincipalToBtc(alice, MAX_FEE) as any);
    const requestId = Number(result["request-id"]);

    expect(receipts(alice)).toEqual({
      btc: 0,
      locked: ALICE_SATS,
      stx: requiredUstx(ALICE_SATS),
    });
    expect(supplies().locked).toBe(ALICE_SATS);
    receiptsMatch();

    expect(settleBtcWithdrawal(requestId, true).type).toBe("ok");
    expect(reclaimBtcWithdrawal(requestId, carol).type).toBe("ok");
    expect(receipts(alice)).toEqual({
      btc: 0,
      locked: 0,
      stx: requiredUstx(ALICE_SATS),
    });
    expect(supplies().locked).toBe(0);
    receiptsMatch();
  });

  it("unlocks the sats to the member when the signers refuse, whoever settles", () => {
    readyToLeave();
    const result = plain(claimPrincipalToBtc(alice, MAX_FEE) as any);
    const requestId = Number(result["request-id"]);

    expect(settleBtcWithdrawal(requestId, false).type).toBe("ok");
    expect(reclaimBtcWithdrawal(requestId, carol).type).toBe("ok");
    expect(receipts(alice)).toEqual({
      btc: ALICE_SATS,
      locked: 0,
      stx: requiredUstx(ALICE_SATS),
    });
    expect(receipts(carol)).toEqual({ btc: 0, locked: 0, stx: 0 });
    expect(Number(settledMember(alice)["released-sats"])).toBe(ALICE_SATS);
    receiptsMatch();
  });
});

describe("receipts: what nobody but the pool can do", () => {
  it("cannot be transferred", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    for (const token of [BTC, STX]) {
      expect(
        simnet.callPublicFn(
          token,
          "transfer",
          [Cl.uint(1), Cl.principal(alice), Cl.principal(bob), Cl.none()],
          alice,
        ).result,
      ).toBeErr(Cl.uint(501));
    }
    expect(receipts(alice).btc).toBe(ALICE_SATS);
  });

  it("cannot be minted, burned, locked or unlocked from outside", () => {
    bootstrap();
    deposit(alice, ALICE_SATS);
    const args = [Cl.uint(1), Cl.principal(alice)];
    for (const [token, fn] of [
      [BTC, "mint"],
      [BTC, "burn"],
      [BTC, "lock"],
      [BTC, "unlock"],
      [BTC, "burn-locked"],
      [STX, "mint"],
      [STX, "burn"],
    ] as const) {
      expect(simnet.callPublicFn(token, fn, args, alice).result).toBeErr(
        Cl.uint(500),
      );
      expect(simnet.callPublicFn(token, fn, args, deployer).result).toBeErr(
        Cl.uint(500),
      );
    }
    receiptsMatch();
  });

  it("reads as a SIP-010 token", () => {
    expect(plain(simnet.callReadOnlyFn(BTC, "get-symbol", [], deployer).result)).toBe("bondBTC");
    expect(read(BTC, "get-decimals")).toBe(8);
    expect(plain(simnet.callReadOnlyFn(STX, "get-symbol", [], deployer).result)).toBe("bondSTX");
    expect(read(STX, "get-decimals")).toBe(6);
  });
});
