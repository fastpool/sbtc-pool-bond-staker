// Refresh the vendored signer managers under `tests/contracts/`.
//
// pox-5 will not let a staker register for a bond except through a registered
// signer manager, so this project cannot test its pool without one -- and it
// needs two, because `bond-staker` vets managers by code hash and can be moved
// between them.
//
// Both are vendored rather than referenced out of a sibling checkout. That
// dependency broke once already: the v1 manager was renamed upstream and the
// whole suite stopped starting, with the real cause buried inside a worker the
// test runner never printed. A copy in the tree is a copy that cannot move
// underneath a checkout.
//
//   fastpool-max500-signer-manager   the manager this pool stakes through,
//                                    taken from mainnet -- the published
//                                    bytes, with the pox-5 boot address
//                                    rewritten for simnet
//   fastpool-signer-manager          v1, the alternate to move to. Already
//                                    simnet-flavoured; copied verbatim
//
//   node scripts/build-test-managers.mjs           rewrite both from source
//   node scripts/build-test-managers.mjs --check   verify, change nothing
//
// `--check` is what `pretest` runs. It is advisory: a checkout with no network
// and no sibling still tests, against what is committed.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const OUT_DIR = join(root, "tests", "contracts");

// A Clarity `contract-call?` target is fixed at deploy time and cannot be
// configured, so the boot address is a literal at every call site and the only
// way to move a contract between networks is to rewrite it. This is the same
// substitution `build-network.mjs` makes, in the other direction.
const MAINNET_BOOT = "SP000000000000000000002Q6VF78";
const SIMNET_BOOT = "ST000000000000000000002AMW42H";

// Published mainnet source is the truth for the manager the pool will actually
// use. Vendoring anything else would test code nobody runs.
const ONCHAIN = {
  address: "SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4",
  name: "fastpool-max500-signer-manager",
  api: "https://api.hiro.so",
};

// v1 has no on-chain instance to copy, so it comes from the sibling project.
// Optional: without that checkout the committed copy stands.
const SIBLING = join(
  root,
  "..",
  "fastpool-pox-5",
  "contracts",
  "signer-manager-accounting-multi.clar",
);

const check = process.argv.includes("--check");

// The vendored contracts open with comments of their own, so the boundary
// between this script's header and the source it wrapped has to be marked
// rather than guessed at.
const MARKER = ";; " + "-".repeat(70);

/** Split a vendored file into [header, source] on the marker line. */
const splitHeader = (text) => {
  const at = text.indexOf(MARKER + "\n");
  return at === -1 ? [null, text] : [text.slice(0, at + MARKER.length + 1), text.slice(at + MARKER.length + 1)];
};

async function fetchOnchain() {
  const url = `${ONCHAIN.api}/v2/contracts/source/${ONCHAIN.address}/${ONCHAIN.name}?proof=0`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url} -> ${response.status}`);
  const { source, publish_height } = await response.json();
  return { source: source.replace(/\r\n/g, "\n"), publishHeight: publish_height };
}

function header({ publishHeight, rewrites }) {
  return `\
;; VENDORED, DO NOT EDIT BY HAND.
;;
;; Mainnet \`${ONCHAIN.address}.${ONCHAIN.name}\`,
;; published at block ${publishHeight} -- the signer manager this pool
;; is built to stake through, and so the one its tests stake through.
;;
;; Exactly one mechanical change from the published source: the ${rewrites} occurrences
;; of the pox-5 boot address \`${MAINNET_BOOT}\` are rewritten
;; to \`${SIMNET_BOOT}\`, which is where simnet boots it. That is
;; the same rewrite \`scripts/build-network.mjs\` makes in the other direction
;; for this project's own contracts, and for the same reason -- a Clarity
;; \`contract-call?\` target is fixed at deploy time and cannot be configured.
;;
;; \`node scripts/build-test-managers.mjs\` refetches the published source and
;; rewrites it again; \`--check\` verifies this file still matches the chain
;; without touching it.
${MARKER}
`;
}

/** Write `body` under `head`, or -- under --check -- report whether it differs. */
function emit(name, head, body) {
  const path = join(OUT_DIR, name);
  const next = head + body;
  const current = existsSync(path) ? readFileSync(path, "utf8") : null;

  if (current === next) {
    console.log(`  ${name}: up to date`);
    return true;
  }
  if (check) {
    // Compare the contract itself, not the header: a re-publish is a finding,
    // a reworded comment is not.
    const drifted = current === null || splitHeader(current)[1] !== body;
    console.log(
      `  ${name}: ${drifted ? "DIFFERS from source" : "header differs only"}`,
    );
    return !drifted;
  }
  writeFileSync(path, next);
  console.log(`  ${name}: written`);
  return true;
}

let ok = true;

try {
  const { source, publishHeight } = await fetchOnchain();
  const rewrites = source.split(MAINNET_BOOT).length - 1;
  if (rewrites === 0) throw new Error("no pox-5 boot address in the published source");
  ok =
    emit(
      "fastpool-max500-signer-manager.clar",
      header({ publishHeight, rewrites }),
      source.replaceAll(MAINNET_BOOT, SIMNET_BOOT),
    ) && ok;
} catch (error) {
  // Offline, or the API is down. The committed copy is what tests run against
  // either way, so this is a warning rather than a failure.
  console.log(`  fastpool-max500-signer-manager.clar: not verified (${error.message})`);
}

if (existsSync(SIBLING)) {
  const name = "fastpool-signer-manager.clar";
  // v1's header is prose about where it came from and why, not something this
  // script generates, so it is carried across rather than rewritten.
  const head = splitHeader(readFileSync(join(OUT_DIR, name), "utf8"))[0];
  ok = emit(name, head, readFileSync(SIBLING, "utf8")) && ok;
} else {
  console.log(`  fastpool-signer-manager.clar: not verified (no sibling checkout)`);
}

// Never fail the run: this guards against silent drift, and a stale copy is a
// thing to go and look at rather than a reason to refuse to test.
if (!ok && check) {
  console.log(
    "\n  A vendored manager no longer matches its source. Run this script\n" +
      "  without --check to update it, and read the diff before committing.",
  );
}
