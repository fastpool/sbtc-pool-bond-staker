import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import {
  advanceToBurnHeight,
  ALT_MANAGER,
  bondStartHeight,
  bindNextBond,
  bootstrap,
  BOND_INDEX,
  boundBond,
  deployer,
  deposit,
  epoch,
  managerPrincipal,
  NEXT_BOND_INDEX,
  num,
  plain,
  POOL,
  poolConfig,
  registerSignerManager,
  setupBond,
  stake,
} from "./helpers/bond-fixture";

const DAO = "esbee-dao";
const accounts = simnet.getAccounts();
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const carol = accounts.get("wallet_3")!;

const ALICE_SATS = 10_000_000; // sqrt -> 3162
const BOB_SATS = 30_000_000; //  sqrt -> 5477

const daoPrincipal = () => `${deployer}.${DAO}`;
const readDao = (fn: string, args: any[] = []) =>
  simnet.callReadOnlyFn(DAO, fn, args, deployer).result;
const callDao = (fn: string, args: any[], who: string) =>
  simnet.callPublicFn(DAO, fn, args, who).result;

const weight = (who: string) => num(readDao("get-weight", [Cl.principal(who)]));
const status = (id: number) => plain(readDao("get-status", [Cl.uint(id)])) as any;
const proposal = (id: number) => plain(readDao("get-proposal", [Cl.uint(id)])) as any;

const vote = (id: number, support: boolean, who: string) =>
  callDao("vote", [Cl.uint(id), Cl.bool(support)], who);

/** Stake the pool, then hand the operator seat to the DAO. */
function daoInCharge() {
  const { bondStart } = bootstrap();
  deposit(alice, ALICE_SATS);
  deposit(bob, BOB_SATS);
  advanceToBurnHeight(bondStart - 288);
  expect(stake().type).toBe("ok");

  expect(
    simnet.callPublicFn(
      POOL,
      "update-operator",
      [Cl.principal(daoPrincipal()), Cl.bool(true)],
      deployer,
    ).result.type,
  ).toBe("ok");
  return { bondStart };
}

/** Carry a proposal all the way to the point of execution. */
function passProposal(id: number) {
  vote(id, true, alice);
  vote(id, true, bob);
  const s = status(id);
  advanceToBurnHeight(Number(s["executable-from"]));
  return s;
}

describe("esbee-dao: who votes and with how much", () => {
  beforeEach(() => {
    daoInCharge();
  });

  it("weighs a member by the square root of their committed sats", () => {
    expect(weight(alice)).toBe(Math.floor(Math.sqrt(ALICE_SATS)));
    expect(weight(bob)).toBe(Math.floor(Math.sqrt(BOB_SATS)));
    // three times the stake is not three times the say
    expect(weight(bob) / weight(alice)).toBeCloseTo(Math.sqrt(3), 2);
    expect(weight(carol)).toBe(0);
  });

  it("lets nobody outside the pool propose or vote", () => {
    expect(callDao("propose-sweep", [Cl.principal(carol)], carol)).toBeErr(
      Cl.uint(401), // NOT_A_MEMBER
    );
    callDao("propose-sweep", [Cl.principal(carol)], alice);
    expect(vote(0, true, carol)).toBeErr(Cl.uint(401));
  });

  it("counts a vote once, at the weight held when it was cast", () => {
    callDao("propose-sweep", [Cl.principal(carol)], alice);
    expect(vote(0, true, alice).type).toBe("ok");
    expect(vote(0, false, alice)).toBeErr(Cl.uint(406)); // ALREADY_VOTED
    expect(Number(proposal(0).yes)).toBe(weight(alice));
    expect(
      Number(plain(readDao("get-vote", [Cl.uint(0), Cl.principal(alice)])).weight),
    ).toBe(weight(alice));
  });
});

describe("esbee-dao: nothing passes quietly", () => {
  beforeEach(() => {
    daoInCharge();
    callDao("propose-sweep", [Cl.principal(carol)], alice);
  });

  it("will not settle in the same block it was raised", () => {
    vote(0, true, alice);
    vote(0, true, bob);
    expect(status(0)["voting-open"]).toBe(true);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(405), // VOTING_OPEN
    );
  });

  it("will not pass on an empty room", () => {
    // nobody votes at all
    advanceToBurnHeight(Number(status(0)["executable-from"]));
    expect(status(0)["met-quorum"]).toBe(false);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(407), // NO_QUORUM
    );
  });

  it("will not pass without a supermajority", () => {
    vote(0, true, alice); // 3162
    vote(0, false, bob); // 5477 against
    advanceToBurnHeight(Number(status(0)["executable-from"]));
    expect(status(0)["met-quorum"]).toBe(true);
    expect(status(0).approved).toBe(false);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(408), // REJECTED
    );
  });

  it("holds a passed proposal for a day before it can land", () => {
    vote(0, true, alice);
    vote(0, true, bob);
    const s = status(0);
    // voting is over and it carried, but the delay has not run
    advanceToBurnHeight(Number(proposal(0)["voting-ends-at"]));
    expect(status(0).approved).toBe(true);
    expect(status(0).ready).toBe(false);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(409), // TOO_EARLY
    );

    advanceToBurnHeight(Number(s["executable-from"]));
    expect(status(0).ready).toBe(true);
  });

  it("lets a stale mandate expire", () => {
    passProposal(0);
    advanceToBurnHeight(simnet.burnBlockHeight + 1008);
    expect(status(0).expired).toBe(true);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(410), // EXPIRED
    );
  });

  it("voids a mandate the pool has rolled past", () => {
    passProposal(0);
    // the membership that voted is not the membership that would live with it
    setupBond(NEXT_BOND_INDEX);
    simnet.callPublicFn(POOL, "bind-next-bond", [], deployer);
    advanceToBurnHeight(bondStartHeight(NEXT_BOND_INDEX) - 288);
    expect(stake().type).toBe("ok");

    expect(status(0)["same-epoch"]).toBe(false);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(413), // EPOCH_MOVED
    );
  });

  it("cannot spend one mandate on another power", () => {
    passProposal(0);
    expect(callDao("execute-trust-signer", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(412), // WRONG_KIND
    );
  });

  it("cannot be executed twice", () => {
    // a kind that lands cleanly: the sweep in the beforeEach has nothing to
    // sweep, and bond-staker rightly refuses it
    callDao("propose-trust-signer", [Cl.bufferFromHex("ab".repeat(32))], alice);
    passProposal(1);
    expect(callDao("execute-trust-signer", [Cl.uint(1)], carol).type).toBe("ok");
    expect(callDao("execute-trust-signer", [Cl.uint(1)], carol)).toBeErr(
      Cl.uint(411), // ALREADY_EXECUTED
    );
  });

  it("keeps a mandate alive when the call it makes fails", () => {
    // there is nothing unattributed to sweep, so bond-staker refuses and the
    // whole transaction reverts -- including the executed flag, so the mandate
    // can still be spent once the underlying call would succeed
    passProposal(0);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(Cl.uint(114));
    expect(status(0).executed).toBe(false);
    expect(status(0).ready).toBe(true);
  });
});

describe("esbee-dao: exercising the operator's powers", () => {
  beforeEach(() => {
    daoInCharge();
  });

  it("adds a signer manager to the trusted list by vote", () => {
    const hash = plain(
      simnet.callReadOnlyFn(
        POOL,
        "get-signer-manager-hash",
        [Cl.principal(managerPrincipal(ALT_MANAGER))],
        deployer,
      ).result,
    ) as string;
    callDao(
      "propose-trust-signer",
      [Cl.bufferFromHex(hash.replace(/^0x/, ""))],
      alice,
    );
    passProposal(0);
    expect(callDao("execute-trust-signer", [Cl.uint(0)], carol).type).toBe("ok");
    expect(
      Number(
        plain(
          simnet.callReadOnlyFn(
            POOL,
            "get-trusted-signer",
            [Cl.bufferFromHex(hash.replace(/^0x/, ""))],
            deployer,
          ).result,
        ),
      ),
    ).toBe(1);
  });

  it("checks the signer change against what was actually voted on", () => {
    registerSignerManager(ALT_MANAGER, 7);
    callDao(
      "propose-signer-change",
      [Cl.principal(managerPrincipal(ALT_MANAGER)), Cl.principal(managerPrincipal())],
      alice,
    );
    passProposal(0);
    // executing with a different manager than the one voted on is refused
    expect(
      simnet.callPublicFn(
        DAO,
        "execute-signer-change",
        [
          Cl.uint(0),
          Cl.principal(managerPrincipal()),
          Cl.principal(managerPrincipal()),
        ],
        carol,
      ).result,
    ).toBeErr(Cl.uint(414)); // WRONG_TARGET
  });

  it("cannot vote itself out of the operator seat", () => {
    // bond-staker refuses to change your own entry, and the DAO is the caller
    callDao(
      "propose-operator-change",
      [Cl.principal(daoPrincipal()), Cl.bool(false)],
      alice,
    );
    passProposal(0);
    expect(callDao("execute-operator-change", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(100), // bond-staker UNAUTHORIZED
    );
  });
});

describe("esbee-dao: skipping a bond", () => {
  beforeEach(() => {
    daoInCharge();
  });

  it("puts a floor under the next bind, and nothing else", () => {
    // The pool is live in bond 2, so the walk would take 2 + 6 next. The
    // members decide to sit that one out.
    callDao("propose-next-bond", [Cl.uint(NEXT_BOND_INDEX + 1)], alice);
    expect(proposal(0).kind).toBe("next-bond");
    expect(Number(proposal(0).index)).toBe(NEXT_BOND_INDEX + 1);

    passProposal(0);
    expect(callDao("execute-next-bond", [Cl.uint(0)], carol).type).toBe("ok");
    expect(Number(poolConfig()["min-bond-index"])).toBe(NEXT_BOND_INDEX + 1);

    // and the bond they skipped is now unbindable, by anyone
    setupBond(NEXT_BOND_INDEX);
    expect(bindNextBond(carol)).toBeErr(Cl.uint(103)); // BOND_NOT_FOUND
  });

  it("spends a mandate on the power it was raised for and no other", () => {
    callDao("propose-next-bond", [Cl.uint(NEXT_BOND_INDEX + 1)], alice);
    passProposal(0);
    expect(callDao("execute-sweep", [Cl.uint(0)], carol)).toBeErr(
      Cl.uint(412), // WRONG_KIND
    );
  });

  it("binds without a vote when the members have said nothing", () => {
    setupBond(NEXT_BOND_INDEX);
    // carol is not a member, not an operator, and does not need to be
    expect(bindNextBond(carol).type).toBe("ok");
    expect(Number(boundBond()["bond-index"])).toBe(NEXT_BOND_INDEX);
  });
});
