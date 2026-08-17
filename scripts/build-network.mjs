// Emit the contracts for a given network.
//
// A Clarity `contract-call?` target is a literal, so the sBTC protocol's
// address is fixed at deploy time. It is the same hash on every network but a
// different version byte, so the text differs:
//
//   mainnet  SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4
//   testnet  SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1
//
// The source in `contracts/` is the mainnet form -- that is what the tests run
// against, since simnet mirrors mainnet's sBTC deployment. This writes the
// other flavours out to `build/<network>/`.
//
//   node scripts/build-network.mjs testnet
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SBTC = {
  mainnet: "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4",
  testnet: "SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1",
};

const network = process.argv[2];
if (!SBTC[network]) {
  console.error(`usage: node scripts/build-network.mjs <${Object.keys(SBTC).join("|")}>`);
  process.exit(1);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const from = join(root, "contracts");
const to = join(root, "build", network);
mkdirSync(to, { recursive: true });

let swapped = 0;
for (const file of readdirSync(from).filter((f) => f.endsWith(".clar"))) {
  const source = readFileSync(join(from, file), "utf8");
  const out = source.replaceAll(SBTC.mainnet, SBTC[network]);
  swapped += source.split(SBTC.mainnet).length - 1;
  writeFileSync(join(to, file), out);
}
console.log(`wrote ${to} (${swapped} sBTC references set to ${SBTC[network]})`);
