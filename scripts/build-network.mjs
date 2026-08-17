// Emit the contracts for a given network.
//
// Two protocol addresses are baked into the source, because a Clarity
// `contract-call?` target is fixed at deploy time and cannot be configured:
//
//   sBTC   the same hash on every network, a different version byte
//   pox-5  the boot address, whose text differs between mainnet and testnet
//
// Both are plain literals at every call site. A constant would work for the
// calls made from public and private functions, but not from read-only ones --
// a read-only function may not call through a constant -- and half the
// read-only API here reaches pox-5 for reward-cycle arithmetic. Rather than
// split the source between two mechanisms, everything is a literal and this
// script rewrites the addresses.
//
// `contracts/` holds the simnet flavour, which is what the tests run against:
// mainnet-encoded sBTC, since simnet mirrors mainnet's deployment, and the
// testnet-encoded boot address.
//
//   node scripts/build-network.mjs testnet
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SOURCE = {
  sbtc: "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4",
  pox5: "ST000000000000000000002AMW42H",
};

const TARGETS = {
  mainnet: { sbtc: SOURCE.sbtc, pox5: "SP000000000000000000002Q6VF78" },
  testnet: { sbtc: "SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1", pox5: SOURCE.pox5 },
};

const network = process.argv[2];
if (!TARGETS[network]) {
  console.error(`usage: node scripts/build-network.mjs <${Object.keys(TARGETS).join("|")}>`);
  process.exit(1);
}
const target = TARGETS[network];

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const from = join(root, "contracts");
const to = join(root, "build", network);
mkdirSync(to, { recursive: true });

const counts = { sbtc: 0, pox5: 0 };
for (const file of readdirSync(from).filter((f) => f.endsWith(".clar"))) {
  let source = readFileSync(join(from, file), "utf8");
  for (const key of ["sbtc", "pox5"]) {
    if (target[key] === SOURCE[key]) continue;
    counts[key] += source.split(SOURCE[key]).length - 1;
    source = source.replaceAll(SOURCE[key], target[key]);
  }
  writeFileSync(join(to, file), source);
}

// A protocol address left on the source network would point at a contract that
// does not exist there, and only show up at deploy time.
for (const key of ["sbtc", "pox5"]) {
  if (target[key] === SOURCE[key]) continue;
  const left = readdirSync(to).reduce(
    (n, f) => n + readFileSync(join(to, f), "utf8").split(SOURCE[key]).length - 1,
    0,
  );
  if (left > 0) {
    console.error(`${left} ${key} reference(s) left on the source network`);
    process.exit(1);
  }
}

console.log(
  `wrote ${to}: ${counts.sbtc} sBTC and ${counts.pox5} pox-5 references rewritten`,
);
