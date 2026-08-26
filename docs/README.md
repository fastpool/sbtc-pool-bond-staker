# docs/

Longer notes than a contract comment has room for. Two kinds, and the
difference matters — one describes the contracts, the other describes roads not
taken.

## Reference

About code that is deployed or about to be. These are meant to stay true; if
one disagrees with a contract, the contract is right and the note is stale.

| note | about |
| --- | --- |
| [address-front-running.md](address-front-running.md) | Why `bond-bridge` commits before it reveals, why the wait is two bitcoin blocks, what it does and does not protect, and how BNS-V2's version of the same race differs |

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
