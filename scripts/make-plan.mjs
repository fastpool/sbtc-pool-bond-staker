// Write a deployment plan for a network: publish the four contracts,
// initialize the pool, and seat the DAO as an operator.
//
//   node scripts/make-plan.mjs testnet ST3YOUR…DEPLOYER [signer-manager]
//   node scripts/make-plan.mjs mainnet SP3YOUR…DEPLOYER [signer-manager]
//   node scripts/make-plan.mjs testnet ST3YOUR…DEPLOYER --staker-name vault-4 --suffix -4
//
// The deployer address has to be given because it appears in a dozen places and
// a half-substituted plan would deploy under one identity and initialize under
// another. `initialize` only accepts the contract's own deployer, so the two
// must match.
//
// `--staker-name` and `--suffix` override the network's names, and have to
// match whatever `build-network.mjs` was given: pox-5 keys a bond's allowlist
// on the staker's principal, so publishing under a name no grant mentions
// leaves a pool that can never stake.
//
// Publishes come from build/<network>/, whose sBTC and pox-5 addresses have
// been rewritten for the network -- run `pnpm run build:<network>` first.
import { existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Per network: what the pool is called -- the name its allowlist grant spells
// -- and what its three siblings carry after their source names, since a
// contract name can never be reused at an address. `build-network.mjs`
// publishes under the same names by default; the two have to agree or the plan
// points at files that are not there. The manager is the signer manager
// `initialize` binds the pool to, which has to be registered with pox-5.
const NETWORKS = {
  testnet: {
    staker: "vault-3",
    suffix: "-3",
    manager: "ST1B38CGQRPXEMRH7B66VXTS22DQTNMSW4YJJ7QK1.signer-manager",
    address: /^S[TN][0-9A-HJKMNP-Z]{38,40}$/,
    example: "ST3YOUR…DEPLOYER",
    stacksNode: "https://api.testnet.hiro.so",
    bitcoinNode: "http://blockstack:blockstacksystem@bitcoind.testnet.stacks.co:18332",
    // Fee in uSTX per byte, matching `deployment_fee_rate` in settings/<Network>.toml.
    feeRate: 10,
  },
  mainnet: {
    staker: "esbee-dao-bond-staker-1",
    suffix: "-1",
    manager: "SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4.fastpool-max500-signer-manager",
    address: /^S[PM][0-9A-HJKMNP-Z]{38,40}$/,
    example: "SP3YOUR…DEPLOYER",
    stacksNode: "https://api.hiro.so",
    bitcoinNode: "http://blockstack:blockstacksystem@bitcoin.blockstack.com:8332",
    feeRate: 10,
  },
};

const usage =
  "usage: node scripts/make-plan.mjs <testnet|mainnet> <deployer-address> [signer-manager]" +
  " [--staker-name <name>] [--suffix <suffix>]\n" +
  "       node scripts/make-plan.mjs <testnet|mainnet> --template";

// The two flags are pulled out first so they may sit anywhere, leaving the
// positional arguments where they have always been. A bare `--` is dropped:
// pnpm forwards the separator itself when a flag is passed through `pnpm run`.
const argv = process.argv.slice(2).filter((a) => a !== "--");
const network = argv.shift();
if (!NETWORKS[network]) {
  console.error(usage);
  process.exit(1);
}
const { staker: STAKER, suffix: SUFFIX, manager: DEFAULT_MANAGER } = NETWORKS[network];
const Network = network[0].toUpperCase() + network.slice(1);
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

if (!template && !NETWORKS[network].address.test(deployer ?? "")) {
  console.error(usage);
  process.exit(1);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// Dependency order, which is also the order Clarinet publishes them in: the
// pool calls the treasury, the bridge calls both, and the DAO calls the pool.
// Nothing calls the DAO, so it goes last.
//
// The three siblings carry the same suffix the build gave them.
const DAO = `esbee-dao${suffix}`;
const CONTRACTS = [
  `bond-treasury${suffix}`,
  staker,
  `bond-bridge${suffix}`,
  DAO,
];

for (const name of CONTRACTS) {
  if (!existsSync(join(root, "build", network, `${name}.clar`))) {
    console.error(
      `build/${network}/${name}.clar is missing — run: pnpm run build:${network}` +
        (staker === STAKER && suffix === SUFFIX ? "" : " --") +
        (staker === STAKER ? "" : ` --staker-name ${staker}`) +
        (suffix === SUFFIX ? "" : ` --suffix ${suffix}`),
    );
    process.exit(1);
  }
}

// Fee in uSTX, the way clarinet sizes it: bytes x the fee rate in
// settings/<Network>.toml, with a floor so a small contract still gets mined.
const fee = (bytes) => Math.max(50_000, bytes * NETWORKS[network].feeRate);

const publish = CONTRACTS.map((name) => {
  const path = `build/${network}/${name}.clar`;
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
#     pnpm run build:${network}
#     pnpm run plan:${network} ${NETWORKS[network].example}
#
# Every <DEPLOYER> below has to be the account that publishes the contracts:
# \`initialize\` only accepts the pool's own deployer, so publishing under one
# identity and initializing under another leaves the pool unusable.
#
# The pool is published as \`${STAKER}\`: pox-5 keys a bond's allowlist on the
# staker's principal, so the name is whatever the grant spells. The siblings
# take \`${SUFFIX}\` because a contract name can never be reused at an address.
# To use other names, pass the same \`-- --staker-name\` and \`--suffix\` to
# both commands.
`
  : "";

const plan = `${header}---
id: 0
name: ${Network} deployment
network: ${network}
stacks-node: "${NETWORKS[network].stacksNode}"
bitcoin-node: "${NETWORKS[network].bitcoinNode}"
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
    # Seats the DAO alongside the deployer, which is what puts the voted
    # powers -- signer moves, the trusted list, who the operators are, sweeps
    # and skipping a bond -- in the members' hands.
    #
    # \`update-operator\` refuses to change the caller's own entry, so the
    # deployer cannot retire itself here. Handing over completely is a later
    # call *from the DAO*, by vote, once the pool has staked and the members
    # have the shares to vote with.
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
const out = join(root, "deployments", `${network}-plan.yaml`);
writeFileSync(out, plan);
console.log(`wrote ${out}${template ? " (template)" : ""}
  deployer / operator : ${deployer}
  pool contract       : ${deployer}.${staker}
  operator DAO        : ${deployer}.${DAO}
  signer manager      : ${manager}

  clarinet deployments apply --${network} --manifest-path Clarinet-${network}.toml \\
    --deployment-plan-path deployments/${network}-plan.yaml`);
