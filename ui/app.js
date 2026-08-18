// A small, buildless UI for the bond-staker pool.
//
// Everything is read straight from chain through the node's read-only endpoint,
// so the page shows real state before a wallet is connected. Writes go through
// the connected wallet.
import {
  Cl,
  cvToHex,
  hexToCV,
  cvToValue,
} from "https://esm.sh/@stacks/transactions@7";
import {
  connect,
  disconnect,
  getLocalStorage,
  isConnected,
  request,
} from "https://esm.sh/@stacks/connect@8";
import { toPoxAddress } from "./btc-address.js";

const NETWORKS = {
  testnet: {
    api: "https://api.testnet.hiro.so",
    sbtc: "SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1",
    explorer: "https://explorer.hiro.so",
  },
  mainnet: {
    api: "https://api.hiro.so",
    sbtc: "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4",
    explorer: "https://explorer.hiro.so",
  },
  devnet: {
    api: "http://localhost:3999",
    sbtc: "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4",
    explorer: "http://localhost:8000",
  },
};

const POX5 = { address: "ST000000000000000000002AMW42H", name: "pox-5" };

const config = {
  network: localStorage.getItem("network") ?? "testnet",
  deployer: localStorage.getItem("deployer") ?? "",
  manager: localStorage.getItem("manager") ?? "",
  // The pool's contract name is not fixed: pox-5 keys a bond's allowlist on the
  // staker's principal, so a deployment has to take whatever name the grant
  // happens to spell -- `vault-1` on the current testnet bonds. Same contract,
  // different label.
  pool: localStorage.getItem("pool") || "bond-staker",
};

const $ = (id) => document.getElementById(id);
const net = () => NETWORKS[config.network];
const pool = () => ({ address: config.deployer, name: config.pool || "bond-staker" });
const bridge = () => ({ address: config.deployer, name: "bond-bridge" });

let account = null;
let state = {};

/// --- chain reads -----------------------------------------------------------

async function readOnly({ address, name }, fn, args = []) {
  const url = `${net().api}/v2/contracts/call-read/${address}/${name}/${fn}`;
  const body = {
    sender: account ?? address,
    arguments: args.map(cvToHex),
  };
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await response.json();
  if (!json.okay) throw new Error(json.cause ?? "read failed");
  return cvToValue(hexToCV(json.result), true);
}

/** `cvToValue` leaves `{type, value}` wrappers on nested fields. */
const plain = (value) => {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(plain);
  if ("type" in value && "value" in value) return plain(value.value);
  return Object.fromEntries(
    Object.entries(value).map(([k, v]) => [k, plain(v)]),
  );
};

const num = (value) => Number(plain(value) ?? 0);

/// --- formatting ------------------------------------------------------------

const sats = (value) =>
  `${Number(value).toLocaleString()} sats` +
  (Number(value) >= 1e5 ? ` (${(Number(value) / 1e8).toFixed(4)} BTC)` : "");
const stx = (value) => `${(Number(value) / 1e6).toLocaleString()} STX`;
const shorten = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

function say(message, kind = "info") {
  const box = $("status");
  box.textContent = message;
  box.className = `status ${kind}`;
}

/// --- wallet ----------------------------------------------------------------

async function connectWallet() {
  await connect();
  loadAccount();
  await refresh();
}

function loadAccount() {
  if (!isConnected()) {
    account = null;
  } else {
    const stored = getLocalStorage();
    account = stored?.addresses?.stx?.[0]?.address ?? null;
  }
  $("account").textContent = account ? shorten(account) : "not connected";
  $("connect").textContent = account ? "Disconnect" : "Connect wallet";
}

/** One place for every write, so the wallet call shape is defined once. */
async function call(contract, functionName, functionArgs, label) {
  if (!account) return say("Connect a wallet first", "warn");
  try {
    say(`${label}…`);
    const result = await request("stx_callContract", {
      contract: `${contract.address}.${contract.name}`,
      functionName,
      functionArgs,
      network: config.network,
    });
    const txid = result?.txid ?? result?.txId;
    say(`${label} submitted: ${txid ?? "see wallet"}`, "ok");
    if (txid) {
      $("status").innerHTML +=
        ` <a target="_blank" href="${net().explorer}/txid/${txid}?chain=${config.network}">explorer</a>`;
    }
  } catch (error) {
    say(`${label} failed: ${error?.message ?? error}`, "warn");
  }
}

/// --- rendering -------------------------------------------------------------

async function refresh() {
  if (!config.deployer) {
    say("Set the pool's deployer address to begin", "warn");
    return;
  }
  try {
    const [bond, totals, cfg, live, preview, burn] = await Promise.all([
      readOnly(pool(), "get-bound-bond"),
      readOnly(pool(), "get-pool"),
      readOnly(pool(), "get-config"),
      readOnly(pool(), "get-live-epoch"),
      readOnly(pool(), "get-stake-preview"),
      fetch(`${net().api}/v2/info`).then((r) => r.json()),
    ]);
    state = {
      bond: plain(bond),
      totals: plain(totals),
      config: plain(cfg),
      live: plain(live),
      preview: plain(preview),
      burnHeight: burn.burn_block_height,
    };
    renderPool();
    if (account) await renderPosition();
    say("");
  } catch (error) {
    say(`Could not read the pool: ${error?.message ?? error}`, "warn");
  }
}

function renderPool() {
  const { bond, totals, config: cfg, live, preview, burnHeight } = state;
  const opens = num(bond["stake-opens-at"]);
  const starts = num(bond["start-height"]);
  const bound = plain(bond.bound) === true;
  const inWindow = bound && burnHeight >= opens && burnHeight < starts;

  $("pool").innerHTML = `
    <dl>
      <dt>Burn height</dt><dd>${burnHeight.toLocaleString()}</dd>
      <dt>Epochs staked</dt><dd>${num(cfg["epoch-count"])}${
        plain(cfg.finished) ? " (wound down)" : ""
      }</dd>
      ${
        live
          ? `<dt>Live bond</dt><dd>#${num(live["bond-index"])}, ${sats(
              num(live["staked-sats"]),
            )}, unlocks at ${num(live["unlock-burn-height"]).toLocaleString()}</dd>`
          : ""
      }
      <dt>Bond bound</dt><dd>${
        bound
          ? `#${num(bond["bond-index"])}, starts ${starts.toLocaleString()}, cap ${sats(
              num(bond["max-sats"]),
            )}`
          : "none — deposits are closed"
      }</dd>
      <dt>Stake window</dt><dd>${
        bound
          ? `${opens.toLocaleString()} – ${starts.toLocaleString()} ${
              inWindow ? "· open now" : burnHeight < opens ? "· not yet" : "· missed"
            }`
          : "—"
      }</dd>
      <dt>Queued</dt><dd>${sats(num(totals["queued-sats"]))} + ${stx(
        num(totals["queued-ustx"]),
      )}</dd>
      <dt>Bonded</dt><dd>${sats(num(totals["bonded-sats"]))} + ${stx(
        num(totals["bonded-ustx"]),
      )}</dd>
      <dt>Next stake</dt><dd>${sats(num(preview.sats))} of ${sats(
        num(preview["eligible-sats"]),
      )} eligible${
        plain(preview.scaled)
          ? ` — short ${stx(num(preview["short-ustx"]))} of STX`
          : ""
      }</dd>
    </dl>`;

  $("stake").disabled = !inWindow;
  $("stake").title = inWindow ? "" : "only inside the stake window";
}

async function renderPosition() {
  const [member, rewards, principal] = await Promise.all([
    readOnly(pool(), "get-settled-member", [Cl.principal(account)]),
    readOnly(pool(), "get-claimable-rewards", [Cl.principal(account)]),
    readOnly(pool(), "get-claimable-principal", [Cl.principal(account)]),
  ]);
  const m = plain(member);
  const claim = plain(principal);
  if (!m) {
    $("position").innerHTML = "<p>No position yet.</p>";
    return;
  }
  $("position").innerHTML = `
    <dl>
      <dt>Shares</dt><dd>${Number(num(m.shares)).toLocaleString()}</dd>
      <dt>Queued</dt><dd>${sats(num(m["queued-sats"]))} + ${stx(
        num(m["queued-ustx"]),
      )}</dd>
      <dt>Bonded</dt><dd>${sats(num(m["bonded-sats"]))} + ${stx(
        num(m["bonded-ustx"]),
      )}</dd>
      <dt>Released</dt><dd>${sats(num(claim["released-sats"]))} + ${stx(
        num(claim["released-ustx"]),
      )}</dd>
      <dt>Rewards</dt><dd>${sats(num(rewards))}</dd>
      <dt>Leaving</dt><dd>${plain(m["exit-epoch"]) === null ? "no" : "at the next roll"}</dd>
    </dl>`;
}

/// --- actions ---------------------------------------------------------------

async function quoteStx(inputId, outputId) {
  const amount = Number($(inputId).value);
  if (!Number.isFinite(amount) || amount <= 0) {
    $(outputId).textContent = "";
    return;
  }
  try {
    const ustx = num(
      await readOnly(pool(), "get-required-ustx", [Cl.uint(amount)]),
    );
    const value = (amount / 100) * num(state.bond["stx-value-ratio"]);
    $(outputId).textContent =
      `plus ${stx(ustx)} — ${((ustx / (value + ustx)) * 100).toFixed(2)}% of the deposit`;
  } catch {
    $(outputId).textContent = "bind a bond first";
  }
}

function wire() {
  $("network").value = config.network;
  $("deployer").value = config.deployer;
  $("manager").value = config.manager;
  $("pool").value = config.pool;

  for (const [id, key] of [
    ["network", "network"],
    ["deployer", "deployer"],
    ["manager", "manager"],
    ["pool", "pool"],
  ]) {
    $(id).addEventListener("change", () => {
      config[key] = $(id).value.trim();
      localStorage.setItem(key, config[key]);
      refresh();
    });
  }

  $("connect").addEventListener("click", async () => {
    if (account) {
      disconnect();
      loadAccount();
      $("position").innerHTML = "";
    } else {
      await connectWallet();
    }
  });
  $("refresh").addEventListener("click", refresh);

  for (const tab of document.querySelectorAll("[data-tab]")) {
    tab.addEventListener("click", () => {
      for (const t of document.querySelectorAll("[data-tab]")) {
        t.classList.toggle("on", t === tab);
      }
      for (const panel of document.querySelectorAll("[data-panel]")) {
        panel.hidden = panel.dataset.panel !== tab.dataset.tab;
      }
    });
  }

  $("sbtc-sats").addEventListener("input", () =>
    quoteStx("sbtc-sats", "sbtc-quote"),
  );
  $("btc-sats").addEventListener("input", () =>
    quoteStx("btc-sats", "btc-quote"),
  );

  $("deposit").addEventListener("click", () =>
    call(pool(), "deposit", [Cl.uint(Number($("sbtc-sats").value))], "Deposit"),
  );
  $("withdraw").addEventListener("click", () =>
    call(pool(), "withdraw", [], "Withdraw"),
  );
  $("stake").addEventListener("click", () => {
    if (!config.manager) return say("Set the signer manager address", "warn");
    call(pool(), "stake", [Cl.principal(config.manager)], "Stake");
  });
  $("claim-rewards").addEventListener("click", () =>
    call(pool(), "claim-rewards", [Cl.principal(account)], "Claim rewards"),
  );
  $("claim-principal").addEventListener("click", () =>
    call(pool(), "claim-principal", [Cl.principal(account)], "Claim principal"),
  );
  $("request-exit").addEventListener("click", () =>
    call(pool(), "request-exit", [], "Request exit"),
  );
  $("cancel-exit").addEventListener("click", () =>
    call(pool(), "cancel-exit", [], "Cancel exit"),
  );

  $("announce").addEventListener("click", async () => {
    const address = await readOnly(bridge(), "get-deposit-address").catch(
      () => null,
    );
    $("deposit-address").textContent = plain(address) ?? "";
    call(
      bridge(),
      "announce-btc-deposit",
      [
        Cl.bufferFromHex($("btc-txid").value.trim().replace(/^0x/, "")),
        Cl.uint(Number($("btc-vout").value || 0)),
        Cl.uint(Number($("btc-sats").value)),
      ],
      "Announce deposit",
    );
  });
  $("confirm").addEventListener("click", () =>
    call(
      bridge(),
      "confirm-btc-deposit",
      [
        Cl.bufferFromHex($("btc-txid").value.trim().replace(/^0x/, "")),
        Cl.uint(Number($("btc-vout").value || 0)),
      ],
      "Confirm deposit",
    ),
  );
  $("cancel-announce").addEventListener("click", () =>
    call(
      bridge(),
      "cancel-btc-deposit",
      [
        Cl.bufferFromHex($("btc-txid").value.trim().replace(/^0x/, "")),
        Cl.uint(Number($("btc-vout").value || 0)),
      ],
      "Cancel announcement",
    ),
  );

  $("claim-to-btc").addEventListener("click", async () => {
    try {
      const { version, hashbytes } = await toPoxAddress($("btc-payout").value);
      await call(
        bridge(),
        "claim-principal-to-btc",
        [
          Cl.tuple({
            version: Cl.bufferFromHex(version),
            hashbytes: Cl.bufferFromHex(hashbytes),
          }),
          Cl.uint(Number($("max-fee").value || 0)),
        ],
        "Claim to bitcoin",
      );
    } catch (error) {
      say(`Bad bitcoin address: ${error.message}`, "warn");
    }
  });
}

wire();
loadAccount();
refresh();
setInterval(refresh, 30_000);
