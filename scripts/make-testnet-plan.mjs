// Write a testnet deployment plan: publish the three contracts, then call
// `initialize` on the pool.
//
//   node scripts/make-testnet-plan.mjs ST3YOUR…DEPLOYER [signer-manager]
//
// The deployer address has to be given because it appears in six places and a
// half-substituted plan would deploy under one identity and initialize under
// another. `initialize` only accepts the contract's own deployer, so the two
// must match.
//
// Publishes come from build/testnet/, whose sBTC and pox-5 addresses have been
// rewritten for the network -- run `pnpm run build:testnet` first.
import { existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [given, manager = "ST1B38CGQRPXEMRH7B66VXTS22DQTNMSW4YJJ7QK1.signer-manager"] =
  process.argv.slice(2);

// `--template` writes the same plan with the address left as a placeholder, so
// the file on disk is always a working syntax reference even before anyone has
// a deployer. Clarinet rejects the placeholder, which is the failure we want if
// it is ever applied unedited.
const template = given === "--template";
const deployer = template ? "<DEPLOYER>" : given;

if (!template && !/^S[TN][0-9A-HJKMNP-Z]{38,40}$/.test(deployer ?? "")) {
  console.error(
    "usage: node scripts/make-testnet-plan.mjs <deployer-address> [signer-manager]\n" +
      "       node scripts/make-testnet-plan.mjs --template",
  );
  process.exit(1);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CONTRACTS = ["bond-treasury", "bond-staker", "bond-bridge"];

for (const name of CONTRACTS) {
  if (!existsSync(join(root, "build", "testnet", `${name}.clar`))) {
    console.error(`build/testnet/${name}.clar is missing — run: pnpm run build:testnet`);
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
    - transaction-type: contract-call
      contract-id: ${deployer}.bond-staker
      expected-sender: ${deployer}
      method: initialize
      parameters:
        - "'${manager}"
        - "'${deployer}"
      cost: 50000
    epoch: '4.0'
`;

mkdirSync(join(root, "deployments"), { recursive: true });
const out = join(root, "deployments", "testnet-plan.yaml");
writeFileSync(out, plan);
console.log(`wrote ${out}${template ? " (template)" : ""}
  deployer / operator : ${deployer}
  signer manager      : ${manager}

  clarinet deployments apply --testnet --manifest-path Clarinet-testnet.toml \\
    --deployment-plan-path deployments/testnet-plan.yaml`);
