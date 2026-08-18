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
// The pool's own name is rewritten for the same reason, and it is per-network
// rather than fixed. pox-5 keys a bond's allowlist on the staker's *principal*,
// and a grant is only ever inserted by `setup-bond` -- so a contract published
// under a name no grant mentions can never stake. On testnet the grants name
// `<deployer>.vault-1`, so `vault-1` is simply what the pool is called there.
// Nothing in the source changes; `.bond-staker` is a local reference in three
// sibling contracts, and this rewrites those alongside the file name.
//
//   node scripts/build-network.mjs testnet                     -> vault-1.clar
//   node scripts/build-network.mjs mainnet                     -> bond-staker.clar
//   node scripts/build-network.mjs testnet --staker-name vault-3
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SOURCE = {
  sbtc: "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4",
  pox5: "ST000000000000000000002AMW42H",
};

// The contract as it is named in `contracts/`, and how its siblings refer to
// it. The leading dot is what makes the token unambiguous: the prose comments
// say `bond-staker` too, and those are not references.
const STAKER = "bond-staker";

// The name each network publishes the pool under. On testnet the allowlist
// grants name `<deployer>.vault-1`, so that is what the pool has to be called
// there -- not a variant to remember on the command line, but the name.
const TARGETS = {
  mainnet: {
    sbtc: SOURCE.sbtc,
    pox5: "SP000000000000000000002Q6VF78",
    staker: STAKER,
  },
  testnet: {
    sbtc: "SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1",
    pox5: SOURCE.pox5,
    staker: "vault-1",
  },
};

const usage =
  `usage: node scripts/build-network.mjs <${Object.keys(TARGETS).join("|")}> [--staker-name <name>]`;

// A bare `--` is dropped: pnpm forwards the separator itself, so the documented
// `pnpm run build:testnet -- --staker-name vault-1` arrives with it still in.
const [network, ...rest] = process.argv.slice(2).filter((a) => a !== "--");
if (!TARGETS[network]) {
  console.error(usage);
  process.exit(1);
}
const target = TARGETS[network];

// `--staker-name` overrides the network's own name, for the case where a grant
// is issued against something else again.
let staker = target.staker;
for (let i = 0; i < rest.length; i++) {
  if (rest[i] !== "--staker-name") {
    console.error(`unexpected argument: ${rest[i]}\n${usage}`);
    process.exit(1);
  }
  staker = rest[++i];
  // Clarity's own rule for a contract name. A name the chain would reject is
  // better caught here than by a publish that has already paid its fee.
  if (!/^[a-zA-Z]([a-zA-Z0-9]|[-_]){0,39}$/.test(staker ?? "")) {
    console.error(`not a valid contract name: ${staker ?? "(missing)"}\n${usage}`);
    process.exit(1);
  }
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const from = join(root, "contracts");
const to = join(root, "build", network);
// Emptied rather than written over: a previous run under a different
// `--staker-name` would otherwise leave its own copy of the pool behind, and
// both the checks below and any deployment plan would read it as current.
rmSync(to, { recursive: true, force: true });
mkdirSync(to, { recursive: true });

const counts = { sbtc: 0, pox5: 0, staker: 0 };
for (const file of readdirSync(from).filter((f) => f.endsWith(".clar"))) {
  let source = readFileSync(join(from, file), "utf8");
  for (const key of ["sbtc", "pox5"]) {
    if (target[key] === SOURCE[key]) continue;
    counts[key] += source.split(SOURCE[key]).length - 1;
    source = source.replaceAll(SOURCE[key], target[key]);
  }
  if (staker !== STAKER) {
    counts.staker += source.split(`.${STAKER}`).length - 1;
    source = source.replaceAll(`.${STAKER}`, `.${staker}`);
  }
  writeFileSync(join(to, file === `${STAKER}.clar` ? `${staker}.clar` : file), source);
}

// A protocol address left on the source network would point at a contract that
// does not exist there, and only show up at deploy time. A reference left on
// the old pool name is the same failure, one contract closer to home.
const leftovers = { ...SOURCE, ...(staker === STAKER ? {} : { staker: `.${STAKER}` }) };
for (const [key, token] of Object.entries(leftovers)) {
  if (target[key] === token) continue;
  const left = readdirSync(to).reduce(
    (n, f) => n + readFileSync(join(to, f), "utf8").split(token).length - 1,
    0,
  );
  if (left > 0) {
    console.error(`${left} ${key} reference(s) left unrewritten`);
    process.exit(1);
  }
}

console.log(
  `wrote ${to}: ${counts.sbtc} sBTC and ${counts.pox5} pox-5 references rewritten` +
    (staker === STAKER
      ? ""
      : `, ${counts.staker} reference(s) renamed to \`${staker}\` (published as ${staker}.clar)`),
);
