// `bond-bridge`: joining and leaving with L1 bitcoin. The member commits to
// the address the bitcoin will come from, reveals it, sends, and the deposit is
// credited to whoever revealed the address that funded it.
//
// The interesting half is `complete-btc-deposit`, which is handed the deposit
// transaction and the parent behind each of its inputs and has to decide, from
// the bytes alone, which address funded it. `helpers/btc-tx` builds those.
import { Cl, serializeCV } from "@stacks/transactions";
import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  addressDigest,
  advanceToBurnHeight,
  ANNOUNCE_TTL,
  announceBtcAddress,
  bootstrap,
  bridgePrincipal,
  btcAddress,
  btcAnnouncement,
  btcCommitment,
  btcRecipient,
  btcWithdrawal,
  cancelBtcAddress,
  cancelBtcCommitment,
  claimPrincipalToBtc,
  commitBtcAddress,
  COMMIT_TTL,
  completeBtcDeposit,
  creditedDeposit,
  deployer,
  deposit,
  MAX_SATS,
  member,
  num,
  plain,
  poolPrincipal,
  poolTotals,
  readBridge,
  readPool,
  reclaimBtcWithdrawal,
  requiredUstx,
  revealBtcAddress,
  REVEAL_DELAY,
  SALT,
  sbtcBalance,
  settledMember,
  settleBtcWithdrawal,
  stake,
  stxBalance,
  sweepBtcDeposit,
  treasuryBalance,
  treasuryPrincipal,
  unattributedPrincipal,
  unstakeSbtc,
} from "./helpers/bond-fixture";
import { buildTx, fundedDeposit, scriptFor, txidOf } from "./helpers/btc-tx";
import { parseTx, txidOf as txidOfAsync } from "../lib/btc-tx.js";

const accounts = simnet.getAccounts();
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const carol = accounts.get("wallet_3")!;

const ALICE_SATS = 10_000_000; // 0.1 BTC
const BOB_SATS = 30_000_000; // 0.3 BTC

/** Alice's bitcoin address, and Bob's; p2wpkh unless a test says otherwise. */
const ALICE_HASH = "a1".repeat(20);
const BOB_HASH = "b0".repeat(20);
const aliceAddress = btcAddress(ALICE_HASH);
const bobAddress = btcAddress(BOB_HASH);

/**
 * Sweep a deposit, two burn blocks on from wherever the test is.
 * `sweepBtcDeposit` dates the sweep one burn block back, and the contract wants
 * an announcement that outright predates its sweep -- so without the gap the
 * two land on the same height and the deposit is refused.
 */
const sweep = (
  txid: string,
  sats: number,
  recipient?: string,
  voutIndex?: number,
) => {
  simnet.mineEmptyBurnBlocks(2);
  return sweepBtcDeposit(txid, sats, recipient, voutIndex);
};

/** A deposit funded from one address, with a parent for its single input. */
const depositFrom = (hashbytes: string, version = "04") =>
  fundedDeposit([{ version, hashbytes }]);

/**
 * Announce, send, sweep, complete. The sweep is dated to the burn height
 * before the call, so the announcement has to be at least one block older --
 * which it is, every simnet call being its own block.
 */
function joinFromBitcoin(
  who: string,
  sats: number,
  hashbytes = ALICE_HASH,
  version = "04",
) {
  expect(
    announceBtcAddress(who, sats, btcAddress(hashbytes, version)).type,
  ).toBe("ok");
  const funded = depositFrom(hashbytes, version);
  expect(sweep(funded.txid, sats).type).toBe("ok");
  return funded;
}

describe("bond-bridge: announcing an address", () => {
  it("names the treasury as the address to bridge to", () => {
    bootstrap();
    const result = plain(announceBtcAddress(alice, ALICE_SATS, aliceAddress) as any);
    expect(result["deposit-to"]).toBe(treasuryPrincipal());
    expect(plain(readBridge("get-deposit-address"))).toBe(
      treasuryPrincipal(),
    );
  });

  it("takes the STX leg up front and holds the allocation", () => {
    bootstrap();
    const ustx = requiredUstx(ALICE_SATS);
    const stxBefore = stxBalance(alice);

    expect(announceBtcAddress(alice, ALICE_SATS, aliceAddress).type).toBe("ok");

    // the STX is paid now; the sats are still on bitcoin
    expect(stxBalance(alice)).toBe(stxBefore - ustx);
    expect(stxBalance(bridgePrincipal())).toBe(ustx);
    expect(treasuryBalance()).toBe(0);
    expect(Number(poolTotals()["announced-sats"])).toBe(ALICE_SATS);
    expect(num(readPool("get-committing-sats"))).toBe(ALICE_SATS);

    const claim = btcAnnouncement(aliceAddress);
    expect(claim.member).toBe(alice);
    expect(Number(claim.sats)).toBe(ALICE_SATS);
    expect(Number(claim.ustx)).toBe(ustx);
  });

  it("keys the announcement by the script the address locks to", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);

    // the three p2sh-shaped versions are one address on the chain, so they are
    // one announcement here -- p2sh, p2sh-p2wpkh and p2sh-p2wsh over the same
    // hash cannot be held by three different members
    const p2sh = btcAddress(BOB_HASH, "01");
    expect(announceBtcAddress(bob, BOB_SATS, p2sh).type).toBe("ok");
    expect(
      announceBtcAddress(carol, BOB_SATS, btcAddress(BOB_HASH, "02")),
    ).toBeErr(Cl.uint(303)); // ADDRESS_ANNOUNCED
    expect(
      plain(
        readBridge("get-address-script", [btcAddress(BOB_HASH, "03")]),
      ) as any,
    ).toBe(`0x${scriptFor("01", BOB_HASH)}`);
  });

  it("takes every address shape the sBTC bridge takes, and nothing else", () => {
    bootstrap();
    const shapes = [
      ["00", ALICE_HASH],
      ["01", ALICE_HASH],
      ["04", ALICE_HASH],
      ["05", "a5".repeat(32)],
      ["06", "a6".repeat(32)],
    ];
    for (const [version, hash] of shapes) {
      const address = btcAddress(hash, version);
      expect(plain(readBridge("get-address-script", [address]))).toBe(
        `0x${scriptFor(version, hash)}`,
      );
    }

    // a version nobody uses, and a hash of the wrong length for its version.
    // There is nothing to commit to either, so the reveal is where it stops.
    for (const address of [
      btcAddress(ALICE_HASH, "07"),
      btcAddress("a5".repeat(32), "04"),
      btcAddress(ALICE_HASH, "05"),
    ]) {
      expect(plain(readBridge("get-address-script", [address]))).toBeNull();
      expect(plain(readBridge("get-address-digest", [address, Cl.bufferFromHex(SALT)]))).toBeNull();
      expect(revealBtcAddress(alice, address)).toBeErr(Cl.uint(315));
    }
  });

  it("holds one live announcement per address", () => {
    bootstrap();
    expect(announceBtcAddress(alice, ALICE_SATS, aliceAddress).type).toBe("ok");
    // and finds out before any bitcoin has moved
    expect(announceBtcAddress(bob, BOB_SATS, aliceAddress)).toBeErr(Cl.uint(303));
    // ...any other address of theirs will do
    expect(announceBtcAddress(bob, BOB_SATS, bobAddress).type).toBe("ok");
  });

  it("hands the STX back when an announcement is called off", () => {
    bootstrap();
    const stxBefore = stxBalance(alice);
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);

    // nobody else can cancel it while it is live
    expect(cancelBtcAddress(aliceAddress, bob)).toBeErr(Cl.uint(308)); // LIVE
    expect(cancelBtcAddress(aliceAddress, alice).type).toBe("ok");

    expect(stxBalance(alice)).toBe(stxBefore);
    expect(stxBalance(bridgePrincipal())).toBe(0);
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
    expect(btcAnnouncement(aliceAddress)).toBeNull();
    // and the address is free again
    expect(announceBtcAddress(bob, BOB_SATS, aliceAddress).type).toBe("ok");
  });

  it("lets a stranger clear an announcement that went nowhere", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    simnet.mineEmptyBurnBlocks(ANNOUNCE_TTL - 1);
    expect(cancelBtcAddress(aliceAddress, carol)).toBeErr(Cl.uint(308));

    simnet.mineEmptyBurnBlocks(1);
    expect(cancelBtcAddress(aliceAddress, carol).type).toBe("ok");
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
  });
});

describe("bond-bridge: committing and revealing an address", () => {
  const digest = (address = aliceAddress) => addressDigest(address, SALT);

  it("will not reveal in the same block as the commit", () => {
    bootstrap();
    expect(commitBtcAddress(alice, digest(), ALICE_SATS).type).toBe("ok");
    expect(revealBtcAddress(alice, aliceAddress)).toBeErr(Cl.uint(314)); // SOON
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcAddress(alice, aliceAddress).type).toBe("ok");
  });

  it("will not reveal an address nobody committed to", () => {
    bootstrap();
    expect(revealBtcAddress(alice, aliceAddress)).toBeErr(Cl.uint(312));
    // nor one committed to under a different salt
    expect(commitBtcAddress(alice, digest(), ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcAddress(alice, aliceAddress, "cc".repeat(32))).toBeErr(
      Cl.uint(312),
    );
  });

  it("says nothing about the address until the reveal", () => {
    bootstrap();
    // the same address under two salts is two digests, so a watcher holding a
    // list of addresses cannot recognise one by its commitment
    expect(digest()).not.toBe(addressDigest(aliceAddress, "cc".repeat(32)));
    // and the p2sh-shaped versions commit as one, the way they announce as one
    expect(addressDigest(btcAddress(BOB_HASH, "01"))).toBe(
      addressDigest(btcAddress(BOB_HASH, "03")),
    );

    commitBtcAddress(alice, digest(), ALICE_SATS);
    expect(Number(btcCommitment(alice, digest()).sats)).toBe(ALICE_SATS);
    expect(btcAnnouncement(aliceAddress)).toBeNull();
  });

  it("gives the address to the first reveal, so a watcher is always late", () => {
    bootstrap();
    // Alice commits and reveals. Only now is the address spoken for anywhere.
    expect(commitBtcAddress(alice, digest(), ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcAddress(alice, aliceAddress).type).toBe("ok");

    // Carol reads it off the reveal and races the rest of the flow. Even
    // knowing the salt, the address is already taken.
    expect(commitBtcAddress(carol, digest(), ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcAddress(carol, aliceAddress)).toBeErr(Cl.uint(303));

    // The sats go where the first reveal said they would.
    const funded = depositFrom(ALICE_HASH);
    expect(sweep(funded.txid, ALICE_SATS).type).toBe("ok");
    expect(completeBtcDeposit(funded.txid, funded.tx, funded.parents).type).toBe(
      "ok",
    );
    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
    expect(member(carol)).toBeNull();
  });

  it("lets a copied digest block nobody: commitments are keyed by member", () => {
    bootstrap();
    // Carol lifts alice's digest out of the mempool and commits it first.
    expect(commitBtcAddress(carol, digest(), ALICE_SATS).type).toBe("ok");
    // Alice's own commit is unaffected.
    expect(commitBtcAddress(alice, digest(), ALICE_SATS).type).toBe("ok");
    // ...and she cannot commit the same one twice.
    expect(commitBtcAddress(alice, digest(), ALICE_SATS)).toBeErr(Cl.uint(313));

    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcAddress(alice, aliceAddress).type).toBe("ok");
  });

  it("hands back the STX and the room when a commitment is abandoned", () => {
    bootstrap();
    const ustx = requiredUstx(ALICE_SATS);
    const stxBefore = stxBalance(alice);
    expect(commitBtcAddress(alice, digest(), ALICE_SATS).type).toBe("ok");
    expect(stxBalance(alice)).toBe(stxBefore - ustx);
    expect(num(readPool("get-committing-sats"))).toBe(ALICE_SATS);

    // A stranger cannot cancel it while it is live...
    expect(cancelBtcCommitment(alice, digest(), carol)).toBeErr(Cl.uint(308));
    // ...but the member can, whenever.
    expect(cancelBtcCommitment(alice, digest()).type).toBe("ok");
    expect(stxBalance(alice)).toBe(stxBefore);
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
  });

  it("lets anyone clear a commitment that has gone stale", () => {
    bootstrap();
    const stxBefore = stxBalance(alice);
    expect(commitBtcAddress(alice, digest(), ALICE_SATS).type).toBe("ok");

    // not a moment before COMMIT_TTL...
    simnet.mineEmptyBurnBlocks(COMMIT_TTL - 1);
    expect(cancelBtcCommitment(alice, digest(), carol)).toBeErr(Cl.uint(308));

    simnet.mineEmptyBurnBlocks(1);
    expect(cancelBtcCommitment(alice, digest(), carol).type).toBe("ok");
    expect(num(readPool("get-committing-sats"))).toBe(0);
    // the STX goes back to the member, not to whoever cleared it
    expect(stxBalance(alice)).toBe(stxBefore);
  });

  it("clears a commitment far sooner than a revealed address", () => {
    bootstrap();
    // A commitment holds nothing in flight: nothing has been sent, so it does
    // not get the week that a revealed announcement does.
    expect(COMMIT_TTL).toBeLessThan(ANNOUNCE_TTL);
    expect(announceBtcAddress(alice, ALICE_SATS, aliceAddress).type).toBe("ok");

    simnet.mineEmptyBurnBlocks(COMMIT_TTL);
    expect(cancelBtcAddress(aliceAddress, carol)).toBeErr(Cl.uint(308)); // LIVE
    expect(cancelBtcAddress(aliceAddress, alice).type).toBe("ok"); // its owner
  });

  it("counts a commitment against the pool's allocation", () => {
    bootstrap();
    expect(commitBtcAddress(alice, digest(), MAX_SATS).type).toBe("ok");
    expect(deposit(bob, 1)).toBeErr(Cl.uint(105)); // ALLOCATION_EXCEEDED
    cancelBtcCommitment(alice, digest());
    expect(deposit(bob, 1).type).toBe("ok");
  });
});

describe("bond-bridge: completing a deposit", () => {
  it("credits the member the inputs came from", () => {
    bootstrap();
    const ustx = requiredUstx(ALICE_SATS);
    const funded = joinFromBitcoin(alice, ALICE_SATS);

    expect(treasuryBalance()).toBe(ALICE_SATS);
    // permissionless: a keeper can finish the job
    const result = plain(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents, 0, carol) as any,
    );
    expect(result.member).toBe(alice);
    expect(Number(result.sats)).toBe(ALICE_SATS);
    expect(result.script).toBe(`0x${scriptFor("04", ALICE_HASH)}`);

    expect(Number(poolTotals()["announced-sats"])).toBe(0);
    expect(Number(poolTotals()["queued-sats"])).toBe(ALICE_SATS);
    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
    expect(Number(member(alice)["queued-ustx"])).toBe(ustx);
    // the STX leg moved from the bridge to the ledger with the sats
    expect(stxBalance(bridgePrincipal())).toBe(0);
    expect(stxBalance(poolPrincipal())).toBe(ustx);
    // the announcement is spent, the deposit is on the record
    expect(btcAnnouncement(aliceAddress)).toBeNull();
    expect(creditedDeposit(funded.txid).member).toBe(alice);
    // alice never touched sBTC
    expect(sbtcBalance(alice)).toBe(1_000_000_000);
  });

  it("carries an L1 joiner into the bond like any other member", () => {
    const { bondStart } = bootstrap();
    const funded = joinFromBitcoin(alice, ALICE_SATS);
    expect(completeBtcDeposit(funded.txid, funded.tx, funded.parents).type).toBe(
      "ok",
    );

    advanceToBurnHeight(bondStart - 288);
    expect(stake().type).toBe("ok");
    expect(Number(settledMember(alice).shares)).toBe(ALICE_SATS);
  });

  it("takes a deposit whose inputs all come from the one address", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    // three inputs, three parents, one address -- and the spent output sits at
    // a different place in each parent
    const funded = fundedDeposit([
      { version: "04", hashbytes: ALICE_HASH, vout: 0, outputs: 3 },
      { version: "04", hashbytes: ALICE_HASH, vout: 2, outputs: 3 },
      { version: "04", hashbytes: ALICE_HASH, vout: 5, outputs: 6, inputs: 4 },
    ]);
    sweep(funded.txid, ALICE_SATS);

    expect(completeBtcDeposit(funded.txid, funded.tx, funded.parents).type).toBe(
      "ok",
    );
    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
  });

  it("reads every address shape out of a parent's outputs", () => {
    bootstrap();
    for (const [version, hash] of [
      ["00", "c0".repeat(20)],
      ["01", "c1".repeat(20)],
      ["05", "c5".repeat(32)],
      ["06", "c6".repeat(32)],
    ]) {
      const address = btcAddress(hash, version);
      expect(announceBtcAddress(alice, 1_000_000, address).type).toBe("ok");
      const funded = fundedDeposit([{ version, hashbytes: hash, vout: 1 }]);
      sweep(funded.txid, 1_000_000);
      expect(
        completeBtcDeposit(funded.txid, funded.tx, funded.parents).type,
      ).toBe("ok");
    }
    expect(Number(member(alice)["queued-sats"])).toBe(4_000_000);
  });

  it("refuses a transaction that is not the one the signers swept", () => {
    bootstrap();
    const funded = joinFromBitcoin(alice, ALICE_SATS);
    // the same address, a different transaction
    const other = fundedDeposit([{ version: "04", hashbytes: ALICE_HASH }], {
      depositValue: 90_000,
    });

    // the right txid, someone else's bytes
    expect(
      completeBtcDeposit(funded.txid, other.tx, other.parents),
    ).toBeErr(Cl.uint(316)); // TXID_MISMATCH
    // a txid the registry has never seen
    expect(
      completeBtcDeposit(other.txid, other.tx, other.parents),
    ).toBeErr(Cl.uint(304)); // NOT_SWEPT
  });

  it("refuses a parent that is not the one the input names", () => {
    bootstrap();
    const funded = joinFromBitcoin(alice, ALICE_SATS);
    // a parent that pays the same address but is a different transaction
    const impostor = buildTx(
      [{ txid: "fe".repeat(32), vout: 0 }],
      [{ value: 200_000, script: scriptFor("04", ALICE_HASH) }],
    );
    expect(
      completeBtcDeposit(funded.txid, funded.tx, [impostor]),
    ).toBeErr(Cl.uint(319)); // PARENT_MISMATCH
    // and no parent at all is no proof either
    expect(completeBtcDeposit(funded.txid, funded.tx, [])).toBeErr(
      Cl.uint(318), // INPUT_COUNT
    );
  });

  it("refuses a deposit funded from an address nobody announced", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    const funded = depositFrom(BOB_HASH);
    sweep(funded.txid, ALICE_SATS);

    expect(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents),
    ).toBeErr(Cl.uint(302)); // UNKNOWN_ANNOUNCEMENT
  });

  it("refuses a deposit with an input from anywhere else", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    // alice funds most of it, but one input is not hers: neither of them can
    // claim it, which is the point -- an onlooker cannot announce the other
    // address and take the deposit
    const funded = fundedDeposit([
      { version: "04", hashbytes: ALICE_HASH },
      { version: "04", hashbytes: BOB_HASH },
    ]);
    sweep(funded.txid, ALICE_SATS);

    expect(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents),
    ).toBeErr(Cl.uint(320)); // FOREIGN_INPUT
    expect(announceBtcAddress(bob, ALICE_SATS, bobAddress).type).toBe("ok");
    expect(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents),
    ).toBeErr(Cl.uint(320));
  });

  it("cannot be pointed at the wrong output of the right parent", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    // the parent pays alice at output 1 and someone else at output 0; the
    // deposit spends output 0, so it is not hers however it is presented
    const parent = buildTx(
      [{ txid: "fd".repeat(32), vout: 0 }],
      [
        { value: 200_000, script: scriptFor("04", BOB_HASH) },
        { value: 200_000, script: scriptFor("04", ALICE_HASH) },
      ],
    );
    const tx = buildTx(
      [{ txid: txidOf(parent), vout: 0 }],
      [{ value: 100_000, script: scriptFor("05", "ee".repeat(32)) }],
    );
    sweep(txidOf(tx), ALICE_SATS);

    expect(completeBtcDeposit(txidOf(tx), tx, [parent])).toBeErr(Cl.uint(302));
  });

  it("will not credit an announcement younger than the sweep", () => {
    bootstrap();
    const funded = depositFrom(ALICE_HASH);
    // the deposit is swept first, and only then is the address announced --
    // which is how an onlooker would try to take someone else's bitcoin
    sweep(funded.txid, ALICE_SATS);
    expect(announceBtcAddress(carol, ALICE_SATS, aliceAddress).type).toBe("ok");

    expect(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents),
    ).toBeErr(Cl.uint(321)); // ANNOUNCED_TOO_LATE
  });

  it("credits one bitcoin deposit once", () => {
    bootstrap();
    const funded = joinFromBitcoin(alice, ALICE_SATS);
    expect(completeBtcDeposit(funded.txid, funded.tx, funded.parents).type).toBe(
      "ok",
    );

    // a second announcement of the same address cannot re-claim it, even
    // though the sweep is now older than it
    expect(announceBtcAddress(alice, ALICE_SATS, aliceAddress).type).toBe("ok");
    expect(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents),
    ).toBeErr(Cl.uint(321));
  });

  it("credits what arrived when the signers' fee eats into the deposit", () => {
    bootstrap();
    const SWEEP_FEE = 20_000;
    const arrived = ALICE_SATS - SWEEP_FEE;
    const ustx = requiredUstx(ALICE_SATS);

    expect(announceBtcAddress(alice, ALICE_SATS, aliceAddress).type).toBe("ok");
    const funded = depositFrom(ALICE_HASH);
    expect(sweep(funded.txid, arrived).type).toBe("ok");
    expect(completeBtcDeposit(funded.txid, funded.tx, funded.parents).type).toBe(
      "ok",
    );

    expect(Number(member(alice)["queued-sats"])).toBe(arrived);
    // the STX leg follows the announcement, and is the member's to reclaim
    expect(Number(member(alice)["queued-ustx"])).toBe(ustx);
    expect(stxBalance(bridgePrincipal())).toBe(0);
    // the room the shortfall was holding is released, not left reserved
    expect(Number(poolTotals()["announced-sats"])).toBe(0);
    expect(num(readPool("get-committing-sats"))).toBe(arrived);
  });

  it("credits only what was announced when more arrives than expected", () => {
    bootstrap();
    const extra = 5_000;
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    const funded = depositFrom(ALICE_HASH);
    sweep(funded.txid, ALICE_SATS + extra);
    expect(completeBtcDeposit(funded.txid, funded.tx, funded.parents).type).toBe(
      "ok",
    );

    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
    // the overpayment is in the treasury attributed to nobody
    expect(Number(unattributedPrincipal())).toBe(extra);
  });

  it("will not take a deposit the signers sent somewhere else", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    const funded = depositFrom(ALICE_HASH);
    // swept to the pool instead of the treasury
    sweep(funded.txid, ALICE_SATS, poolPrincipal());

    expect(
      completeBtcDeposit(funded.txid, funded.tx, funded.parents),
    ).toBeErr(Cl.uint(305)); // MISDIRECTED
  });

  it("refuses what it cannot read, and more inputs than it will take", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    const funded = depositFrom(ALICE_HASH);
    sweep(funded.txid, ALICE_SATS);

    // a marker with no witness stacks behind it is not a transaction at all
    const broken = `${funded.tx.slice(0, 8)}0001${funded.tx.slice(8)}`;
    expect(completeBtcDeposit(funded.txid, broken, funded.parents)).toBeErr(
      Cl.uint(317), // MALFORMED_TX
    );
    // nor is a parent that does not deserialize
    expect(completeBtcDeposit(funded.txid, funded.tx, ["00"])).toBeErr(
      Cl.uint(317),
    );

    // nine inputs is one more than the contract will take a parent for
    const nine = fundedDeposit(
      Array.from({ length: 9 }, () => ({
        version: "04",
        hashbytes: ALICE_HASH,
      })),
    );
    sweep(nine.txid, ALICE_SATS, treasuryPrincipal(), 1);
    expect(
      completeBtcDeposit(nine.txid, nine.tx, nine.parents.slice(0, 8), 1),
    ).toBeErr(Cl.uint(317));
  });

  it("reads a parent of any shape: no scan bound to fall foul of", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    // 200 inputs to walk past and the spent output 300 down the list -- an
    // exchange payout batch, which the hand-rolled scan this replaced would
    // have refused
    const funded = fundedDeposit([
      { version: "04", hashbytes: ALICE_HASH, vout: 300, outputs: 320, inputs: 200 },
    ]);
    sweep(funded.txid, ALICE_SATS);

    expect(completeBtcDeposit(funded.txid, funded.tx, funded.parents).type).toBe(
      "ok",
    );
    expect(Number(member(alice)["queued-sats"])).toBe(ALICE_SATS);
  });

  it("refuses an input spending an output the parent does not have", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    const parent = buildTx(
      [{ txid: "fc".repeat(32), vout: 0 }],
      [{ value: 200_000, script: scriptFor("04", ALICE_HASH) }],
    );
    // the deposit names output 7 of a parent that has one
    const tx = buildTx(
      [{ txid: txidOf(parent), vout: 7 }],
      [{ value: 100_000, script: scriptFor("05", "ee".repeat(32)) }],
    );
    sweep(txidOf(tx), ALICE_SATS);

    expect(completeBtcDeposit(txidOf(tx), tx, [parent])).toBeErr(Cl.uint(317));
  });

  it("refuses a deposit funded from a script no address could name", () => {
    bootstrap();
    announceBtcAddress(alice, ALICE_SATS, aliceAddress);
    // a bare multisig output: a real scriptPubKey, but not one of the six
    // shapes an announcement can be keyed by
    const parent = buildTx(
      [{ txid: "fb".repeat(32), vout: 0 }],
      [{ value: 200_000, script: `51${"21" + "02".repeat(0x21)}51ae` }],
    );
    const tx = buildTx(
      [{ txid: txidOf(parent), vout: 0 }],
      [{ value: 100_000, script: scriptFor("05", "ee".repeat(32)) }],
    );
    sweep(txidOf(tx), ALICE_SATS);

    expect(completeBtcDeposit(txidOf(tx), tx, [parent])).toBeErr(Cl.uint(315));
  });

  it("says what it would make of a transaction before anyone pays for it", () => {
    bootstrap();
    const funded = depositFrom(ALICE_HASH);
    expect(
      plain(
        readBridge("get-funding-script", [
          Cl.bufferFromHex(funded.tx),
          Cl.list(funded.parents.map((p) => Cl.bufferFromHex(p))),
        ]) as any,
      ),
    ).toBe(`0x${scriptFor("04", ALICE_HASH)}`);
  });
});

describe("bond-bridge: what a client has to build", () => {
  it("computes the same digest off chain as the contract does", () => {
    bootstrap();
    // Written out here rather than taken from `get-address-digest`, so the
    // contract is checked against something not of its own making -- a client
    // that builds the commit before the contract can be asked has to agree.
    const digest = createHash("sha256")
      .update(
        Buffer.from(
          serializeCV(
            Cl.tuple({
              script: Cl.bufferFromHex(scriptFor("04", ALICE_HASH)),
              salt: Cl.bufferFromHex(SALT),
            }),
          ),
          "hex",
        ),
      )
      .digest("hex");

    expect(addressDigest(aliceAddress, SALT)).toBe(`0x${digest}`);
    expect(commitBtcAddress(alice, digest, ALICE_SATS).type).toBe("ok");
    simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
    expect(revealBtcAddress(alice, aliceAddress, SALT).type).toBe("ok");
  });

  it("takes an explorer's hex as it comes, witnesses and all", async () => {
    bootstrap();
    const funded = depositFrom(ALICE_HASH);
    // What `/tx/:txid/hex` returns: the same transaction with a marker, a flag
    // and one witness stack per input. Its txid is unchanged -- witnesses are
    // not part of it -- and the contract reads either form.
    const witness =
      `${funded.tx.slice(0, 8)}0001${funded.tx.slice(8, -8)}` +
      `02${"47" + "aa".repeat(0x47)}${"21" + "bb".repeat(0x21)}` +
      funded.tx.slice(-8);

    expect(parseTx(witness).segwit).toBe(true);
    expect(await txidOfAsync(funded.tx)).toBe(funded.txid);
    expect(plain(readBridge("get-txid", [Cl.bufferFromHex(witness)]))).toBe(
      `0x${funded.txid}`,
    );

    expect(announceBtcAddress(alice, ALICE_SATS, aliceAddress).type).toBe("ok");
    sweep(funded.txid, ALICE_SATS);
    expect(
      completeBtcDeposit(funded.txid, witness, funded.parents).type,
    ).toBe("ok");
  });
});

describe("bond-bridge: leaving over the sBTC bridge", () => {
  const MAX_FEE = 10_000;

  /** A member with released principal, ready to be paid out. */
  function readyToLeave() {
    const { bondStart, unlockHeight } = bootstrap();
    deposit(alice, ALICE_SATS);
    deposit(bob, BOB_SATS);
    advanceToBurnHeight(bondStart - 288);
    expect(stake().type).toBe("ok");
    advanceToBurnHeight(unlockHeight);
    expect(unstakeSbtc().type).toBe("ok");
  }

  it("asks the bridge to pay a bitcoin address, and settles the answer", () => {
    readyToLeave();
    const result = plain(claimPrincipalToBtc(alice, MAX_FEE) as any);
    const requestId = Number(result["request-id"]);

    expect(Number(result.sats)).toBe(ALICE_SATS);
    expect(Number(result.amount)).toBe(ALICE_SATS - MAX_FEE);
    expect(Number(poolTotals()["withdrawing-sats"])).toBe(ALICE_SATS);
    expect(btcWithdrawal(requestId).member).toBe(alice);

    // pending until the signers rule on it
    expect(reclaimBtcWithdrawal(requestId)).toBeErr(Cl.uint(310));
    expect(settleBtcWithdrawal(requestId, false).type).toBe("ok");
    expect(reclaimBtcWithdrawal(requestId).type).toBe("ok");

    // rejected: the sats are back on her claim, not lost to the pool
    expect(Number(poolTotals()["withdrawing-sats"])).toBe(0);
    expect(Number(settledMember(alice)["released-sats"])).toBe(ALICE_SATS);
  });

  it("is the member's call alone", () => {
    readyToLeave();
    expect(claimPrincipalToBtc(carol, MAX_FEE)).toBeErr(Cl.uint(110));
    expect(claimPrincipalToBtc(alice, ALICE_SATS)).toBeErr(Cl.uint(116));
  });
});
