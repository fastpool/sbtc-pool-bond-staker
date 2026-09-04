# The Bond Staker and Esbee DAO

**By Friedger — September 2026**

---

## 1. The Landscape: PoX-5 and Protocol Bonds

PoX-5 is the Stacks protocol upgrade that introduces *Bitcoin Staking* — a mechanism whereby BTC-holders can earn yield from the Stacks Proof-of-Transfer (PoX) rewards without surrendering custody of their bitcoin. It was activated at Bitcoin block 960,230 (Epoch 4.0), and the genesis bond will start earning at block 966,350.

The core instrument is the **protocol bond**: a six-month, dual-asset commitment consisting of:

- **BTC leg**: a timelock on Bitcoin L1, held under the user's own keys, **or** an sBTC lock on Stacks
- **STX leg**: an STX lock inside the `pox-5` Clarity contract on Stacks, gating participation and determining signing weight.

The two legs are cryptographically linked: the Bitcoin script on L1 commits to a hash of the participant's Stacks principal, and `pox-5` refuses to register a bond it cannot match to a confirmed L1 UTXO. For sBTC locks, the link is encoded in Clarity. Rewards flow weekly into sBTC (via the sBTC auto-bridge) and can be claimed as sBTC or Bitcoin L1.

---

## 2. The Bond Staker: A Pooled Staker Contract

The **sbtc-pool-bond-staker** is a contract suite that lets multiple members aggregate their sBTC and the required STX into a single pooled position on a PoX-5 bond. The pool itself is the *staker* registered on the bond's allowlist — PoX-5 sees only the pool contract, not the individual members. All member-level accounting lives inside the pool.

### Architecture: Four Contracts

The system comprises four contracts deployed in dependency order:

| Contract        | Role                                                                                                      |
| --------------- | --------------------------------------------------------------------------------------------------------- |
| `bond-treasury` | Holds the pooled sBTC principal. Inert — no admin, no upgrade path, no discretion.                        |
| `bond-staker`   | The ledger: deposits, shares, epochs, the bond position, and reward accounting.                           |
| `bond-bridge`   | The L1 → L2 on-ramp and off-ramp. Handles Bitcoin address commitments, BTC deposits, and BTC withdrawals. |
| `esbee-dao`     | (Optional) Replaces the operator key with a quadratic-vote DAO.                                           |

Each contract calls only the ones above it; there are no circular references.

### The Three Quantities

Every member tracks three values:

- **sats** — the sBTC deposited; what they get back.
- **ustx** — the STX deposited alongside; what they get back.
- **shares** — their weight in an epoch; what determines their share of rewards.

Shares are struck when a bond is staked (one share per committed satoshi, mirroring PoX-5's own weighting). They are tracked separately from deposits because the two quantities part ways depending on how a member leaves.

### Epochs and Rolls

Each bond that the pool stakes into is an **epoch**. At the transition between bonds, `stake` performs a "roll" that:

1. Adds queued deposits to the pool's position.
2. Releases members who requested exit.
3. Carries remaining members forward untouched.

The roll adds only the *net difference* in sBTC and resizes the STX lock in place. PoX-5 makes this seamless — bond N's term ends at exactly the cycle bond N+6 begins.

Rewards arrive as bare sBTC transfers, twice per reward cycle. Since an epoch's final cycle pays out *after* the roll that replaced it, the pool runs two clocks: positions move at roll time, while rewards move at epoch settlement time. A **stash** mechanism bridges this gap — when a member's epoch is still paying while the pool has moved on, their claim is set aside and keeps drawing down until that epoch settles.

---

## 3. The Bridge: Joining and Leaving with Bitcoin

The `bond-bridge` contract is a sophisticated L1 ↔ L2 bridge that solves a fundamental problem: an sBTC deposit is a bare mint with no record of who sent it. The bridge has members tie deposits to themselves *in advance*, via a two-phase commitment:

1. **`commit-btc-address(digest, sats)`** — Commit to a hash of the Bitcoin address (with a salt), paying the STX leg. The pool reserves allocation room.
2. **`reveal-btc-address(address, salt)`** — Reveal the address on Stacks. One burn block later, the address is public.
3. **Send from that address** — The member broadcasts the Bitcoin transaction from the revealed address.
4. **Wait for sBTC signers** — The signers sweep the deposit and mint to the treasury.
5. **`complete-btc-deposit(txid, vout, tx, parents)`** — Permissionless. The caller proves every input of the deposit tx is locked to the revealed address by walking the parent transaction chain using Clarity 6's `get-bitcoin-tx-output?`.

### The Security Argument

The commit-then-reveal order is the entire security model. Without commitment, a member names an address in the clear on Stacks; an onlooker who sees it in the mempool can race to claim it with a higher fee. The salted digest commits to nothing, and the reveal (mined first) takes the address. The 2-burn-block delay is critical: `burn-block-height` is per *tenure* (not per Stacks block), so two blocks guarantee at least one full Bitcoin block of margin.

### Proving Deposit Ownership

At `complete-btc-deposit`, the caller provides the deposit transaction and its parent transactions. The contract walks the chain of txids — authenticated by the sBTC registry — to verify every input is locked to the revealed address. All inputs must lock to the revealed address, not just one, preventing a two-address transaction from being claimable by either party. A maximum of 8 inputs is enforced.

### The Fast Lane

For addresses whose public key is recoverable (p2pkh, p2sh-p2wpkh, p2wpkh), there is a single-call shortcut: **`claim-btc-address(address, public_key, signature, sats)`**. The member signs the message `fastpool bond address claim: <contract_hash160>` with their Bitcoin key. Since a signature cannot be copied, there is no need to hide the address first. No commit, no delay, no attack window.

### 

---

## 4. Leaving the Pool

Members have three exit paths, each with different consequences:

| Path                   | When                   | STX                   | sBTC                 | Rewards                                     |
| ---------------------- | ---------------------- | --------------------- | -------------------- | ------------------------------------------- |
| **request-exit**       | Released at next roll  | Released at roll      | Released at roll     | Earned until roll                           |
| **unstake-sbtc**       | After bond's 12 cycles | Released              | Released             | Full term                                   |
| **unstake-sbtc-early** | Any time               | Stays locked in PoX-5 | Released immediately | Forfeited (unrecognized) + forfeited future |

Early unstaking works the same regardless of how a member joined — whether they deposited native sBTC directly or arrived via the L1 BTC bridge. Once deposited, the pool treats every position uniformly.`unstake-sbtc-early` releases the member's sBTC from the treasury and marks their position as `released`, but leaves the STX leg locked in PoX-5 until the bond's normal unlock cycle.

-----

## 5. The Operator

The operator seat controls five powers, spanning three categories of control.

**Bond scheduling** — The operator sets which bond period the pool commits to next via `set-next-bond`. This doesn't lock the pool in; it places a floor that the next permissionless bind will honor. A floor of `N + 1` skips bond `N`; a floor of `M` aims at bond `M`. The operator cannot prevent a bind — that remains permissionless — but they control whether the pool participates in a given period at all.

**Signing infrastructure** — The operator trusts and distrusts signer-manager code hashes, and can change the signer manager for the live bond through `update-bond-registration`. This is the operator's most consequential power: pox-5 pays rewards to the active signer manager, so a broken or malicious manager costs the pool an entire bond's worth of yield. Trust is tied to code hashes, so managers can be vetted before deployment. A newly trusted manager takes effect only at the next roll; a distrusted one is removed instantly, which matters when a manager stops signing and an emergency rotation is needed.

**Pool administration** — The operator adds and removes operator keys through `update-operator`, and sweeps unattributed principal (sBTC that arrived at the treasury without a matching announcement) to a designated recipient. The operator cannot modify their own entry, preventing self-lockout.

---

## 6. Esbee DAO: Quadratic Governance for Bond Pools

The **Esbee DAO** replaces the deployer's operator key with on-chain governance.  To start the DAO, the deployer adds the `esbee-dao` contract as the operator principal.

### Quadratic Voting

A member's voting weight is **√(committed sats)**. A holder 10,000× larger has 100× the say, not 10,000×. Only *committed* (bonded) shares count — queued deposits are withdrawable on demand, so counting them would let anyone rent a majority for one transaction.

### Proposal Lifecycle

Every proposal must clear all of these lines:

| Requirement      | Duration                          | Purpose                                                                    |
| ---------------- | --------------------------------- | -------------------------------------------------------------------------- |
| Voting period    | ~2 days (288 burn blocks)         | Cannot be raised and settled before anyone reads it                        |
| Quorum           | 3,000 bips (30% of √total-shares) | An empty room does not decide                                              |
| Supermajority    | 6,000 bips (60% of votes cast)    | A bare majority is not a mandate                                           |
| Execution delay  | ~1 day (144 burn blocks)          | Members can `request-exit` before the outcome lands                        |
| Execution window | ~1 week (1,008 burn blocks)       | A stale mandate cannot be dusted off months later                          |
| Same epoch       | Always                            | If the pool rolls, the membership that voted is no longer the one affected |

Execution is permissionless — anyone can execute a passed proposal. The mandate is the vote, not the executor. The DAO cannot touch deposits and cannot remove itself from the operator seat (by PoX-5 design).

---

## 7. Testing and Verification

The contract suite is verified through four complementary layers, each catching a different class of defects.

### Unit Tests

The `tests/` directory holds ~3,600 lines of vitest tests across six files, covering every public entry point. They run against **simnet** — Clarity's in-VM execution environment — which includes a real pox-5 deployment. This means the tests exercise the *actual* pox-5 contract (bond admin, reward accounting, signer validation), not a stub. The fixture can call `setup-bond` and allowlist the pool directly through the boot address, so the bond registration is verified against the protocol rather than mocked.

### Invariant Fuzzing

Rendezvous drives a fuzzer that explores random transaction sequences against the pool's 23 invariants. Rather than a separate harness file, the invariants live as `define-read-only` functions inside `bond-staker.clar` itself — Clarinet compiles the contract twice, stripping `#[env(simnet)]` forms for the publish build while including them for fuzzing. The stand-ins for pox-5's sBTC custody (`bond-escrow.clar`) are modelled as real token contracts with actual transfers, so invariants stated against the pool's sBTC balance can't hold trivially.

The fuzzer has caught real defects:

- **A rounding hole in reward accounting.** `sync-rewards` credited `floor(a) + floor(b)` across successive syncs while a member's share floors once against the running index — `floor(a) + floor(b)` can be one satoshi short of `floor(a + b)`. After enough syncs the pool owed members more than it had credited, and the final `claim-rewards` would have aborted on underflow.
- **Principal conjured by rounding.** A roll that couldn't carry all queued deposits scaled positions by a fraction. The part handed back was taken as the *remainder* of the carried part, rounding it up so members were collectively owed a satoshi more than the pool credited.
- **A double-refund on the settlement clock.** Epochs used to stay open for rewards past their roll, and positions waited for that too — so members were carried across later than the pool was, and `withdraw` would refund a deposit a second time out of another member's queued funds.

### Stxer Simulations

`stxer` runs end-to-end simulations against a fork of real mainnet state — the actual deployed `pox-5` and `sBTC` contracts, not stand-ins. Steps are sent from principals that the developers hold no key for, which is the only way to model the bond admin's side of a launch (e.g., `setup-bond` granting the pool an allowlist slot). Nothing is signed or broadcast; the simulation exercises the full run, from deploy and allowlist through bind, deposit, and stake. Two scenario scripts are maintained: `simulate:genesis` covers the standard flow (deposit sBTC directly), and `simulate:bridge` covers the L1 bitcoin path. Each prints a per-step report and a stxer URL, so a reader can replay the exact execution in the sandboxed environment. 

### Symbolic Verification (Clairvoyance)

There is on-going research about formal verifcation of Clarity code by Jude Nelson. We did some experiments with that to see how far the pool can be pushed. 

Running the prototype against the bond-staker contract and 18 invariants resulted in 155 HOLDS, 0 VIOLATED, 2 NOT PROVEN (a known tool limitation around `(or)` expressions), 401 UNFINISHED (reachability limited by the engine's step budget and `settle`'s branching factor). No mutator was shown to break any invariant. This is evidence, not a clean bill of health — the UNFINISHED results are what the tool cannot reach, not a verdict.

Furthermore, we ran mutation scripts that break the contract on purpose and requires the invariant it breaks to stop holding. Every mutator that introduces a bug is confirmed to flip at least one invariant from HOLDS to NOT PROVEN. This guards against the primary failure mode of symbolic verification: invariants whose own reads get abstracted away hold trivially, making a wall of HOLDS results indistinguishable from genuine correctness.

---

## 8. Why This Matters

The bond staker + esbee dao system demonstrates several important patterns for decentralized finance on Stacks:

- **Permissionless exit guarantees** — The operator can never strand the pool. `bind-next-bond`, `stake`, `unstake-sbtc`, and both claim functions are permissionless. Members can always exit.
- **L1 security through on-chain proof** — The bridge verifies Bitcoin transaction ancestry using Clarity 6's native `get-bitcoin-tx-output?`, with no merkle proofs or block headers needed. The deposit is anchored by the sBTC registry.
- **Quadratic voting without identity** — Esbee DAO achieves meaningful decentralization with sqrt-weighted voting over committed stakes. No identity system needed.
- **Zero operator trust for user funds** — The operator binds bonds, picks signers, and manages the skip, but can never touch deposits or prevent members from leaving.
- **Composability with PoX-5** — The pool follows PoX-5's bond lifecycle precisely, using the protocol's own roll mechanism rather than building a parallel state machine.

This is pooled Bitcoin staking at the protocol level: secure, permissionless, and governed by the people who stake.