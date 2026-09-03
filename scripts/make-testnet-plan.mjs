// Write a testnet deployment plan: publish the four contracts, initialize the
// pool, and hand the operator seat to the DAO.
//
//   node scripts/make-testnet-plan.mjs ST3YOUR…DEPLOYER [signer-manager]
//   node scripts/make-testnet-plan.mjs ST3YOUR…DEPLOYER --staker-name vault-4 --suffix -4
//
// The deployer address has to be given because it appears in a dozen places and
// a half-substituted plan would deploy under one identity and initialize under
// another. `initialize` only accepts the contract's own deployer, so the two
// must match.
//
// `--staker-name` and `--suffix` override the testnet names, and have to match
// whatever `build-network.mjs` was given: pox-5 keys a bond's allowlist on the
// staker's principal, so publishing under a name no grant mentions leaves a
// pool that can never stake.
//
// Publishes come from build/testnet/, whose sBTC and pox-5 addresses have been
// rewritten for the network -- run `pnpm run build:testnet` first.
import { existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_MANAGER = "ST1B38CGQRPXEMRH7B66VXTS22DQTNMSW4YJJ7QK1.signer-manager";
// What the pool is called on testnet -- the name its allowlist grant has to
// spell -- and what its three siblings carry after their source names, since
// the names the two earlier generations took are spent. `build-network.mjs`
// publishes under the same names by default; the two have to agree or the plan
// points at files that are not there.
const STAKER = "vault-3";
const SUFFIX = "-3";

const usage =
  "usage: node scripts/make-testnet-plan.mjs <deployer-address> [signer-manager]" +
  " [--staker-name <name>] [--suffix <suffix>]\n" +
  "       node scripts/make-testnet-plan.mjs --template";

// The two flags are pulled out first so they may sit anywhere, leaving the two
// positional arguments where they have always been. A bare `--` is dropped:
// pnpm forwards the separator itself when a flag is passed through `pnpm run`.
const argv = process.argv.slice(2).filter((a) => a !== "--");
let staker = STAKER;
let suffix = SUFFIX;
for (let i = argv.length - 1; i >= 0; i--) {
  if (argv[i] === "--staker-name") {
    [staker] = argv.splice(i, 2).slice(1);
    if (!/^[a-zA-Z]([a-zA-Z0-9]|[-_]){0,39}$/.test(staker ?? "")) {
      console.error(`not a valid contract name: ${staker ?? "(missing)"}\n${usage}`);
      process.exit(1);
    }
  } else if (argv[i] === "--suffix") {
    [suffix] = argv.splice(i, 2).slice(1);
    if (!/^[a-zA-Z0-9_-]{0,20}$/.test(suffix ?? "\0")) {
      console.error(`not a valid name suffix: ${suffix ?? "(missing)"}\n${usage}`);
      process.exit(1);
    }
  }
}

const [given, manager = DEFAULT_MANAGER] = argv;

// `--template` writes the same plan with the address left as a placeholder, so
// the file on disk is always a working syntax reference even before anyone has
// a deployer. Clarinet rejects the placeholder, which is the failure we want if
// it is ever applied unedited.
const template = given === "--template";
const deployer = template ? "<DEPLOYER>" : given;

if (!template && !/^S[TN][0-9A-HJKMNP-Z]{38,40}$/.test(deployer ?? "")) {
  console.error(usage);
  process.exit(1);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// Dependency order, which is also the order Clarinet publishes them in: the
// pool calls the treasury, the bridge calls both, and the DAO calls the pool.
// Nothing calls the DAO, so it goes last.
//
// The three siblings carry the same suffix `build:testnet` gave them: a
// contract name cannot be reused at an address, and the two earlier
// deployments took the unsuffixed and the `-2` names.
const DAO = `esbee-dao${suffix}`;
const CONTRACTS = [
  `bond-treasury${suffix}`,
  staker,
  `bond-bridge${suffix}`,
  DAO,
];

for (const name of CONTRACTS) {
  if (!existsSync(join(root, "build", "testnet", `${name}.clar`))) {
    console.error(
      `build/testnet/${name}.clar is missing — run: pnpm run build:testnet` +
        (staker === STAKER && suffix === SUFFIX ? "" : " --") +
        (staker === STAKER ? "" : ` --staker-name ${staker}`) +
        (suffix === SUFFIX ? "" : ` --suffix ${suffix}`),
    );
    process.exit(1);
  }
}

// Fee in uSTX, the way clarinet sizes it: bytes x the fee rate in
// settings/Testnet.toml, with a floor so a small contract still gets mined.
const FEE_RATE = 10;
const fee = (bytes) => Math.max(50_000, bytes * FEE_RATE);

const publish = CONTRACTS.map((name) => {
  const path = `build/testnet/${name}.clar`;
  return `    - transaction-type: contract-publish
      contract-name: ${name}
      expected-sender: ${deployer}
      cost: ${fee(statSync(join(root, path)).size)}
      path: ${path}
      clarity-version: 6`;
}).join("\n");

const header = template
  ? `# TEMPLATE -- regenerate with your own address before applying:
#
#     pnpm run build:testnet
#     pnpm run plan:testnet ST3YOUR…DEPLOYER
#
# Every <DEPLOYER> below has to be the account that publishes the contracts:
# \`initialize\` only accepts the pool's own deployer, so publishing under one
# identity and initializing under another leaves the pool unusable.
#
# The pool is published as \`vault-3\` on testnet: pox-5 keys a bond's allowlist
# on the staker's principal, so the name is whatever the grant spells, and the
# grants for \`vault-1\` and \`vault-2\` belong to pools already published. The
# siblings take \`-3\` for the same reason. To use other names, pass the same
# \`-- --staker-name\` and \`--suffix\` to both commands.
`
  : "";

const plan = `${header}---
id: 0
name: Testnet deployment
network: testnet
stacks-node: "https://api.testnet.hiro.so"
bitcoin-node: "http://blockstack:blockstacksystem@bitcoind.testnet.stacks.co:18332"
plan:
  batches:
  - id: 0
    transactions:
${publish}
    epoch: '4.0'
  - id: 1
    transactions:
    # Binds the pool to its signer manager and names its operator. Only the
    # contract's own deployer may call it, and only once. A separate batch so
    # the publishes above are confirmed first.
    #
    # The deployer takes the seat rather than the DAO because the DAO cannot
    # vote until the pool has staked: voting weight is committed shares, and
    # there are none before then. The DAO joins as a second operator in the
    # next batch. Binding itself needs no seat -- \`bind-next-bond\` is
    # permissionless -- so what the seat holds is the signer manager, the
    # skip, and the sweep.
    - transaction-type: contract-call
      contract-id: ${deployer}.${staker}
      expected-sender: ${deployer}
      method: initialize
      parameters:
        - "'${manager}"
        - "'${deployer}"
      cost: 50000
    epoch: '4.0'
  - id: 2
    transactions:
    # Seats the DAO alongside the deployer, which is what puts the four voted
    # powers -- signer moves, the trusted list, who the operators are, and
    # sweeps -- in the members' hands.
    #
    # \`update-operator\` refuses to change the caller's own entry, so the
    # deployer cannot retire itself here. Handing over completely is a later
    # call *from the DAO*, by vote; leaving both seated is the right state for a
    # testnet run, since only the keyed operator can bind a bond.
    - transaction-type: contract-call
      contract-id: ${deployer}.${staker}
      expected-sender: ${deployer}
      method: update-operator
      parameters:
        - "'${deployer}.${DAO}"
        - "true"
      cost: 50000
    epoch: '4.0'
`;

mkdirSync(join(root, "deployments"), { recursive: true });
const out = join(root, "deployments", "testnet-plan.yaml");
writeFileSync(out, plan);
console.log(`wrote ${out}${template ? " (template)" : ""}
  deployer / operator : ${deployer}
  pool contract       : ${deployer}.${staker}
  operator DAO        : ${deployer}.${DAO}
  signer manager      : ${manager}

  clarinet deployments apply --testnet --manifest-path Clarinet-testnet.toml \\
    --deployment-plan-path deployments/testnet-plan.yaml`);
