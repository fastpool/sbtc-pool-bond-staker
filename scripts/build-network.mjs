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
// The contracts' own names are rewritten for the same reason, and they are
// per-network rather than fixed.
//
// The pool's name is forced by the protocol. pox-5 keys a bond's allowlist on
// the staker's *principal*, and a grant is only ever inserted by `setup-bond`
// -- so a pool published under a name no grant mentions can never stake, and
// the pool is called whatever its grant spells:
//
//   mainnet   the genesis bond's allowlist names `<deployer>.esbee-dao-bond-staker-1`
//   testnet   the grants so far spell `vault-1` and `vault-2`, and both are
//             published -- `vault-1` is the pool before members could unstake
//             mid-term (kept under `v1/`), `vault-2` the one before binding
//             became permissionless; neither ever staked. The third pool is
//             `vault-3`, and its grant is a request to the bond admin.
//
// Its three siblings are forced by something duller: a contract name can never
// be reused at an address, and on testnet `bond-treasury`, `bond-bridge` and
// `esbee-dao` were published alongside `vault-1`, their `-2` copies alongside
// `vault-2`. Each is wired to its pool by a constant that cannot be re-pointed,
// so a new pool needs three of its own. They take the pool's generation number
// as a suffix -- `-1` on mainnet, `-3` on testnet -- and nothing about them
// changes but the name. See MAINNET.md and TESTNET.md.
//
//   node scripts/build-network.mjs mainnet    -> esbee-dao-bond-staker-1.clar, bond-treasury-1.clar, ...
//   node scripts/build-network.mjs testnet    -> vault-3.clar, bond-treasury-3.clar, ...
//   node scripts/build-network.mjs testnet --staker-name vault-4 --suffix -4
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Simnet-only code, dropped on the way out.
//
// `contracts/` carries the fuzzing surface -- the invariants, the properties
// and the pox-5 stand-ins -- each form marked `;; #[env(simnet)]`. Clarinet
// understands that annotation and strips it from any publish source, and
// `clarinet check` compiles the project both with and without it. This does
// the same thing here, so what lands in `build/<network>/` is the deployable
// contract and nothing else: the file that is checked, sized for its fee, and
// read by anyone auditing what was published is already free of it, rather
// than relying on the publisher to strip it.
const ANNOTATION = /^[ \t]*;;[ \t]*#\[env\(simnet\)\][ \t]*\r?\n/gm;

// The index just past the `)` closing the form that opens at `i`. Comments and
// strings are skipped so a `)` inside either cannot end the form early.
const formEnd = (source, i) => {
  let depth = 0;
  for (; i < source.length; i++) {
    const c = source[i];
    if (c === ";") {
      while (i < source.length && source[i] !== "\n") i++;
    } else if (c === '"') {
      for (i++; i < source.length && source[i] !== '"'; i++) {
        if (source[i] === "\\") i++;
      }
    } else if (c === "(") {
      depth++;
    } else if (c === ")" && --depth === 0) {
      return i + 1;
    }
  }
  throw new Error("unbalanced form after #[env(simnet)]");
};

// A form's doc comment belongs to the form. Walk back over the comment lines
// sitting directly above the annotation, stopping at a blank line or at any
// code -- so a comment block deliberately separated by a blank line survives,
// and a doc comment written against a stripped function does not outlive it.
const commentStart = (source, index) => {
  while (index > 0 && source[index - 1] === "\n") {
    const lineStart = source.lastIndexOf("\n", index - 2) + 1;
    if (!source.slice(lineStart, index - 1).trimStart().startsWith(";;")) break;
    index = lineStart;
  }
  return index;
};

const stripEnvSimnet = (source, file) => {
  let out = "";
  let cursor = 0;
  ANNOTATION.lastIndex = 0;
  for (let m; (m = ANNOTATION.exec(source)) !== null; ) {
    if (m.index < cursor) continue;
    out += source.slice(cursor, Math.max(cursor, commentStart(source, m.index)));
    let i = m.index + m[0].length;
    // whitespace or a plain comment may sit between the annotation and its form
    while (i < source.length && source[i] !== "(") {
      if (source[i] === ";") while (i < source.length && source[i] !== "\n") i++;
      i++;
    }
    if (i >= source.length) {
      console.error(`${file}: #[env(simnet)] with no form after it`);
      process.exit(1);
    }
    i = formEnd(source, i);
    while (source[i] === "\n" || source[i] === "\r") i++;
    cursor = i;
  }
  return out + source.slice(cursor);
};

const SOURCE = {
  sbtc: "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4",
  pox5: "ST000000000000000000002AMW42H",
};

// The contracts as they are named in `contracts/`, and how they refer to each
// other. The leading dot is what makes a token a reference: the prose comments
// say `bond-staker` too, and those are not.
const STAKER = "bond-staker";
const SIBLINGS = ["bond-treasury", "bond-bridge", "esbee-dao"];

// `staker` is the pool's published name; `suffix` is appended to each of the
// three siblings.
const TARGETS = {
  mainnet: {
    sbtc: SOURCE.sbtc,
    pox5: "SP000000000000000000002Q6VF78",
    staker: "esbee-dao-bond-staker-1",
    suffix: "-1",
  },
  testnet: {
    sbtc: "SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1",
    pox5: SOURCE.pox5,
    staker: "vault-3",
    suffix: "-3",
  },
};

const usage =
  `usage: node scripts/build-network.mjs <${Object.keys(TARGETS).join("|")}>` +
  " [--staker-name <name>] [--suffix <suffix>]";

// Clarity's own rule for a contract name. A name the chain would reject is
// better caught here than by a publish that has already paid its fee.
const NAME = /^[a-zA-Z]([a-zA-Z0-9]|[-_]){0,39}$/;

// A bare `--` is dropped: pnpm forwards the separator itself, so the documented
// `pnpm run build:testnet -- --staker-name vault-4` arrives with it still in.
const [network, ...rest] = process.argv.slice(2).filter((a) => a !== "--");
if (!TARGETS[network]) {
  console.error(usage);
  process.exit(1);
}
const target = TARGETS[network];

// `--staker-name` overrides the network's own name, for the case where a grant
// is issued against something else again; `--suffix` moves the siblings along
// with it, since the names the last generation took are spent too. Neither is
// needed for the current generation, which is the network's default.
let staker = target.staker;
let suffix = target.suffix;
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === "--staker-name") {
    staker = rest[++i];
    if (!NAME.test(staker ?? "")) {
      console.error(`not a valid contract name: ${staker ?? "(missing)"}\n${usage}`);
      process.exit(1);
    }
  } else if (rest[i] === "--suffix") {
    suffix = rest[++i];
    // What a suffix may be is what the names it lands on may end in.
    if (!/^[a-zA-Z0-9_-]{0,20}$/.test(suffix ?? "\0")) {
      console.error(`not a valid name suffix: ${suffix ?? "(missing)"}\n${usage}`);
      process.exit(1);
    }
  } else {
    console.error(`unexpected argument: ${rest[i]}\n${usage}`);
    process.exit(1);
  }
}

// Source name -> published name, for every contract that changes.
const renames = new Map();
if (staker !== STAKER) renames.set(STAKER, staker);
for (const name of SIBLINGS) {
  const published = `${name}${suffix}`;
  if (published === name) continue;
  if (!NAME.test(published)) {
    console.error(`not a valid contract name: ${published}`);
    process.exit(1);
  }
  renames.set(name, published);
}

// A reference is `.<name>` not run on into a longer name -- without the guard,
// rewriting `.bond-bridge` would match inside `.bond-bridge-2` and a second
// pass would suffix it twice. Clarity contract names are [a-zA-Z0-9_-].
const reference = (name) => new RegExp(`\\.${name}(?![a-zA-Z0-9_-])`, "g");

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const from = join(root, "contracts");
const to = join(root, "build", network);
// Emptied rather than written over: a previous run under a different
// `--staker-name` would otherwise leave its own copy of the pool behind, and
// both the checks below and any deployment plan would read it as current.
rmSync(to, { recursive: true, force: true });
mkdirSync(to, { recursive: true });

const counts = { sbtc: 0, pox5: 0, names: 0, stripped: 0 };
for (const file of readdirSync(from).filter((f) => f.endsWith(".clar"))) {
  const raw = readFileSync(join(from, file), "utf8");
  let source = stripEnvSimnet(raw, file);
  counts.stripped += raw.length - source.length;
  for (const key of ["sbtc", "pox5"]) {
    if (target[key] === SOURCE[key]) continue;
    counts[key] += source.split(SOURCE[key]).length - 1;
    source = source.replaceAll(SOURCE[key], target[key]);
  }
  for (const [name, published] of renames) {
    counts.names += (source.match(reference(name)) ?? []).length;
    source = source.replace(reference(name), `.${published}`);
  }
  const base = file.replace(/\.clar$/, "");
  writeFileSync(join(to, `${renames.get(base) ?? base}.clar`), source);
}

// A protocol address left on the source network would point at a contract that
// does not exist there, and only show up at deploy time. A reference left on an
// old contract name is the same failure, one contract closer to home.
const built = readdirSync(to).map((f) => readFileSync(join(to, f), "utf8"));
const count = (test) => built.reduce((n, s) => n + (s.match(test)?.length ?? 0), 0);
const leftovers = [
  ...Object.entries(SOURCE)
    .filter(([key, token]) => target[key] !== token)
    .map(([key, token]) => [key, new RegExp(token, "g")]),
  ...[...renames.keys()].map((name) => [name, reference(name)]),
];
for (const [key, test] of leftovers) {
  const left = count(test);
  if (left > 0) {
    console.error(`${left} ${key} reference(s) left unrewritten`);
    process.exit(1);
  }
}

const published = [...renames].map(([from, to]) => `${from} -> ${to}`).join(", ");
console.log(
  `wrote ${to}: ${counts.stripped} bytes of #[env(simnet)] code stripped, ` +
    `${counts.sbtc} sBTC and ${counts.pox5} pox-5 references rewritten` +
    (renames.size === 0
      ? ""
      : `, ${counts.names} contract reference(s) renamed (${published})`),
);
