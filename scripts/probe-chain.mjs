// Re-read a network: burn height, the bonds pox-5 has set up, whose pool names
// they allowlist, and where each published pool stands. This is what the
// tables in TESTNET.md and MAINNET.md are gathered from; run it before acting
// on any height written there.
//
//   node scripts/probe-chain.mjs testnet                 # vault-1, vault-2, vault-3
//   node scripts/probe-chain.mjs testnet vault-3 vault-4  # names to ask about
//   node scripts/probe-chain.mjs mainnet                 # bond-staker
//
// Everything is a read-only call through the public API; nothing is signed.
import { cvToJSON, fetchCallReadOnlyFunction, principalCV, uintCV } from "@stacks/transactions";

// The same key on both networks; the address differs only in its version byte.
const NETWORKS = {
  testnet: {
    api: "https://api.testnet.hiro.so",
    deployer: "STFCGF789WX1B737VQYAQ6BG3QYVMJGPDJN4TJFM",
    pox: "ST000000000000000000002AMW42H",
    names: ["vault-1", "vault-2", "vault-3"],
  },
  mainnet: {
    api: "https://api.hiro.so",
    deployer: "SPFCGF789WX1B737VQYAQ6BG3QYVMJGPDKRKYK00",
    pox: "SP000000000000000000002Q6VF78",
    names: ["esbee-dao-bond-staker-1"],
  },
};
// How far past the current height to look for bonds. pox-5 sets a bond up at
// most two cycles ahead, so anything beyond the next few is `none` anyway.
const LOOKAHEAD = 6;

const [network, ...names] = process.argv.slice(2).filter((a) => a !== "--");
if (!NETWORKS[network]) {
  console.error(`usage: node scripts/probe-chain.mjs <${Object.keys(NETWORKS).join("|")}> [name ...]`);
  process.exit(1);
}
const { api: API, deployer: DEPLOYER, pox: boot } = NETWORKS[network];
const POX = { contractAddress: boot, contractName: "pox-5" };
if (names.length === 0) names.push(...NETWORKS[network].names);

const call = async (contract, functionName, functionArgs = []) =>
  cvToJSON(
    await fetchCallReadOnlyFunction({
      ...contract,
      functionName,
      functionArgs,
      network,
      senderAddress: DEPLOYER,
      client: { baseUrl: API },
    }),
  );
// `cvToJSON` nests every value under `.value`; these unwrap the shapes used here.
const num = (j) => Number(j.value);
const opt = (j) => (j.value === null ? null : j.value);
const tuple = (j) =>
  Object.fromEntries(Object.entries(j.value).map(([k, v]) => [k, v.value?.value ?? v.value]));

const info = await (await fetch(`${API}/v2/info`)).json();
const burn = info.burn_block_height;
const pox = tuple((await call(POX, "get-pox-info")).value);
const cycleLength = Number(pox["reward-cycle-length"]);
const prepare = Number(pox["prepare-cycle-length"]);
console.log(`burn height ${burn}  reward cycle ${pox["reward-cycle-id"]}  cycle ${cycleLength}  prepare ${prepare}`);

// The pool's own arithmetic, so the deadline printed is the one
// `bind-next-bond` will enforce: notice, then the stake window, then the
// prepare phase, all before the bond starts.
const BIND_NOTICE = 576;
const STAKE_WINDOW = 288;

const first = num(await call(POX, "bond-period-to-burn-height", [uintCV(0)]));
const second = num(await call(POX, "bond-period-to-burn-height", [uintCV(1)]));
const spacing = second - first;
const current = Math.floor((burn - first) / spacing);

console.log(`\nbonds (spaced ${spacing} blocks; setup-bond opens ${2 * cycleLength} blocks before a start)`);
for (let index = Math.max(0, current - 1); index <= current + LOOKAHEAD; index++) {
  const start = first + index * spacing;
  const bond = opt(await call(POX, "get-protocol-bond", [uintCV(index)]));
  const staked = num(await call(POX, "get-total-sbtc-staked-for-bond", [uintCV(index)]));
  const grants = [];
  for (const name of names) {
    const allowance = opt(
      await call(POX, "get-bond-allowance", [uintCV(index), principalCV(`${DEPLOYER}.${name}`)]),
    );
    if (allowance !== null) grants.push(`${name}: ${allowance.value} sats`);
  }
  const stakeOpens = start - prepare - STAKE_WINDOW;
  const bindBy = stakeOpens - BIND_NOTICE;
  const when =
    start <= burn ? "started" : bindBy <= burn ? "bind deadline passed" : `bind by ${bindBy}, stake ${stakeOpens}..${start - prepare - 1}`;
  console.log(
    `  ${String(index).padStart(2)}  start ${start}  ${bond ? "set up" : "not set up"}  ` +
      `staked ${staked} sats  grants [${grants.join(", ")}]  ${when}`,
  );
}

console.log("\npools");
for (const name of names) {
  const contract = { contractAddress: DEPLOYER, contractName: name };
  const res = await fetch(`${API}/v2/contracts/interface/${DEPLOYER}/${name}`);
  if (!res.ok) {
    console.log(`  ${name}: not published`);
    continue;
  }
  const pool = tuple(await call(contract, "get-pool"));
  const bound = tuple(await call(contract, "get-bound-bond"));
  const config = tuple(await call(contract, "get-config"));
  const membership = opt(await call(POX, "get-bond-membership", [principalCV(`${DEPLOYER}.${name}`)]));
  console.log(
    `  ${name}: epochs ${config["epoch-count"]}, finished ${config.finished}, ` +
      `bound to bond ${bound.bound ? bound["bond-index"] : "none"}` +
      (bound.bound ? ` (start ${bound["start-height"]}, stakeable ${bound.stakeable})` : "") +
      `, queued ${pool["queued-sats"]} sats / ${pool["queued-ustx"]} uSTX, ` +
      `bonded ${pool["bonded-sats"]} sats, pox-5 membership ${membership ? "yes" : "none"}`,
  );
}
