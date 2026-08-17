# UI

A buildless page for the staking flow — deposit with sBTC or with L1 bitcoin,
watch the pool, claim, leave.

```
pnpm exec serve ui        # or: python3 -m http.server -d ui 8080
```

Open it, pick a network, paste the address that deployed `bond-staker`, and
connect a wallet. State is read straight from the node's read-only endpoint, so
the page shows the real pool before any wallet is connected; only writes need
one.

Three files, no bundler:

| file | what it does |
| --- | --- |
| `index.html` | markup and styles |
| `app.js` | reads, writes, formatting |
| `btc-address.js` | bitcoin address → the `{version, hashbytes}` the bridge wants |

`@stacks/transactions` and `@stacks/connect` come from esm.sh, pinned to major
versions in the import lines. Everything else is plain DOM.

## The two ways in

**With sBTC.** Enter an amount in sats; the page quotes the STX leg from
`get-required-ustx` and shows it as a share of the deposit. One `deposit` call
moves both legs.

**With L1 bitcoin.** Three steps, in this order, and the order is the point:

1. **Announce** the txid of the transaction you are *about to* broadcast. This
   also takes the STX leg — the one Stacks transaction you were always going to
   have to send, since STX cannot come from bitcoin.
2. **Send** the bitcoin to the treasury address the page shows. Never to the
   staker contract: sBTC arriving there is taken for reward and split among the
   members.
3. **Confirm** once the sBTC signers have swept it. Permissionless — a keeper
   can do this for you.

Announcing before broadcasting is what makes the deposit yours: until the
transaction is out, nobody else knows its txid to announce it first.

Going out, *Claim to bitcoin* hands your released principal to the sBTC signers
to pay out on L1. `btc-address.js` turns a `bc1…`/`tb1…`/`1…`/`3…` address into
the pox-shaped `{version, hashbytes}` pair; p2pkh, p2sh, p2wpkh, p2wsh and p2tr
are handled and everything else is refused rather than guessed at. It is
covered by `tests/btc-address.test.ts`, which round-trips every shape against
an independently written encoder and checks the canonical BIP-173 vector.

The STX leg always comes back on Stacks — `claim-principal` — since that is the
only place STX exists.

## Networks

`app.js` knows the sBTC deployer per network, which differs by version byte:

    testnet   SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1
    mainnet   SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4

The *contracts* have the same split, and it is not something the page can fix:
a `contract-call?` target is a literal. Build the flavour you are deploying
with `node scripts/build-network.mjs testnet`, which writes `build/testnet/`.
