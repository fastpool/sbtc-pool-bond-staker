# docs/

Longer notes than a contract comment has room for. Three kinds, and the
difference matters — one describes the contracts as they are, one describes work
that is meant to happen, and one describes roads not taken.

## Reference

About code that is deployed or about to be. These are meant to stay true; if
one disagrees with a contract, the contract is right and the note is stale.

| note | about |
| --- | --- |
| [address-front-running.md](address-front-running.md) | Why `bond-bridge` commits before it reveals, why the wait is two bitcoin blocks, what it does and does not protect, and how BNS-V2's version of the same race differs |

## Planned

Designed and not built, but meant to be. Unlike the shelved notes, these are
proposals someone is expected to act on or reject on the merits.

| note | designed | what it would do |
| --- | --- | --- |

## Talk

[talk/](talk/) is the esbee DAO talk on bitcoin staking through this pool: the
[article](talk/article-bond-staker-esbee-dao.md), the
[slides](talk/slides-bitcoin-staking-esbee-dao.md) in markdown, and the two
scripts that render them -- `pnpm build:slides` for the PDF (LibreOffice
Writer), `pnpm build:site` for the self-contained reveal.js page in `site/`
that `pnpm deploy:site` publishes.

## Shelved

Design work that was done and then parked. Nothing here is built, and nothing
here is a plan of record.

The point of keeping it is that the expensive part of a design is rarely the
design. It is the two afternoons spent finding out which shapes the language
will not let you have, and those findings survive the idea that prompted them.

| note | shelved | what it was |
| --- | --- | --- |
| [sip-013-receipt-token.md](sip-013-receipt-token.md) | 2026-08-26 | Replacing `bond-treasury` with a non-transferable SIP-013 semi-fungible token, so a depositor holds something for their sats |
| [sip-013-transferable.md](sip-013-transferable.md) | 2026-08-26 | The same, made tradeable |
| [tagged-reward-claims.md](tagged-reward-claims.md) | 2026-08-29 | Attribute reward sBTC by the cycle it was earned in rather than the burn height it arrived at, closing the residual half of #2 |

