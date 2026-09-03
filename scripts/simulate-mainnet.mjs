// Dry-run the pool against real mainnet state, on stxer.
//
//   node scripts/simulate-mainnet.mjs genesis
//   node scripts/simulate-mainnet.mjs bridge
//
// Nothing here is signed or broadcast. stxer forks mainnet at a block and
// replays the steps against that state, so the contracts are checked against
// the pox-5 and sBTC that are actually deployed rather than against simnet
// stand-ins -- and the steps may be sent from principals we do not hold a key
// for, which is the only way to model the bond admin's side of the launch.
//
// Two things this can prove and the test suite cannot: that the contracts
// deploy and initialize against mainnet's pox-5, and that the pool can bind
// the genesis bond under the name its allowlist spells and stake into it.
//
// The genesis bond is set up on mainnet and allowlists
// `<deployer>.esbee-dao-bond-staker-1`, so the run takes the bond as it is:
// its real pricing, the real grant, the real signer manager. The allowlisting
// step is only simulated when the bond the run lands on does not exist yet --
// a later bond, say -- and then the parameters under BOND are *our
// assumptions*, not the protocol's.
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  Cl,
  ClarityVersion,
  cvToJSON,
  fetchCallReadOnlyFunction,
  hexToCV,
  cvToString,
  serializeCV,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";
import { buildTx, scriptFor } from "../lib/btc-tx.js";

const API = "https://api.hiro.so";
const POX5 = "SP000000000000000000002Q6VF78.pox-5";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const SBTC_REGISTRY = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry";

// The burn height the genesis bond starts at, announced at
// https://www.stacks.co/blog/the-genesis-bond-starts-at-bitcoin-block-966-350
// The *index* is not assumed -- it is resolved from this height below, because
// pox-5 does not agree with the obvious guess. See resolveBondIndex.
const GENESIS_BURN_HEIGHT = 966_350;

// Same key as the testnet deployer, in its mainnet form.
const DEPLOYER = "SPFCGF789WX1B737VQYAQ6BG3QYVMJGPDKRKYK00";

// The signer manager the pool stakes through: the published one, already
// registered with pox-5, so nothing has to be deployed or registered for it.
const MANAGER_ID = "SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4.fastpool-max500-signer-manager";

// A real, funded mainnet account, used only to give the simulated member STX
// for the bond's STX leg. It is never asked to do anything else.
const FUNDER = "SP1K1A1PMGW2ZJCNF46NWZWHG8TS1D23EGH1KNK60";

// The contracts are written for Clarity 6 / epoch 4.0, and say so in
// Clarinet.toml. Left to its default, stxer publishes at an older version and
// `bond-staker` fails to analyse on `with-staking` -- an epoch-4 form -- which
// then cascades into every contract that calls it.
const CLARITY = ClarityVersion.Clarity6;

// Published name -> source name, as `build-network.mjs mainnet` writes them.
// The pool is called what the genesis bond's grant spells; the siblings carry
// the same `-1`.
const NAMES = {
  "esbee-dao-bond-staker-1": "bond-staker",
  "bond-treasury-1": "bond-treasury",
  "iou-bond-btc-1": "iou-bond-btc",
  "iou-bond-stx-1": "iou-bond-stx",
  "bond-bridge-1": "bond-bridge",
  "esbee-dao-1": "esbee-dao",
};
const POOL = "esbee-dao-bond-staker-1";
const TREASURY = "bond-treasury-1";
const RECEIPTS = ["iou-bond-btc-1", "iou-bond-stx-1"];
const BRIDGE = "bond-bridge-1";
const DAO = "esbee-dao-1";

// How far behind the tip to pin. The newest blocks are not indexed yet.
const SETTLE_LAG = 10;

// Our assumptions about a bond the run has to create itself. Matching the
// genesis bond's terms: `stx-value-ratio` is uSTX per 100 sats and
// `min-ustx-ratio` is in bips, so 310237 and 500 price the STX leg at about
// 15 512 STX per whole BTC.
const BOND = {
  targetRate: 300,
  stxValueRatio: 310_237,
  minUstxRatio: 500,
  allowanceSats: 500_000_000, // 5 BTC of room for us on the allowlist, as granted
};

// What the simulated member brings. 0.01 BTC wants ~155 STX at the genesis
// bond's pricing, which the funder's transfer below covers.
const MEMBER_SATS = 1_000_000;
const MEMBER_USTX = 200_000_000;

// bond-bridge's REVEAL_DELAY: burn blocks between a commit and its reveal.
const REVEAL_DELAY = 2;

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * Read a built contract, refusing one that is older than its source.
 *
 * A stale build fails deep in the run as `UndefinedFunction`, several minutes
 * and one published simulation later. Cheaper to catch here.
 */
const contract = (name) => {
  const built = join(root, "build", "mainnet", `${name}.clar`);
  const source = join(root, "contracts", `${NAMES[name]}.clar`);
  if (statSync(built).mtimeMs < statSync(source).mtimeMs) {
    console.error(
      `build/mainnet/${name}.clar is older than contracts/${NAMES[name]}.clar\n` +
        `  run: pnpm run build:mainnet`,
    );
    process.exit(1);
  }
  return fitForSdk(name, readFileSync(built, "utf8"));
};

/**
 * `@stacks/transactions` refuses a code body over 100,000 bytes -- its own
 * cap, not the chain's (a transaction may be 2 MB) and not clarinet's, whose
 * Rust codec deploys the published source as written. stxer encodes with the
 * SDK, so a source past the cap is simulated with its comment lines dropped:
 * the same code, byte for byte, minus the prose. Announced, never quiet.
 */
const SDK_CODE_BODY_CAP = 100_000;
const fitForSdk = (name, source) => {
  if (Buffer.byteLength(source) <= SDK_CODE_BODY_CAP) return source;
  const stripped = source
    .split("\n")
    .filter((line) => !line.trimStart().startsWith(";;"))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n");
  console.log(
    `  ${name}: ${Buffer.byteLength(source)} bytes is over the stacks.js cap of ` +
      `${SDK_CODE_BODY_CAP}; simulating without comment lines (${Buffer.byteLength(stripped)} bytes). ` +
      `clarinet deploys the full source.`,
  );
  return stripped;
};

const [poxAddress, poxName] = POX5.split(".");
const readPox = async (functionName, functionArgs = []) =>
  cvToJSON(
    await fetchCallReadOnlyFunction({
      contractAddress: poxAddress,
      contractName: poxName,
      functionName,
      functionArgs,
      senderAddress: DEPLOYER,
      network: "mainnet",
      client: { baseUrl: API },
    }),
  );

const unwrap = (v) => v?.value?.value ?? v?.value ?? v;

/**
 * What `bond-bridge.get-address-digest` would return, computed here so the
 * commit can be built before the contract exists to be asked.
 */
const addressDigest = (script, salt) => {
  const tuple = Cl.tuple({
    script: Cl.bufferFromHex(script),
    salt: Cl.bufferFromHex(salt),
  });
  return createHash("sha256")
    .update(Buffer.from(serializeCV(tuple), "hex"))
    .digest("hex");
};

const sha256d = (hex) =>
  createHash("sha256")
    .update(createHash("sha256").update(Buffer.from(hex, "hex")).digest())
    .digest();

/** The txid of a serialized transaction, as bitcoin displays it. */
const txidOf = (tx) => Buffer.from(sha256d(tx)).reverse().toString("hex");

/**
 * Find the bond whose start height is the announced one.
 *
 * Worth doing rather than hardcoding: "the genesis bond" reads like index 0,
 * but on mainnet index 0 starts at 962,150 -- a cycle earlier, and already
 * past. The bond that starts at 966,350 is a different index, and binding the
 * wrong one would fail late and confusingly.
 */
async function resolveBondIndex() {
  for (let i = 0; i <= 8; i++) {
    const height = Number(unwrap(await readPox("bond-period-to-burn-height", [Cl.uint(i)])));
    if (height === GENESIS_BURN_HEIGHT) {
      const cycle = Number(unwrap(await readPox("bond-period-to-reward-cycle", [Cl.uint(i)])));
      // `.value` is null for `none`; unwrap() cannot be used here, because its
      // nullish chain falls through to the wrapper object and reads as truthy.
      const exists = (await readPox("get-protocol-bond", [Cl.uint(i)])).value != null;
      const granted =
        (await readPox("get-bond-allowance", [Cl.uint(i), Cl.principal(`${DEPLOYER}.${POOL}`)])).value != null;
      return { index: i, height, cycle, exists, granted };
    }
  }
  throw new Error(`no bond index starts at burn height ${GENESIS_BURN_HEIGHT}`);
}

/** pox-5 only lets its bond admin call `setup-bond`. Read who that is. */
async function readBondAdmin() {
  const response = await fetch(
    `${API}/v2/data_var/${poxAddress}/${poxName}/bond-admin?proof=0`,
  );
  const { data } = await response.json();
  return cvToString(hexToCV(data));
}

/**
 * Everything up to a bound bond: publish, register the signer manager, have
 * the bond admin allowlist us, initialize, bind.
 */
function launch(builder, { bond, admin, poolId, managerId }) {
  builder
    .withSender(DEPLOYER)
    .addContractDeploy({ contract_name: TREASURY, source_code: contract(TREASURY), fee: 0, clarity_version: CLARITY });
  for (const name of RECEIPTS) {
    builder.addContractDeploy({ contract_name: name, source_code: contract(name), fee: 0, clarity_version: CLARITY });
  }
  builder
    .addContractDeploy({ contract_name: POOL, source_code: contract(POOL), fee: 0, clarity_version: CLARITY })
    .addContractDeploy({ contract_name: BRIDGE, source_code: contract(BRIDGE), fee: 0, clarity_version: CLARITY })
    .addContractDeploy({ contract_name: DAO, source_code: contract(DAO), fee: 0, clarity_version: CLARITY });

  // The whitelisting transaction, only when the chain has not done it: the
  // bond admin creates the bond and puts the pool on its allowlist. pox-5 keys
  // an allowance on the staker's principal and only ever inserts it here, so a
  // pool missing from this list can never stake into this bond -- there is no
  // adding it later. On the genesis bond that has happened for real.
  if (!bond.exists) {
    builder.withSender(admin).addContractCall({
      contract_id: POX5,
      function_name: "setup-bond",
      function_args: [
        Cl.uint(bond.index),
        Cl.uint(BOND.targetRate),
        Cl.uint(BOND.stxValueRatio),
        Cl.uint(BOND.minUstxRatio),
        Cl.bufferFromHex("00"), // early-unlock script; the sBTC path ignores it
        Cl.list([
          Cl.tuple({
            staker: Cl.principal(poolId),
            "max-sats": Cl.uint(BOND.allowanceSats),
          }),
        ]),
      ],
      fee: 0,
    });
  }

  return (
    builder
      .addReads([{ EvalReadonly: [DEPLOYER, "", POX5, `(get-bond-allowance u${bond.index} '${poolId})`] }])

      .withSender(DEPLOYER)
      .addContractCall({
        contract_id: poolId,
        function_name: "initialize",
        function_args: [Cl.principal(managerId), Cl.principal(DEPLOYER)],
        fee: 0,
      })
      .addContractCall({
        contract_id: poolId,
        function_name: "update-operator",
        function_args: [Cl.principal(`${DEPLOYER}.${DAO}`), Cl.bool(true)],
        fee: 0,
      })
      // No index and no allocation: the call takes neither. It walks to the
      // earliest period pox-5 has allowlisted this pool for, so what is being
      // simulated here is whether the grant and the timing line up at all.
      .addContractCall({
        contract_id: poolId,
        function_name: "bind-next-bond",
        function_args: [],
        fee: 0,
      })
      .addEvalCode(poolId, "(find-next-bond)")
      .addEvalCode(poolId, "(get-bound-bond)")
  );
}

/** Give the member the sats and the STX their deposit needs. */
function fund(builder, { member, sats }) {
  return builder
    // sBTC is minted by evaluating inside the token contract, which is the
    // only way to conjure it: `protocol-mint` is gated to the sBTC protocol.
    .addEvalCode(SBTC, `(ft-mint? sbtc-token u${sats} '${member})`)
    .withSender(FUNDER)
    .addSTXTransfer({ recipient: member, amount: MEMBER_USTX, fee: 0 });
}

async function main() {
  const scenario = process.argv[2] ?? "genesis";
  if (!["genesis", "bridge"].includes(scenario)) {
    console.error("usage: node scripts/simulate-mainnet.mjs <genesis|bridge>");
    process.exit(1);
  }

  const info = await (await fetch(`${API}/v2/info`)).json();
  // Pin a few blocks behind the tip. The very newest block is not indexed yet
  // -- both the block lookup here and stxer's own fail on it -- and stepping
  // back also makes a run reproducible for as long as the chainstate is kept.
  const pinnedHeight = info.stacks_tip_height - SETTLE_LAG;
  // The burn height to count from is the one belonging to the block pinned to,
  // which lags the tip `/v2/info` reports. Counting from the wrong one lands
  // short of the stake window and `stake` returns ERR_TOO_EARLY -- a confusing
  // failure at the very last step.
  const pinned = await (await fetch(`${API}/extended/v2/blocks/${pinnedHeight}`)).json();
  if (typeof pinned.burn_block_height !== "number") {
    throw new Error(`could not read burn height for stacks block ${pinnedHeight}`);
  }
  const bond = await resolveBondIndex();
  const admin = await readBondAdmin();
  const poolId = `${DEPLOYER}.${POOL}`;
  const managerId = MANAGER_ID;
  if (bond.exists && !bond.granted) {
    throw new Error(`bond ${bond.index} is set up and does not allowlist ${poolId}`);
  }

  // The window closes where the prepare phase opens and runs STAKE_WINDOW
  // blocks before that -- the pool's own arithmetic, with pox-5's prepare length.
  const prepare = Number(unwrap(await readPox("get-pox-info")).value?.["prepare-cycle-length"] ?? 100);
  const stakeOpensAt = bond.height - prepare - 288;
  // A couple of blocks inside the window rather than exactly on its edge: the
  // window is 288 wide, so the margin costs nothing and absorbs any further
  // drift between the pinned block and the tip.
  const advance = Math.max(0, stakeOpensAt + 2 - pinned.burn_block_height);

  console.log(`scenario            : ${scenario}
mainnet burn height : ${info.burn_block_height}
mainnet stacks tip  : ${info.stacks_tip_height}
pinned at           : stacks ${pinnedHeight}, burn ${pinned.burn_block_height}
genesis bond        : index ${bond.index}, starts ${bond.height}, cycle ${bond.cycle}
  already set up?   : ${bond.exists ? "yes" : "no -- the simulation creates it"}
  allowlists us?    : ${bond.granted ? "yes" : "no -- the simulation grants it"}
bond admin          : ${admin}
pool                : ${poolId}
signer manager      : ${managerId}
stake window opens  : ${stakeOpensAt}
burn blocks to skip : ${advance}
`);

  if (bond.index !== 0) {
    console.log(
      `NOTE: the bond starting at ${GENESIS_BURN_HEIGHT} is index ${bond.index}, not 0.\n` +
        `      A launch floor (\`min-sats\`) is only accepted on bond 0, so this run\n` +
        `      binds with a floor of zero: the pool starts on whatever turned up.\n`,
    );
  }

  const builder = SimulationBuilder.new({ network: "mainnet" })
    .useBlockHeight(pinnedHeight)
    .pipe((b) => launch(b, { bond, admin, poolId, managerId }))
    .pipe((b) => fund(b, { member: DEPLOYER, sats: MEMBER_SATS }));

  builder.withSender(DEPLOYER);

  if (scenario === "genesis") {
    // Straight in with sBTC in hand.
    builder.addContractCall({
      contract_id: poolId,
      function_name: "deposit",
      function_args: [Cl.uint(MEMBER_SATS)],
      fee: 0,
    });
  } else {
    // In over L1: commit to the address the bitcoin will come from, wait
    // REVEAL_DELAY burn blocks, reveal it, then have the sBTC signers sweep the
    // deposit to the treasury and complete it.
    //
    // The deposit and its parent are built here rather than taken from bitcoin
    // because nothing is broadcast: what `complete-btc-deposit` checks is that
    // the bytes hash to the txid the registry recorded, and the registry entry
    // below is written by this simulation. Real bytes would prove no more.
    const salt = "5a".repeat(32);
    const hashbytes = "a1".repeat(20);
    const script = scriptFor("04", hashbytes); // p2wpkh
    const address = Cl.tuple({
      version: Cl.bufferFromHex("04"),
      hashbytes: Cl.bufferFromHex(hashbytes),
    });
    // The parent pays the member's address; the deposit spends that output.
    const parent = buildTx(
      [{ txid: "de".repeat(32), vout: 0 }],
      [{ value: MEMBER_SATS * 2, script }],
    );
    const tx = buildTx(
      [{ txid: txidOf(parent), vout: 0 }],
      [{ value: MEMBER_SATS, script: scriptFor("05", "ee".repeat(32)) }],
    );
    const txid = txidOf(tx);
    const bridgeId = `${DEPLOYER}.${BRIDGE}`;
    const treasuryId = `${DEPLOYER}.${TREASURY}`;
    builder
      .addReads([{ EvalReadonly: [DEPLOYER, "", bridgeId, `(get-address-digest { version: 0x04, hashbytes: 0x${hashbytes} } 0x${salt})`] }])
      .addContractCall({
        contract_id: bridgeId,
        function_name: "commit-btc-address",
        function_args: [
          Cl.bufferFromHex(addressDigest(script, salt)),
          Cl.uint(MEMBER_SATS),
        ],
        fee: 0,
      })
      .addAdvanceBlocks({ bitcoin_blocks: REVEAL_DELAY, stacks_blocks_per_bitcoin: 1 })
      .addContractCall({
        contract_id: bridgeId,
        function_name: "reveal-btc-address",
        function_args: [address, Cl.bufferFromHex(salt)],
        fee: 0,
      })
      // Stand in for the sBTC signers sweeping the bitcoin to the treasury.
      //
      // Two writes, because the bridge checks both halves of what a real sweep
      // does: the sBTC has to exist in the treasury, and the registry has to
      // record the deposit as completed. Minting alone leaves
      // `complete-btc-deposit` returning ERR_DEPOSIT_NOT_SWEPT (u304) --
      // `get-swept-deposit` reads sbtc-registry, not the token.
      //
      // Done by evaluating inside each contract rather than by calling
      // `complete-deposit-wrapper`: that path is gated to the current signer
      // principal and wants a burn header for a height that, after
      // AdvanceBlocks, exists only inside this simulation.
      //
      // `sweep-burn-height` has to be *after* the reveal, which is the rule
      // that stops an address being claimed once its deposit is already swept.
      .addEvalCode(SBTC, `(ft-mint? sbtc-token u${MEMBER_SATS} '${treasuryId})`)
      .addEvalCode(
        SBTC_REGISTRY,
        `(map-set completed-deposits { txid: 0x${txid}, vout-index: u0 } {
           amount: u${MEMBER_SATS},
           recipient: '${treasuryId},
           sweep-txid: 0x${"cd".repeat(32)},
           sweep-burn-hash: 0x${"ef".repeat(32)},
           sweep-burn-height: u${pinned.burn_block_height + REVEAL_DELAY + 1},
         })`,
      )
      .addContractCall({
        contract_id: bridgeId,
        function_name: "complete-btc-deposit",
        function_args: [
          Cl.bufferFromHex(txid),
          Cl.uint(0),
          Cl.bufferFromHex(tx),
          Cl.list([Cl.bufferFromHex(parent)]),
        ],
        fee: 0,
      });
  }

  builder
    .addEvalCode(poolId, "(get-pool)")
    .addEvalCode(poolId, "(get-stake-preview)")
    // Forward to the stake window, then stake -- which is the call that
    // registers the pool for the bond with pox-5.
    .addAdvanceBlocks({ bitcoin_blocks: advance, stacks_blocks_per_bitcoin: 1 })
    .addContractCall({
      contract_id: poolId,
      function_name: "stake",
      function_args: [Cl.principal(managerId)],
      fee: 0,
    })
    .addReads([
      { EvalReadonly: [DEPLOYER, "", POX5, `(get-total-sbtc-staked-for-bond u${bond.index})`] },
      { EvalReadonly: [DEPLOYER, "", POX5, `(get-bond-membership '${poolId})`] },
    ])
    .addEvalCode(poolId, "(get-live-epoch)");

  const id = await builder.run();
  const url = `https://stxer.xyz/simulations/mainnet/${id}`;
  console.log(`\nsimulation: ${url}\n`);
  await report(id);
  console.log(`\nsimulation: ${url}`);
}

/**
 * Read the run back and say what each step did.
 *
 * Worth the extra call: a step can fail and still be reported as an `Ok`
 * transaction -- a deploy whose analysis failed comes back as `(err none)`
 * with the reason only in `vm_error`. Printing the URL alone would hide that.
 */
async function report(id) {
  let result;
  for (let attempt = 0; ; attempt++) {
    try {
      result = await getSimulationResult(id);
      break;
    } catch (error) {
      if (attempt >= 10) throw error;
      await new Promise((r) => setTimeout(r, 3000));
    }
  }

  const decode = (hex) => {
    try {
      return cvToString(hexToCV(`0x${String(hex).replace(/^0x/, "")}`));
    } catch {
      return String(hex);
    }
  };

  let failures = 0;
  result.steps.forEach((step, i) => {
    const kind = Object.keys(step.Result ?? {})[0] ?? Object.keys(step)[0];
    const body = step.Result?.[kind];
    const inner = body?.Ok ?? body?.Err ?? body;
    const vmError = inner?.vm_error ?? (body?.Err ? JSON.stringify(body.Err) : null);

    let shown;
    if (kind === "AdvanceBlocks") {
      const last = Array.isArray(inner) ? inner[inner.length - 1] : null;
      shown = `${Array.isArray(inner) ? inner.length : 0} bitcoin blocks -> burn ${last?.burn_height ?? "?"}`;
    } else if (Array.isArray(inner)) {
      shown = inner.map((r) => decode(r?.Ok ?? r)).join(", ");
    } else if (inner?.result !== undefined) {
      shown = decode(inner.result);
    } else if (typeof inner === "string") {
      shown = decode(inner);
    } else {
      shown = kind;
    }

    const bad = Boolean(vmError) || String(shown).startsWith("(err");
    if (bad) failures++;
    console.log(
      `${bad ? "x" : " "} ${String(i).padStart(2)} ${kind.padEnd(14)} ${String(shown).slice(0, 150)}` +
        (vmError ? `\n      ${vmError}` : ""),
    );
  });

  console.log(
    failures === 0
      ? `\nall ${result.steps.length} steps clean`
      : `\n${failures} of ${result.steps.length} steps failed`,
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
