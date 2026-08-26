# Front-running an address announcement

Why `bond-bridge` makes a member commit to an address before naming it, why the
wait is measured in bitcoin blocks, why it is two of them, and what it does and
does not protect. Written against `bond-bridge.clar` at `6935241`.

The short version: the delay is not what keeps a member's money safe. The rule
*wait for your reveal to confirm before you send* is. The delay decides how
often an honest member has to retry, and it is set so that losing means a
visibly stuck transaction rather than invisible bad luck.

## What is being defended

`announcements` maps a bitcoin `script` to the member who claimed it. When a
deposit is swept, `complete-btc-deposit` reads that map to decide whose sats
they are. Whoever holds the entry gets credited.

The map is written by `map-insert`, so **the first writer wins** and holds the
address until `ANNOUNCE_TTL` (1000 burn blocks, ~7 days) or until they cancel.

An attacker wants that entry to name them, so that a deposit somebody else sends
is credited to the attacker.

## The attack

The attacker needs the script. There is exactly one place to get it: the
victim's `reveal-btc-address` transaction, sitting unconfirmed in the Stacks
mempool in the clear. The commit tells them nothing — it is
`sha256(script ‖ salt)`.

    1. victim commits at burn height N          attacker learns nothing
    2. victim broadcasts the reveal             now the script is visible
    3. attacker reads the script out of it
    4. attacker submits their own commit
    5. attacker waits out REVEAL_DELAY
    6. attacker submits their reveal
    7. whichever reveal is mined first takes the address; the loser gets
       ERR_ADDRESS_ANNOUNCED (u303)

The attacker wins only if the victim's reveal is **still unmined** when the
attacker's reveal is mined. Everything below is about widening that gap.

### The attacker cannot reuse the victim's commitment

This is the part that is easy to get wrong. `reveal-btc-address` looks the
commitment up by *both* member and digest:

```clarity
(member tx-sender)
(digest (unwrap! (get-address-digest address salt) ERR_UNSUPPORTED_ADDRESS))
(commitment (unwrap!
  (map-get? commitments { member: member, digest: digest })
  ERR_UNKNOWN_COMMITMENT))
```

Suppose the attacker copies the reveal verbatim — same address, **same salt**.
The digest they compute is byte-identical, since a digest is only a function of
`script` and `salt`. It still fails: the lookup is `{member: attacker, digest}`
and the only entry that exists is `{member: victim, digest}`. They get
`ERR_UNKNOWN_COMMITMENT (u312)`.

So the attacker has to create their own commitment, and `committed-at-height`
on *theirs* is what `REVEAL_DELAY` is measured from. That is why step 5 exists
and cannot be skipped.

`tests/bond-bridge.test.ts` pins this both ways: a copied digest blocks nobody
from committing, and a racer who does the whole flow still loses the insert.

### The timeline

    t=0s   victim's reveal enters the mempool   ← must be mined before t=r
    t=1s   attacker reads the address out of it
    t=1s   attacker submits commit-btc-address  ← this part is fast
    t=5s   attacker's commit is mined at height N
           ...
           attacker waits: burn-block-height >= N + REVEAL_DELAY
           ...
    t=r    attacker's reveal is mined

The victim only has to beat `t=r`. The wait starts when the *attacker's* commit
lands, not when the victim's did.

## Why the clock is burn blocks

An attacker can buy priority in the Stacks mempool with fees. They cannot buy a
bitcoin block. It is the one clock in the system they do not control, which is
the only reason the wait means anything.

| `REVEAL_DELAY` unit | attacker's mandatory wait | so the victim's reveal must be mined within |
| --- | --- | --- |
| 2 Stacks blocks | 2 Stacks blocks | ~20 seconds |
| 2 burn blocks | ≥ 1 full bitcoin block | ~10 minutes |

Both are the same attack. What differs is the failure mode:

- At ~20 seconds, losing means being slightly outbid. Someone paying 100× fees
  on two transactions wins routinely, and the member never learns why.
- At ~10 minutes, losing means the reveal sat unmined for ten minutes — a fee
  problem visible in the mempool and fixable by bumping.

The ratio of those windows is about 60×. That is a ratio of *time*, not of
attack success; do not read it as "sixty times safer".

## Why two, not one

`burn-block-height` is per **tenure**, and every Stacks block inside a tenure
reports the same value.

At `u1`, a commit landing in the last Stacks block of tenure N can be revealed
in the *first* Stacks block of tenure N+1 — seconds later in wall clock, and a
legal `>= N + 1`. So the guaranteed margin was zero, and the expected margin was
however long happened to be left until the next bitcoin block. Bitcoin block
arrivals are memoryless, so from a random moment that wait is exponential with a
ten-minute mean: roughly one attempt in ten gives a window under a minute, one
in five under two.

At `u2` the whole of tenure N+1 must pass, whichever moment inside tenure N the
commit landed in. The floor becomes a full bitcoin block rather than a ceiling.

    u1    tenure N                      │ tenure N+1
          ──────────────────────────────┼──────────────────────
           attacker commits ────────────┤
                                        └→ may reveal
                                           gap = time to next bitcoin block

    u2    tenure N          │ tenure N+1         │ tenure N+2
          ──────────────────┼────────────────────┼──────────────
           attacker commits ┤                    │
                            └────────────────────┴→ may reveal
                                gap ≥ one whole bitcoin block

The cost is up to two bitcoin blocks before a member may broadcast, against a
deposit that then waits hours on the sBTC sweep. The latency is free in
context.

## What it does not do

**It does not make the race unwinnable.** If the victim's reveal is genuinely
stuck, the attacker still wins. `u2` changes the odds, not the outcome space.

**It is not what protects the member's money.** If the attacker wins, the
victim's reveal *fails*. No bitcoin has moved. The victim's commitment survives
the failed transaction, `cancel-btc-commitment` returns the STX leg, and they
try again with a fresh address. Total cost: two transaction fees.

The attack only pays if the victim sends bitcoin **without checking that their
reveal confirmed**. No value of `REVEAL_DELAY` fixes that, which is why the rule
is stated in the contract header, in the README, and here.

**It does not stop squatting an address that is already public.** An address
seen anywhere on bitcoin can be committed to by anyone at any time and revealed
before its owner gets there. The defence is a fresh address, not the delay.

**A hit-and-run squat is nearly free.** `cancel-btc-deposit` lets the announcer
cancel their own announcement at any height and take the STX back. Squatting
only costs the attacker if they *hold* the address — and holding it is what
locks their STX and occupies pool allocation room. A squat they immediately drop
costs them a fee and achieves nothing.

## What a member should do

In order of effect:

1. **Use the fast lane.** `claim-btc-address` has no race at all — see below.
2. **Wait for the reveal to confirm before broadcasting**, and send only from
   the address it revealed. This is the one that actually protects the money.
3. **Use a fresh address.** One already visible on bitcoin can be pre-committed
   at leisure, and no delay helps.
4. If a reveal fails with `u303`, cancel the commitment and retry with a
   different address.

## Why BNS-V2 can lean on its delay less

BNS-V2 (`SP2QEZ06AGJ3RKJPBV14SY1V5BBFNAW33D96YPGZF.BNS-V2`) runs the same
commit-and-reveal over a scarcer resource, and it is worth knowing exactly how
it differs — the surface similarity invites copying the wrong half.

**It has a delay too, and for names it is stricter than this contract's.**

```clarity
;; name-register, line 1161 — note `>` not `>=`, so this is two burn blocks
(asserts! (> burn-block-height (+ (get created-at preorder) u1))
          ERR-NAME-NOT-CLAIMABLE-YET)

;; namespace-reveal, line 769 — one burn block
(asserts! (>= burn-block-height (+ (get created-at preorder) u1))
          ERR-OPERATION-UNAUTHORIZED)
```

**But the delay is not what protects it.** This is:

```clarity
;; handle-existing-name, line 1698 — the name is already registered
(asserts! (> incumbent-preorder-height contract-caller-preorder-height)
          ERR-PREORDERED-BEFORE)
```

A later registrant **takes the name** if their preorder is older. So a contest
is settled by a stored fact — preorder height — and mining order decides
nothing. An attacker reacting to a `name-register` necessarily has a later
preorder, so they lose even if they register first; the victim simply registers
afterwards and takes it back.

(`name-single-preorder`, the map keyed by hash alone at line 163, does not close
the race either way. The attacker picks a different salt for the same name and
gets a different hash.)

### Why that rule cannot be copied here

BNS **creates** the name. It does not exist before registration, so BNS is free
to define who deserves it, and chose "whoever committed earliest". That is a
policy question with a defensible answer.

An announcement creates nothing. The address already exists on bitcoin, owned by
whoever holds the key, and `announcements[script]` is only a routing hint —
"sats arriving from this script are mine". So:

- BNS asks **who should get this name?** — answerable by policy.
- This contract asks **whose bitcoin is this?** — a fact about the world that
  commit timestamps cannot adjudicate.

Adopting earliest-commitment-wins here would be actively dangerous. An attacker
pre-committing to addresses seen on bitcoin would hold *older* commitments than
the real owners and could displace them. In BNS that attack burns STX per name
and yields names nobody wanted; here it would steal deposits from people who
genuinely own the addresses.

First-writer-wins is not laziness. It is what is left when there is no safe fact
to rank by — which leaves arrival time, which is why the window carries the
whole load.

## The fast lane is the real answer

`claim-btc-address` needs no delay because it has what BNS has: an ordering
principle that is not arrival time. Not *who was first* but *who can prove it*.
A signature over `get-address-claim-message` is a fact about the world, and it
is the only one available for an externally-owned address.

It covers every shape whose `hashbytes` can be rebuilt from a public key —
p2pkh (either key encoding), p2sh-p2wpkh, p2wpkh. For those there is nothing to
copy out of the mempool and nothing to wait for.

The remaining four — plain p2sh, p2sh-p2wsh, p2wsh, p2tr — hash a script this
contract never sees, or a key tweaked by one. They keep the commitment, and the
analysis above is entirely about them.

## Rejected: measuring the delay in Stacks blocks

Considered so a member waits ~10 seconds instead of ~10 minutes, and rejected:
it lands *below* where `u1` started. The attacker's cost is not the delay itself
but fitting a commit and a reveal around it before the victim's reveal is mined,
and in Stacks blocks that whole sequence closes in about three blocks while the
attacker bids both of their transactions to the front.

If the latency ever does need cutting, the shape that works is **whichever comes
first** — a floor in wall clock rather than in tenures:

```clarity
(or (>= burn-block-height   (+ (get committed-at-height commitment) u2))
    (>= stacks-block-height (+ (get committed-at-stacks commitment) u100)))
```

That guarantees ~8 minutes regardless of where in a tenure the commit landed,
caps the worst case at ~8 minutes rather than ~20, and cannot be gamed by fees
in either arm — 100 Stacks blocks are no more purchasable than two bitcoin
blocks. It costs one extra field in `commitments`. Not built; the latency does
not currently justify it.
