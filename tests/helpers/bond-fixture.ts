// Fixture for the `bond-staker` pool: stands up pox-5 protocol bonds in
// simnet, allowlists the pool for them, and binds the pool to one.
//
// Simnet's pox-5 is configured with `first-burnchain-block-height = 0`,
// `reward-cycle-length = 1050` and `prepare-cycle-length = 50`, and bond
// periods start every 2 cycles. So bond index N starts at burn height
// N * 2100, and its 12 cycles end 12600 blocks later -- exactly where bond
// N + 6 begins, which is what makes a roll seamless.
//
//   bond 2  ->  starts 4200,  ends 16800
//   bond 8  ->  starts 16800, ends 29400
//   bond 14 ->  starts 29400, ends 42000
//
// `setup-bond` may only be called by pox-5's bond admin. On simnet that role
// is still the boot address the contract source names, which is the sender
// used below -- no simnet wallet holds it.
import {
  Cl,
  ClarityValue,
  cvToValue,
  privateKeyToPublic,
  signMessageHashRsv,
} from "@stacks/transactions";
import { createHash } from "node:crypto";

/** `ripemd160(sha256(x))` — how bitcoin turns a public key into an address. */
const hash160 = (hex: string) => {
  const sha = createHash("sha256").update(Buffer.from(hex, "hex")).digest();
  return createHash("ripemd160").update(sha).digest("hex");
};

/**
 * The 65-byte form of a compressed key: `0x04 || X || Y`, with Y recovered
 * from the curve. Done here with plain bigints rather than a library, so the
 * contract's `secp256k1-decompress?` is being checked against arithmetic and
 * not against another copy of itself.
 */
const decompressPublicKey = (compressed: string) => {
  const P = 2n ** 256n - 2n ** 32n - 977n;
  const x = BigInt(`0x${compressed.slice(2)}`);
  // y² = x³ + 7, and √ is a³ for p ≡ 3 mod 4 with a = (p + 1) / 4
  const ySquared = (x ** 3n + 7n) % P;
  let y = 1n;
  for (let e = (P + 1n) / 4n, base = ySquared; e > 0n; e >>= 1n) {
    if (e & 1n) y = (y * base) % P;
    base = (base * base) % P;
  }
  // the prefix says which root: 02 for even Y, 03 for odd
  if ((y & 1n) !== BigInt(compressed.slice(0, 2) === "03" ? 1 : 0)) y = P - y;
  return `04${x.toString(16).padStart(64, "0")}${y.toString(16).padStart(64, "0")}`;
};

/** The two helpers above, for tests that need to build an address by hand. */
export const hash160Of = hash160;
export const uncompressedKey = (privateKey: string) =>
  decompressPublicKey(privateKeyToPublic(privateKey));

export const POX5 = "ST000000000000000000002AMW42H.pox-5";
export const SBTC_DEPLOYER = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4";
export const SBTC = `${SBTC_DEPLOYER}.sbtc-token`;
/** The manager the pool stakes through, and the one it can be moved to. */
export const MANAGER = "fastpool-max500-signer-manager";
export const ALT_MANAGER = "fastpool-signer-manager";
/** One that calls `sync-rewards` back from inside `validate-stake!`. */
export const CALLBACK_MANAGER = "callback-signer-manager";
export const POOL = "bond-staker";
export const TREASURY = "bond-treasury";
export const BRIDGE = "bond-bridge";

/** pox-5's bond admin on simnet. */
export const BOND_ADMIN = "ST000000000000000000002AMW42H";

export const CYCLE_LENGTH = 1050;

/** The bond the pool starts on, and the one it rolls into. */
export const BOND_INDEX = 2;
export const NEXT_BOND_INDEX = 8;
/** uSTX per 100 sats: ~$100k BTC against ~$1 STX. */
export const STX_VALUE_RATIO = 100_000;
/** Basis points of the sBTC value that must be locked as STX -- 5%. */
export const MIN_USTX_RATIO = 500;
/** Sats the bond admin allowlists the pool for. */
export const ALLOWANCE_SATS = 500_000_000;
/** Sats the pool itself accepts, at or below the allowlisted amount. */
export const MAX_SATS = 400_000_000;

/** Deterministic grant keys; the trailing 01 marks them compressed. */
const SIGNER_KEYS: Record<string, string> = {
  [MANAGER]:
    "010101010101010101010101010101010101010101010101010101010101010101",
  [ALT_MANAGER]:
    "020202020202020202020202020202020202020202020202020202020202020201",
  [CALLBACK_MANAGER]:
    "030303030303030303030303030303030303030303030303030303030303030301",
};

const accounts = simnet.getAccounts();
export const deployer = accounts.get("deployer")!;
export const poolPrincipal = () => `${deployer}.${POOL}`;
export const treasuryPrincipal = () => `${deployer}.${TREASURY}`;
export const bridgePrincipal = () => `${deployer}.${BRIDGE}`;
export const managerPrincipal = (name = MANAGER) => `${deployer}.${name}`;

export const num = (cv: ClarityValue) => Number(cvToValue(cv, true));

/**
 * `cvToValue` leaves `{ type, value }` wrappers on nested fields; strip them
 * so a tuple reads as a plain object.
 */
const unwrap = (value: any): any => {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(unwrap);
  if ("type" in value && "value" in value) return unwrap(value.value);
  return Object.fromEntries(
    Object.entries(value).map(([key, inner]) => [key, unwrap(inner)]),
  );
};

export const plain = (cv: ClarityValue) => unwrap(cvToValue(cv, true));

export function expectOk(cv: ClarityValue, label: string) {
  if (cv.type === "err") {
    throw new Error(`${label} failed: ${Cl.prettyPrint(cv)}`);
  }
  return cv;
}

export const readPox = (fn: string, args: ClarityValue[] = []) =>
  simnet.callReadOnlyFn(POX5, fn, args, deployer).result;

export const readPoxNum = (fn: string, args: ClarityValue[] = []) =>
  num(readPox(fn, args));

export const readPool = (fn: string, args: ClarityValue[] = []) =>
  simnet.callReadOnlyFn(POOL, fn, args, deployer).result;

export const sbtcBalance = (who: string) =>
  num(
    (
      simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer)
        .result as any
    ).value,
  );

/** Total STX held, locked included. */
export const stxBalance = (who: string) =>
  Number(simnet.getAssetsMap().get("STX")?.get(who) ?? 0n);

/** Mine burn blocks until `simnet.burnBlockHeight >= target`. */
export function advanceToBurnHeight(target: number) {
  const delta = target - simnet.burnBlockHeight;
  if (delta > 0) simnet.mineEmptyBurnBlocks(delta);
  return simnet.burnBlockHeight;
}

export const bondStartHeight = (index: number) =>
  readPoxNum("bond-period-to-burn-height", [Cl.uint(index)]);

/** Register a signer-manager contract as a pox-5 signer, with its own key. */
export function registerSignerManager(name = MANAGER, authId = 1) {
  const privateKey = SIGNER_KEYS[name];
  const contractId = managerPrincipal(name);
  const raw = (
    simnet.callReadOnlyFn(
      POX5,
      "get-signer-grant-message-hash",
      [Cl.principal(contractId), Cl.uint(authId)],
      deployer,
    ).result as any
  ).value;
  const messageHash =
    typeof raw === "string" ? raw : Buffer.from(raw).toString("hex");
  const signature = signMessageHashRsv({ messageHash, privateKey });

  return simnet.callPublicFn(
    name,
    "register-self",
    [
      Cl.principal(contractId),
      Cl.bufferFromHex(privateKeyToPublic(privateKey)),
      Cl.uint(authId),
      Cl.bufferFromHex(signature),
    ],
    deployer,
  ).result;
}

/**
 * Create a bond and allowlist the pool for `allowanceSats`. `ratio` prices
 * sats in uSTX per 100 sats -- raise it to model Bitcoin gaining on STX.
 */
export function setupBond(
  index = BOND_INDEX,
  allowanceSats = ALLOWANCE_SATS,
  ratio = STX_VALUE_RATIO,
) {
  // `setup-bond` is only allowed within 2 cycles of the bond start.
  advanceToBurnHeight(bondStartHeight(index) - 2 * CYCLE_LENGTH);

  const result = simnet.callPublicFn(
    POX5,
    "setup-bond",
    [
      Cl.uint(index),
      Cl.uint(1000), // target rate, bips -- not used by the pool
      Cl.uint(ratio),
      Cl.uint(MIN_USTX_RATIO),
      Cl.bufferFromHex("00"), // early-unlock script, the sBTC path ignores it
      Cl.list([
        Cl.tuple({
          staker: Cl.principal(poolPrincipal()),
          "max-sats": Cl.uint(allowanceSats),
        }),
      ]),
    ],
    BOND_ADMIN,
  ).result;
  expectOk(result, `setup-bond ${index}`);
  return result;
}

export const initializePool = (sender = deployer, manager = MANAGER) =>
  simnet.callPublicFn(
    POOL,
    "initialize",
    [Cl.principal(managerPrincipal(manager)), Cl.principal(deployer)],
    sender,
  ).result;

/**
 * Bind whatever the walk finds. No index, no allocation: the call takes none,
 * and anyone may make it -- `sender` is here to prove that, not to authorize.
 */
export const bindNextBond = (sender = deployer) =>
  simnet.callPublicFn(POOL, "bind-next-bond", [], sender).result;

/** The floor the members put under the next bind. Operator-only. */
export const setNextBond = (index: number, sender = deployer) =>
  simnet.callPublicFn(POOL, "set-next-bond", [Cl.uint(index)], sender).result;

/** What `bind-next-bond` would take right now, or null if there is nothing. */
export const nextBond = (): number | null => {
  const found = plain(readPool("find-next-bond", []));
  return found === null ? null : Number(found);
};

/** register signer + initialize + create bond + bind, ready for deposits. */
export function bootstrap(allowanceSats = ALLOWANCE_SATS) {
  registerSignerManager();
  expectOk(initializePool(), "initialize");
  setupBond(BOND_INDEX, allowanceSats);
  expectOk(bindNextBond(), "bind-next-bond");
  return {
    bondStart: bondStartHeight(BOND_INDEX),
    unlockHeight: Number(boundBond()["unlock-burn-height"]),
  };
}

export const deposit = (who: string, sats: number) =>
  simnet.callPublicFn(POOL, "deposit", [Cl.uint(sats)], who).result;

export const depositStx = (who: string, ustx: number) =>
  simnet.callPublicFn(POOL, "deposit-stx", [Cl.uint(ustx)], who).result;

export const withdraw = (who: string) =>
  simnet.callPublicFn(POOL, "withdraw", [], who).result;

export const stake = (who: string = deployer, manager = MANAGER) =>
  simnet.callPublicFn(
    POOL,
    "stake",
    [Cl.principal(managerPrincipal(manager))],
    who,
  ).result;

export const unstakeSbtc = (who: string = deployer, manager = MANAGER) =>
  simnet.callPublicFn(
    POOL,
    "unstake-sbtc",
    [Cl.principal(managerPrincipal(manager))],
    who,
  ).result;

/** Whether the callback manager passes the pool's refusal on, or swallows it. */
export const setCallbackPropagate = (on: boolean, sender = deployer) =>
  simnet.callPublicFn(
    CALLBACK_MANAGER,
    "set-propagate",
    [Cl.bool(on)],
    sender,
  ).result;

/** What the callback manager's last `sync-rewards` call answered. */
export const lastSyncResponse = () =>
  simnet.callReadOnlyFn(
    CALLBACK_MANAGER,
    "get-last-sync-response",
    [],
    deployer,
  ).result;

/** What the pool called its unrecognised rewards mid-roll, seen from inside. */
export const lastUnrecognized = () =>
  num(
    simnet.callReadOnlyFn(
      CALLBACK_MANAGER,
      "get-last-unrecognized",
      [],
      deployer,
    ).result,
  );

export const updateBondRegistration = (
  to: string,
  from: string,
  who: string = deployer,
) =>
  simnet.callPublicFn(
    POOL,
    "update-bond-registration",
    [Cl.principal(to), Cl.principal(from)],
    who,
  ).result;

export const signerHash = (contractId: string) =>
  plain(readPool("get-signer-manager-hash", [Cl.principal(contractId)])) as string;

export const updateOperator = (
  who: string,
  enabled: boolean,
  sender: string = deployer,
) =>
  simnet.callPublicFn(
    POOL,
    "update-operator",
    [Cl.principal(who), Cl.bool(enabled)],
    sender,
  ).result;

export const isOperator = (who: string) =>
  plain(readPool("is-operator", [Cl.principal(who)])) === true;

export const trustSigner = (codeHash: string, who: string = deployer) =>
  simnet.callPublicFn(
    POOL,
    "trust-signer-manager",
    [Cl.bufferFromHex(codeHash.replace(/^0x/, ""))],
    who,
  ).result;

export const distrustSigner = (codeHash: string, who: string = deployer) =>
  simnet.callPublicFn(
    POOL,
    "distrust-signer-manager",
    [Cl.bufferFromHex(codeHash.replace(/^0x/, ""))],
    who,
  ).result;

export const canUseSigner = (contractId: string) =>
  plain(readPool("can-use-signer-manager", [Cl.principal(contractId)])) === true;

export const trustedSigner = (codeHash: string) =>
  plain(
    readPool("get-trusted-signer", [
      Cl.bufferFromHex(codeHash.replace(/^0x/, "")),
    ]),
  );

/** Take committed sBTC back before the bond's term is up. */
export const unstakeEarly = (who: string, sats: number, manager = MANAGER) =>
  simnet.callPublicFn(
    POOL,
    "unstake-sbtc-early",
    [Cl.principal(managerPrincipal(manager)), Cl.uint(sats)],
    who,
  ).result;

export const requestExit = (who: string) =>
  simnet.callPublicFn(POOL, "request-exit", [], who).result;

export const cancelExit = (who: string) =>
  simnet.callPublicFn(POOL, "cancel-exit", [], who).result;

export const settleMember = (who: string, sender = deployer) =>
  simnet.callPublicFn(POOL, "settle-member", [Cl.principal(who)], sender)
    .result;

export const syncRewards = (who: string = deployer) =>
  simnet.callPublicFn(POOL, "sync-rewards", [], who).result;

export const claimRewards = (member: string, who: string = deployer) =>
  simnet.callPublicFn(POOL, "claim-rewards", [Cl.principal(member)], who)
    .result;

export const claimPrincipal = (member: string, who: string = deployer) =>
  simnet.callPublicFn(POOL, "claim-principal", [Cl.principal(member)], who)
    .result;

export const SBTC_REGISTRY = `${SBTC_DEPLOYER}.sbtc-registry`;
export const SBTC_DEPOSIT = `${SBTC_DEPLOYER}.sbtc-deposit`;
export const SBTC_WITHDRAWAL = `${SBTC_DEPLOYER}.sbtc-withdrawal`;

/** A p2pkh-shaped bitcoin address, for withdrawal requests. */
export const btcRecipient = (byte = "11") =>
  Cl.tuple({
    version: Cl.bufferFromHex("00"),
    hashbytes: Cl.bufferFromHex(byte.repeat(20)),
  });

/** The principal the sBTC protocol lets complete deposits and withdrawals. */
export const sbtcSigner = () =>
  plain(
    simnet.callReadOnlyFn(
      SBTC_REGISTRY,
      "get-current-signer-principal",
      [],
      deployer,
    ).result,
  ) as string;

/** The salt most tests use; only the commit/reveal tests care which it is. */
export const SALT = "5a".repeat(32);

export const REVEAL_DELAY = 1;

/** Burn blocks before a stranger may clear an unrevealed commitment. */
export const COMMIT_TTL = 36;

/** ...and before they may clear a revealed one. */
export const ANNOUNCE_TTL = 1000;

/** A `{version, hashbytes}` bitcoin address; p2wpkh unless told otherwise. */
export const btcAddress = (hash = "11".repeat(20), version = "04") =>
  Cl.tuple({
    version: Cl.bufferFromHex(version),
    hashbytes: Cl.bufferFromHex(hash),
  });

/** Ask the contract what an (address, salt) commits to. */
export const addressDigest = (address = btcAddress(), salt = SALT) =>
  plain(
    readBridge("get-address-digest", [address, Cl.bufferFromHex(salt)]),
  ) as string;

export const commitBtcAddress = (who: string, digest: string, sats: number) =>
  simnet.callPublicFn(
    BRIDGE,
    "commit-btc-address",
    [Cl.bufferFromHex(digest.replace(/^0x/, "")), Cl.uint(sats)],
    who,
  ).result;

export const revealBtcAddress = (
  who: string,
  address = btcAddress(),
  salt = SALT,
) =>
  simnet.callPublicFn(
    BRIDGE,
    "reveal-btc-address",
    [address, Cl.bufferFromHex(salt)],
    who,
  ).result;

/**
 * The fast lane: an address the member can sign for.
 *
 * The address is a recipe over the public key, so the key decides what address
 * these helpers are talking about rather than the other way round. One recipe
 * per shape, computed here independently of the contract so the test is
 * checking the contract rather than agreeing with it.
 *
 *   00  p2pkh        hash160 of the key
 *   02  p2sh-p2wpkh  hash160 of `0x0014 || hash160(key)`, the key's own
 *                    witness program used as a redeem script
 *   04  p2wpkh       hash160 of the key
 *
 * `uncompressed` is for the legacy case only: an old p2pkh address may hash
 * the 65-byte encoding of the same key, which is a different address.
 */
export const btcKeyAddress = (
  privateKey: string,
  version = "04",
  { uncompressed = false }: { uncompressed?: boolean } = {},
) => {
  const key = uncompressed
    ? decompressPublicKey(privateKeyToPublic(privateKey))
    : privateKeyToPublic(privateKey);
  const keyhash = hash160(key);
  return btcAddress(
    version === "02" ? hash160(`0014${keyhash}`) : keyhash,
    version,
  );
};

/** Sign the exact message the contract will rebuild for `member`. */
export const signAddressClaim = (member: string, privateKey: string) => {
  const digest = plain(
    readBridge("get-address-claim-digest", [Cl.principal(member)]),
  ) as string;
  return signMessageHashRsv({
    messageHash: digest.replace(/^0x/, ""),
    privateKey,
  });
};

export const claimBtcAddress = (
  who: string,
  privateKey: string,
  sats: number,
  address = btcKeyAddress(privateKey),
  signature = signAddressClaim(who, privateKey),
) =>
  simnet.callPublicFn(
    BRIDGE,
    "claim-btc-address",
    [
      address,
      Cl.bufferFromHex(privateKeyToPublic(privateKey)),
      Cl.bufferFromHex(signature.replace(/^0x/, "")),
      Cl.uint(sats),
    ],
    who,
  ).result;

export const cancelBtcCommitment = (
  member: string,
  digest: string,
  who: string = member,
) =>
  simnet.callPublicFn(
    BRIDGE,
    "cancel-btc-commitment",
    [Cl.principal(member), Cl.bufferFromHex(digest.replace(/^0x/, ""))],
    who,
  ).result;

/**
 * The whole pre-send half of the flow: commit, wait out REVEAL_DELAY, reveal.
 * Returns the failing step's error if either fails, so callers can assert on it
 * the way they would on one call.
 */
export const announceBtcAddress = (
  who: string,
  sats: number,
  address = btcAddress(),
  salt = SALT,
) => {
  const committed = commitBtcAddress(who, addressDigest(address, salt), sats);
  if (committed.type === "err") return committed;
  simnet.mineEmptyBurnBlocks(REVEAL_DELAY);
  return revealBtcAddress(who, address, salt);
};

export const completeBtcDeposit = (
  txid: string,
  tx: string,
  parents: string[],
  voutIndex = 0,
  who: string = deployer,
) =>
  simnet.callPublicFn(
    BRIDGE,
    "complete-btc-deposit",
    [
      Cl.bufferFromHex(txid),
      Cl.uint(voutIndex),
      Cl.bufferFromHex(tx),
      Cl.list(parents.map((parent) => Cl.bufferFromHex(parent))),
    ],
    who,
  ).result;

export const cancelBtcAddress = (
  address = btcAddress(),
  who: string = deployer,
) => simnet.callPublicFn(BRIDGE, "cancel-btc-deposit", [address], who).result;

export const claimPrincipalToBtc = (
  who: string,
  maxFee: number,
  recipient = btcRecipient(),
) =>
  simnet.callPublicFn(
    BRIDGE,
    "claim-principal-to-btc",
    [recipient, Cl.uint(maxFee)],
    who,
  ).result;

export const reclaimBtcWithdrawal = (
  requestId: number,
  who: string = deployer,
) =>
  simnet.callPublicFn(
    BRIDGE,
    "reclaim-btc-withdrawal",
    [Cl.uint(requestId)],
    who,
  ).result;

export const sweepUnattributed = (recipient: string, who: string = deployer) =>
  simnet.callPublicFn(
    POOL,
    "sweep-unattributed-principal",
    [Cl.principal(recipient)],
    who,
  ).result;

/** Sweep a bitcoin deposit through the bridge, minting sBTC to `recipient`. */
export function sweepBtcDeposit(
  txid: string,
  sats: number,
  recipient = treasuryPrincipal(),
  voutIndex = 0,
) {
  const height = simnet.burnBlockHeight - 1;
  const header = (
    simnet.callReadOnlyFn(
      SBTC_DEPOSIT,
      "get-burn-header",
      [Cl.uint(height)],
      deployer,
    ).result as any
  ).value;
  return simnet.callPublicFn(
    SBTC_DEPOSIT,
    "complete-deposit-wrapper",
    [
      Cl.bufferFromHex(txid),
      Cl.uint(voutIndex),
      Cl.uint(sats),
      Cl.principal(recipient),
      header,
      Cl.uint(height),
      Cl.bufferFromHex("bb".repeat(32)),
    ],
    sbtcSigner(),
  ).result;
}

/** Have the sBTC signers accept or reject a withdrawal request. */
export function settleBtcWithdrawal(
  requestId: number,
  accept: boolean,
  fee = 1_000,
) {
  const height = simnet.burnBlockHeight - 1;
  const header = (
    simnet.callReadOnlyFn(
      SBTC_DEPOSIT,
      "get-burn-header",
      [Cl.uint(height)],
      deployer,
    ).result as any
  ).value;
  return accept
    ? simnet.callPublicFn(
        SBTC_WITHDRAWAL,
        "accept-withdrawal-request",
        [
          Cl.uint(requestId),
          Cl.bufferFromHex("cc".repeat(32)), // bitcoin-txid
          Cl.uint(0), // signer-bitmap
          Cl.uint(0), // output-index
          Cl.uint(fee),
          header,
          Cl.uint(height),
          Cl.bufferFromHex("dd".repeat(32)),
        ],
        sbtcSigner(),
      ).result
    : simnet.callPublicFn(
        SBTC_WITHDRAWAL,
        "reject-withdrawal-request",
        [Cl.uint(requestId), Cl.uint(0)],
        sbtcSigner(),
      ).result;
}

export const readTreasury = (fn: string, args: ClarityValue[] = []) =>
  simnet.callReadOnlyFn(TREASURY, fn, args, deployer).result;

export const readBridge = (fn: string, args: ClarityValue[] = []) =>
  simnet.callReadOnlyFn(BRIDGE, fn, args, deployer).result;

export const btcAnnouncement = (address = btcAddress()) =>
  plain(readBridge("get-announcement", [address])) as any;

export const btcCommitment = (member: string, digest: string) =>
  plain(
    readBridge("get-commitment", [
      Cl.principal(member),
      Cl.bufferFromHex(digest.replace(/^0x/, "")),
    ]),
  ) as any;

export const creditedDeposit = (txid: string, voutIndex = 0) =>
  plain(
    readBridge("get-credited-deposit", [
      Cl.bufferFromHex(txid),
      Cl.uint(voutIndex),
    ]),
  ) as any;

export const btcWithdrawal = (requestId: number) =>
  plain(readBridge("get-withdrawal", [Cl.uint(requestId)])) as any;

export const unattributedPrincipal = () =>
  num(readPool("get-unattributed-principal"));

/** Move sBTC into the pool, standing in for a signer-manager reward payout. */
export const payRewards = (from: string, amount: number) =>
  simnet.callPublicFn(
    SBTC,
    "transfer",
    [
      Cl.uint(amount),
      Cl.principal(from),
      Cl.principal(poolPrincipal()),
      Cl.none(),
    ],
    from,
  ).result;

/** The STX leg pox-5 requires for `sats` under the bound bond. */
export const requiredUstx = (sats: number) =>
  num(readPool("get-required-ustx", [Cl.uint(sats)]));

export const poolConfig = () => plain(readPool("get-config")) as any;
export const boundBond = () => plain(readPool("get-bound-bond")) as any;
export const stakePreview = () => plain(readPool("get-stake-preview")) as any;
export const poolTotals = () => plain(readPool("get-pool")) as any;
export const epoch = (index: number) =>
  plain(readPool("get-epoch", [Cl.uint(index)])) as any;
export const member = (who: string) =>
  plain(readPool("get-member", [Cl.principal(who)])) as any;
export const settledMember = (who: string) =>
  plain(readPool("get-settled-member", [Cl.principal(who)])) as any;
/** The epoch `sync-rewards` would credit right now. */
export const rewardEpoch = () => Number(plain(readPool("get-reward-epoch")));

export const claimableRewards = (who: string) =>
  num(readPool("get-claimable-rewards", [Cl.principal(who)]));
export const claimablePrincipal = (who: string) =>
  plain(readPool("get-claimable-principal", [Cl.principal(who)])) as any;
export const earlyUnstakePreview = (who: string) =>
  plain(readPool("get-early-unstake-preview", [Cl.principal(who)])) as any;

/** What pox-5 says it is holding for the pool. */
export const custodiedSats = () =>
  readPoxNum("get-staker-custodied-sbtc", [Cl.principal(poolPrincipal())]);

/** Whether pox-5 would currently refuse an unstake for prepare-phase reasons. */
export function inPreparePhase() {
  const cycle = readPoxNum("current-pox-reward-cycle");
  return plain(readPox("is-in-prepare-phase", [Cl.uint(cycle)])) === true;
}

/**
 * Move to a burn height that is not inside a reward cycle's prepare phase.
 *
 * pox-5 refuses `unstake-sbtc` there, so an early exit can bounce on timing
 * alone. Tests that are not about that should not have to care. Asked of pox-5
 * rather than worked out from the cycle length, so the helper cannot drift
 * from the rule it is dodging.
 */
export function avoidPreparePhase() {
  for (let guard = 0; inPreparePhase() && guard < 200; guard++) {
    simnet.mineEmptyBurnBlocks(10);
  }
  return simnet.burnBlockHeight;
}

/** The pooled principal: the treasury's sBTC balance. */
export const treasuryBalance = () => sbtcBalance(treasuryPrincipal());
