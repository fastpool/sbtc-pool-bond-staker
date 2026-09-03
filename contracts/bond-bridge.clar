;; Bitcoin Staking Bond bridge, version 2
;;
;; L1 on-ramp and off-ramp for `bond-staker`: members join with bitcoin and
;; leave to bitcoin without holding sBTC. Calls `bond-staker` and
;; `bond-treasury`, is called by neither; deploy it last. Holds only the STX
;; legs of open commitments and announcements.
;;
;; Deposit: `commit-btc-address` (salted digest of the funding address), then
;; `reveal-btc-address` REVEAL_DELAY burn blocks later (first reveal takes the
;; address), then send from that address only, then `complete-btc-deposit`
;; once the sBTC signers have swept it. `claim-btc-address` replaces commit
;; and reveal for p2pkh, p2sh-p2wpkh, p2wpkh: a signature by the address key.
;; Every input of the deposit tx must be locked to the announced script, and
;; the announcement must predate the sweep. Credited for the swept amount.
;; Withdraw: `claim-principal-to-btc` requests via `bond-treasury`;
;; `reclaim-btc-withdrawal` settles the signers' verdict.

(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_INVALID_AMOUNT (err u301))
(define-constant ERR_UNKNOWN_ANNOUNCEMENT (err u302))
(define-constant ERR_ADDRESS_ANNOUNCED (err u303))
(define-constant ERR_DEPOSIT_NOT_SWEPT (err u304))
(define-constant ERR_DEPOSIT_MISDIRECTED (err u305))
;; u306 retired (ERR_DEPOSIT_TOO_SMALL): a short deposit is credited for what
;; arrived. Number kept reserved.
(define-constant ERR_DEPOSIT_CREDITED (err u307))
(define-constant ERR_ANNOUNCEMENT_LIVE (err u308))
(define-constant ERR_UNKNOWN_WITHDRAWAL (err u309))
(define-constant ERR_WITHDRAWAL_PENDING (err u310))
(define-constant ERR_NOTHING_RELEASED (err u311))
(define-constant ERR_UNKNOWN_COMMITMENT (err u312))
(define-constant ERR_COMMITMENT_EXISTS (err u313))
(define-constant ERR_REVEAL_TOO_SOON (err u314))
(define-constant ERR_UNSUPPORTED_ADDRESS (err u315))
(define-constant ERR_TXID_MISMATCH (err u316))
(define-constant ERR_MALFORMED_TX (err u317))
(define-constant ERR_INPUT_COUNT (err u318))
(define-constant ERR_PARENT_MISMATCH (err u319))
(define-constant ERR_FOREIGN_INPUT (err u320))
(define-constant ERR_ANNOUNCED_TOO_LATE (err u321))
(define-constant ERR_UNPROVABLE_ADDRESS (err u322))
(define-constant ERR_WRONG_KEY (err u323))
(define-constant ERR_BAD_SIGNATURE (err u324))

;; Error codes carried through the `check-input` fold (no `err` from a fold).
(define-constant CHECK_OK u0)
(define-constant CHECK_MALFORMED u317)
(define-constant CHECK_PARENT u319)
(define-constant CHECK_FOREIGN u320)

;; Burn blocks a revealed announcement holds its address and pool room before
;; anyone may cancel it (about a week; a sweep takes hours).
(define-constant ANNOUNCE_TTL u1000)

;; Burn blocks an unrevealed commitment holds pool room before anyone may
;; cancel it (about six hours; nothing is in flight yet).
(define-constant COMMIT_TTL u36)

;; Burn blocks between commit and reveal. u2 guarantees a full bitcoin block:
;; a mempool copier must commit and wait this long before their own reveal.
(define-constant REVEAL_DELAY u2)

;;; The fast lane: `claim-btc-address`
;; Shapes whose hashbytes derive from a public key alone: p2pkh (either key
;; encoding), p2sh-p2wpkh, p2wpkh. p2sh, p2wsh, p2tr keep commit and reveal.

;; Lowercase hex digits, one byte each.
(define-constant HEX_DIGITS 0x30313233343536373839616263646566)

;; Prefix bitcoin's `signmessage` puts before a message: length byte, then
;; "Bitcoin Signed Message:\n".
(define-constant BTC_SIGNED_MESSAGE 0x18426974636f696e205369676e6564204d6573736167653a0a)

;; "fastpool bond address claim: "; with the 40 hex digits that follow, the
;; signed message is 69 bytes (CLAIM_LENGTH 0x45).
(define-constant CLAIM_PREFIX 0x66617374706f6f6c20626f6e64206164647265737320636c61696d3a20)
(define-constant CLAIM_LENGTH 0x45)

;; Most inputs a deposit tx may have; each needs its parent tx passed in.
;; Parent size is unbounded.
(define-constant MAX_INPUTS u8)

;; Fold driver: one `read-input` step per byte; the bytes are not read.
(define-constant INPUT_SLOTS 0x0000000000000000)

;; Positions for `check-input`, which walks inputs and parents side by side.
(define-constant INPUT_INDEXES (list u0 u1 u2 u3 u4 u5 u6 u7))

;; Keyed by member too, so a digest copied from the mempool cannot block the
;; member's own commit.
(define-map commitments
  {
    member: principal,
    digest: (buff 32),
  }
  {
    sats: uint,
    ustx: uint,
    committed-at-height: uint,
  }
)

;; Keyed by scriptPubKey, not address: it is what `check-input` reads from
;; parents, and the three p2sh-shaped versions lock to one script.
(define-map announcements
  (buff 34)
  {
    member: principal,
    sats: uint,
    ustx: uint,
    announced-at-height: uint,
  }
)

;; Credited bitcoin outputs; one credit per outpoint.
(define-map credited
  {
    txid: (buff 32),
    vout-index: uint,
  }
  {
    member: principal,
    sats: uint,
  }
)

(define-map withdrawals
  uint
  {
    member: principal,
    sats: uint,
  }
)

;;; Reading bitcoin
;; `get-bitcoin-tx-output?` reads outputs and txids; inputs are walked here,
;; over a tx the sBTC registry vouched for, so no read can run past the end.

;; Little-endian integer of `size` (<= 8) bytes at `at`.
(define-private (read-le
    (tx (buff 65536))
    (at uint)
    (size uint)
  )
  (buff-to-uint-le (unwrap-panic (as-max-len? (default-to 0x00 (slice? tx at (+ at size))) u16)))
)

;; Bitcoin varint at `at`: value and the offset just past it.
(define-private (read-varint
    (tx (buff 65536))
    (at uint)
  )
  (let ((marker (read-le tx at u1)))
    (if (< marker u253)
      {
        value: marker,
        next: (+ at u1),
      }
      (if (is-eq marker u253)
        {
          value: (read-le tx (+ at u1) u2),
          next: (+ at u3),
        }
        (if (is-eq marker u254)
          {
            value: (read-le tx (+ at u1) u4),
            next: (+ at u5),
          }
          {
            value: (read-le tx (+ at u1) u8),
            next: (+ at u9),
          }
        )
      )
    )
  )
)

;; Offset just past the input at `at`: txid 32, vout 4, scriptSig (varint,
;; bytes), sequence 4.
(define-private (input-end
    (tx (buff 65536))
    (at uint)
  )
  (let ((script (read-varint tx (+ at u36))))
    (+ (get next script) (get value script) u4)
  )
)

(define-private (read-input
    (slot (buff 1))
    (state {
      tx: (buff 65536),
      cursor: uint,
      left: uint,
      inputs: (list 8 {
        txid: (buff 32),
        index: uint,
      }),
    })
  )
  (if (is-eq (get left state) u0)
    state
    (let (
        (tx (get tx state))
        (at (get cursor state))
      )
      (merge state {
        cursor: (input-end tx at),
        left: (- (get left state) u1),
        inputs: (default-to (get inputs state)
          (as-max-len?
            (append (get inputs state) {
              ;; Internal byte order, as `get-bitcoin-tx-output?` returns.
              txid: (unwrap-panic (as-max-len? (default-to 0x (slice? tx at (+ at u32))) u32)),
              index: (read-le tx (+ at u32) u4),
            })
            u8
          )),
      })
    )
  )
)

;; Outpoints spent by `tx`; `none` for zero inputs or more than MAX_INPUTS.
(define-private (parse-inputs (tx (buff 65536)))
  (let (
      ;; Skip version, and marker+flag (0x0001) of a witness serialization.
      (at (if (and (is-eq (read-le tx u4 u1) u0) (is-eq (read-le tx u5 u1) u1))
        u6
        u4
      ))
      (count (read-varint tx at))
    )
    (if (or (is-eq (get value count) u0) (> (get value count) MAX_INPUTS))
      none
      (some (get inputs
        (fold read-input INPUT_SLOTS {
          tx: tx,
          cursor: (get next count),
          left: (get value count),
          inputs: (list),
        })
      ))
    )
  )
)

;; Input `position` against its parent: the parent's txid must be the one
;; the input names, and the spent output must be locked to `script`.
(define-private (check-input
    (position uint)
    (state {
      inputs: (list 8 {
        txid: (buff 32),
        index: uint,
      }),
      parents: (list 8 (buff 65536)),
      script: (buff 34),
      error: uint,
    })
  )
  (match (element-at? (get inputs state) position)
    input (if (not (is-eq (get error state) CHECK_OK))
      state
      (match (get-bitcoin-tx-output?
        (default-to 0x (element-at? (get parents state) position))
        (get index input)
      )
        output (if (not (is-eq (get txid output) (get txid input)))
          (merge state { error: CHECK_PARENT })
          (if (is-eq (get script output) (get script state))
            state
            (merge state { error: CHECK_FOREIGN })
          )
        )
        parse-error (merge state { error: CHECK_MALFORMED })
      )
    )
    state
  )
)

;; Byte reversal: internal txid order to the display order the sBTC registry
;; keys by.
(define-private (prepend-byte
    (byte (buff 1))
    (acc (buff 32))
  )
  (unwrap-panic (as-max-len? (concat byte acc) u32))
)

(define-private (reverse-32 (input (buff 32)))
  (fold prepend-byte input 0x)
)

;;; Read-only

;; Where a deposit must be minted. sBTC sent to `bond-staker` is reward.
(define-read-only (get-deposit-address)
  .bond-treasury
)

;; scriptPubKey of an address in the sBTC `{version, hashbytes}` shape;
;; `none` for anything but the six shapes below.
(define-read-only (get-address-script (address {
  version: (buff 1),
  hashbytes: (buff 32),
}))
  (let (
      (version (get version address))
      (hash (get hashbytes address))
      (short (is-eq (len hash) u20))
      (long (is-eq (len hash) u32))
    )
    (if (and (is-eq version 0x00) short)
      ;; p2pkh: OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
      (as-max-len? (concat 0x76a914 hash 0x88ac) u34)
      (if (and
          ;; p2sh, p2sh-p2wpkh, p2sh-p2wsh: one script on chain.
          (or
            (is-eq version 0x01)
            (is-eq version 0x02)
            (is-eq version 0x03)
          )
          short
        )
        ;; OP_HASH160 <20> OP_EQUAL
        (as-max-len? (concat 0xa914 hash 0x87) u34)
        (if (and (is-eq version 0x04) short)
          ;; p2wpkh: OP_0 <20>
          (some (concat 0x0014 hash))
          (if (and (is-eq version 0x05) long)
            ;; p2wsh: OP_0 <32>
            (some (concat 0x0020 hash))
            (if (and (is-eq version 0x06) long)
              ;; p2tr: OP_1 <32>
              (some (concat 0x5120 hash))
              none
            )
          )
        )
      )
    )
  )
)

;; Digest for `commit-btc-address`: sha256 over the script and a 32-byte
;; salt the member keeps until the reveal.
(define-read-only (get-address-digest
    (address {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (salt (buff 32))
  )
  (match (get-address-script address)
    script (some (sha256 (unwrap-panic (to-consensus-buff? {
      script: script,
      salt: salt,
    }))))
    none
  )
)

(define-private (hex-digit (nibble uint))
  (unwrap-panic (element-at? HEX_DIGITS nibble))
)

(define-private (hex-byte
    (byte (buff 1))
    (acc (buff 40))
  )
  (let ((value (buff-to-uint-be byte)))
    (unwrap-panic (as-max-len?
      (concat acc (hex-digit (/ value u16)) (hex-digit (mod value u16)))
      u40
    ))
  )
)

;; ASCII message a member signs for `claim-btc-address`: binds member and
;; contract; the address is bound by checking the signature against its key.
(define-read-only (get-address-claim-message (member principal))
  (concat CLAIM_PREFIX
    (fold hex-byte
      (hash160 (unwrap-panic (to-consensus-buff? {
        contract: current-contract,
        member: member,
      })))
      0x
    ))
)

;; What a wallet's `signmessage` hashes for that message: double sha256 over
;; prefix, length and message.
(define-read-only (get-address-claim-digest (member principal))
  (sha256 (sha256
    (concat BTC_SIGNED_MESSAGE CLAIM_LENGTH (get-address-claim-message member))
  ))
)

;; Whether `claim-btc-address` takes the shape: p2pkh, p2sh-p2wpkh, p2wpkh.
(define-read-only (is-provable-address (address {
  version: (buff 1),
  hashbytes: (buff 32),
}))
  (and
    (or
      ;; p2pkh
      (is-eq (get version address) 0x00)
      ;; p2sh-p2wpkh
      (is-eq (get version address) 0x02)
      ;; p2wpkh
      (is-eq (get version address) 0x04)
    )
    (is-eq (len (get hashbytes address)) u20)
  )
)

;; Whether `hashbytes` derives from `public-key` under the address version;
;; false for shapes that cannot be rebuilt.
(define-private (address-matches-key
    (address {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (public-key (buff 33))
  )
  (let (
      (version (get version address))
      (hash (get hashbytes address))
      (keyhash (hash160 public-key))
    )
    (if (is-eq version 0x00)
      ;; p2pkh may hash the compressed or the uncompressed key.
      (or
        (is-eq hash keyhash)
        (is-eq hash (hash160 (unwrap! (secp256k1-decompress? public-key) false)))
      )
      (if (is-eq version 0x02)
        ;; p2sh-p2wpkh: hash160 of the key's p2wpkh witness program.
        (is-eq hash (hash160 (concat 0x0014 keyhash)))
        ;; p2wpkh: compressed key only.
        (and (is-eq version 0x04) (is-eq hash keyhash))
      )
    )
  )
)

(define-read-only (get-commitment
    (member principal)
    (digest (buff 32))
  )
  (map-get? commitments {
    member: member,
    digest: digest,
  })
)

(define-read-only (get-announcement (address {
  version: (buff 1),
  hashbytes: (buff 32),
}))
  (match (get-address-script address)
    script (map-get? announcements script)
    none
  )
)

;; `get-announcement` by script, as the events carry it.
(define-read-only (get-announcement-by-script (script (buff 34)))
  (map-get? announcements script)
)

(define-read-only (get-credited-deposit
    (txid (buff 32))
    (vout-index uint)
  )
  (map-get? credited {
    txid: txid,
    vout-index: vout-index,
  })
)

(define-read-only (get-withdrawal (request-id uint))
  (map-get? withdrawals request-id)
)

;; sBTC registry record of a deposit; `none` until swept.
(define-read-only (get-swept-deposit
    (txid (buff 32))
    (vout-index uint)
  )
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry
    get-completed-deposit txid vout-index
  )
)

;; STX leg for `sats` under the bond the pool is bound to.
(define-read-only (get-required-ustx (sats uint))
  (contract-call? .bond-staker get-required-ustx sats)
)

;; txid in display order, as the sBTC registry keys it; either serialization
(define-read-only (get-txid (tx (buff 65536)))
  (match (get-bitcoin-tx-output? tx u0)
    output (ok (reverse-32 (get txid output)))
    parse-error ERR_MALFORMED_TX
  )
)

;; The one scriptPubKey every input of `tx` is locked to, or the error
;; `complete-btc-deposit` would fail with. Does not check which tx this is.
(define-read-only (get-funding-script
    (tx (buff 65536))
    (parents (list 8 (buff 65536)))
  )
  (let ((inputs (unwrap! (parse-inputs tx) ERR_MALFORMED_TX)))
    (asserts! (is-eq (len inputs) (len parents)) ERR_INPUT_COUNT)
    (let (
        (first (unwrap! (element-at? inputs u0) ERR_INPUT_COUNT))
        (parent (unwrap! (element-at? parents u0) ERR_INPUT_COUNT))
        (funding (unwrap! (get-bitcoin-tx-output? parent (get index first))
          ERR_MALFORMED_TX
        ))
        ;; Refused early so an unrelated parent cannot pick the lookup
        ;; script; the fold below checks it again.
        (named (asserts! (is-eq (get txid funding) (get txid first)) ERR_PARENT_MISMATCH))
        ;; Longer than any supported address script: never announced.
        (script (unwrap! (as-max-len? (get script funding) u34) ERR_UNSUPPORTED_ADDRESS))
        (checked (fold check-input INPUT_INDEXES {
          inputs: inputs,
          parents: parents,
          script: script,
          error: CHECK_OK,
        }))
      )
      (asserts! (not (is-eq (get error checked) CHECK_MALFORMED))
        ERR_MALFORMED_TX
      )
      (asserts! (not (is-eq (get error checked) CHECK_PARENT))
        ERR_PARENT_MISMATCH
      )
      (asserts! (not (is-eq (get error checked) CHECK_FOREIGN)) ERR_FOREIGN_INPUT)
      (ok script)
    )
  )
)

;;; Coming in

;; Step 1: commit to the funding address (`get-address-digest`) and pay the
;; STX leg. Reserves `sats` of pool room from here on.
(define-public (commit-btc-address
    (digest (buff 32))
    (sats uint)
  )
  (let (
      (member tx-sender)
      ;; Reserves pool room and prices the STX leg; rejects an exiting
      ;; member, a closed stake window and sats the pool has no room for.
      (ustx (try! (contract-call? .bond-staker reserve-bridged-deposit member sats)))
    )
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    (asserts!
      (map-insert commitments {
        member: member,
        digest: digest,
      } {
        sats: sats,
        ustx: ustx,
        committed-at-height: burn-block-height,
      })
      ERR_COMMITMENT_EXISTS
    )

    ;; STX leg held here until the sats arrive.
    (try! (stx-transfer? ustx member current-contract))

    (let ((result {
        member: member,
        digest: digest,
        sats: sats,
        ustx: ustx,
        revealable-from: (+ burn-block-height REVEAL_DELAY),
        cancellable-from: (+ burn-block-height COMMIT_TTL),
      }))
      (print (merge { topic: "commit-btc-address" } result))
      (ok result)
    )
  )
)

;; Step 2: reveal the committed address and take it. Send only after this
;; has confirmed, and only from this address (every input).
(define-public (reveal-btc-address
    (address {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (salt (buff 32))
  )
  (let (
      (member tx-sender)
      (script (unwrap! (get-address-script address) ERR_UNSUPPORTED_ADDRESS))
      (digest (unwrap! (get-address-digest address salt) ERR_UNSUPPORTED_ADDRESS))
      (commitment (unwrap!
        (map-get? commitments {
          member: member,
          digest: digest,
        })
        ERR_UNKNOWN_COMMITMENT
      ))
      (sats (get sats commitment))
      (ustx (get ustx commitment))
    )
    (asserts!
      (>= burn-block-height (+ (get committed-at-height commitment) REVEAL_DELAY))
      ERR_REVEAL_TOO_SOON
    )
    ;; First reveal takes the address.
    (asserts!
      (map-insert announcements script {
        member: member,
        sats: sats,
        ustx: ustx,
        announced-at-height: burn-block-height,
      })
      ERR_ADDRESS_ANNOUNCED
    )
    (map-delete commitments {
      member: member,
      digest: digest,
    })

    (let ((result {
        member: member,
        address: address,
        script: script,
        sats: sats,
        ustx: ustx,
        deposit-to: (get-deposit-address),
        cancellable-from: (+ burn-block-height ANNOUNCE_TTL),
      }))
      (print (merge { topic: "reveal-btc-address" } result))
      (ok result)
    )
  )
)

;; Steps 1 and 2 in one call: `signature` over `get-address-claim-digest` by
;; the address key. An earlier unproven announcement wins; no eviction.
(define-public (claim-btc-address
    (address {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (public-key (buff 33))
    (signature (buff 65))
    (sats uint)
  )
  (let (
      (member tx-sender)
      (script (unwrap! (get-address-script address) ERR_UNSUPPORTED_ADDRESS))
      ;; Same reservation as the commit; any assert below unwinds it.
      (ustx (try! (contract-call? .bond-staker reserve-bridged-deposit member sats)))
    )
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    (asserts! (is-provable-address address) ERR_UNPROVABLE_ADDRESS)
    ;; The key must rebuild the address before its signature binds it.
    (asserts! (address-matches-key address public-key) ERR_WRONG_KEY)
    (asserts!
      (secp256k1-verify (get-address-claim-digest member) signature public-key)
      ERR_BAD_SIGNATURE
    )

    ;; First claim takes the address, same map as the reveal.
    (asserts!
      (map-insert announcements script {
        member: member,
        sats: sats,
        ustx: ustx,
        announced-at-height: burn-block-height,
      })
      ERR_ADDRESS_ANNOUNCED
    )

    ;; STX leg held here until the sats arrive.
    (try! (stx-transfer? ustx member current-contract))

    (let ((result {
        member: member,
        address: address,
        script: script,
        sats: sats,
        ustx: ustx,
        deposit-to: (get-deposit-address),
        cancellable-from: (+ burn-block-height ANNOUNCE_TTL),
      }))
      (print (merge { topic: "claim-btc-address" } result))
      (ok result)
    )
  )
)

;; Drop an unrevealed commitment and return its STX leg. Member any time;
;; anyone after COMMIT_TTL burn blocks.
(define-public (cancel-btc-commitment
    (member principal)
    (digest (buff 32))
  )
  (let (
      (commitment (unwrap!
        (map-get? commitments {
          member: member,
          digest: digest,
        })
        ERR_UNKNOWN_COMMITMENT
      ))
      (ustx (get ustx commitment))
    )
    (asserts!
      (or
        (is-eq tx-sender member)
        (>= burn-block-height (+ (get committed-at-height commitment) COMMIT_TTL))
      )
      ERR_ANNOUNCEMENT_LIVE
    )

    (map-delete commitments {
      member: member,
      digest: digest,
    })
    (try! (contract-call? .bond-staker abandon-bridged-deposit (get sats commitment)))
    (try! (as-contract? ((with-stx ustx)) (try! (stx-transfer? ustx tx-sender member))))

    (let ((result {
        member: member,
        digest: digest,
        sats: (get sats commitment),
        ustx: ustx,
      }))
      (print (merge { topic: "cancel-btc-commitment" } result))
      (ok result)
    )
  )
)

;; Step 5: credit a swept deposit to whoever announced its funding address.
;; `parents` is one tx per input of `tx`, in input order. Permissionless.
(define-public (complete-btc-deposit
    (txid (buff 32))
    (vout-index uint)
    (tx (buff 65536))
    (parents (list 8 (buff 65536)))
  )
  (let (
      (swept (unwrap! (get-swept-deposit txid vout-index) ERR_DEPOSIT_NOT_SWEPT))
      ;; `tx` must hash to the registry's txid; later reads rely on that.
      (authentic (asserts! (is-eq (try! (get-txid tx)) txid) ERR_TXID_MISMATCH))
      ;; The one script every input is locked to.
      (script (try! (get-funding-script tx parents)))
      (claim (unwrap! (map-get? announcements script) ERR_UNKNOWN_ANNOUNCEMENT))
      (member (get member claim))
      (announced (get sats claim))
      (ustx (get ustx claim))
      ;; Credited: what arrived, capped at what was announced.
      (credit (if (< (get amount swept) announced)
        (get amount swept)
        announced
      ))
    )
    ;; Minted anywhere but the treasury, the pool does not hold the sats.
    (asserts! (is-eq (get recipient swept) (get-deposit-address))
      ERR_DEPOSIT_MISDIRECTED
    )
    ;; Announcement must predate the sweep, or a swept deposit's funding
    ;; address could be claimed after the fact.
    (asserts! (< (get announced-at-height claim) (get sweep-burn-height swept))
      ERR_ANNOUNCED_TOO_LATE
    )
    ;; The signers' fee leaves the mint short of what was sent; a short
    ;; deposit is credited as is. Excess stays in the treasury unattributed.
    (asserts! (> (get amount swept) u0) ERR_INVALID_AMOUNT)
    ;; One credit per outpoint.
    (asserts!
      (map-insert credited {
        txid: txid,
        vout-index: vout-index,
      } {
        member: member,
        sats: credit,
      })
      ERR_DEPOSIT_CREDITED
    )

    (map-delete announcements script)
    ;; Release the room reserved for sats that never arrived.
    (if (< credit announced)
      (try! (contract-call? .bond-staker abandon-bridged-deposit (- announced credit)))
      true
    )
    ;; STX moves before the ledger counts it. The whole leg as priced at the
    ;; announcement; a leg sized for more sats only over-collateralises.
    (try! (as-contract? ((with-stx ustx))
      (try! (stx-transfer? ustx tx-sender .bond-staker))
    ))
    (try! (contract-call? .bond-staker credit-bridged-deposit member credit ustx))

    (let ((result {
        member: member,
        txid: txid,
        vout-index: vout-index,
        script: script,
        sats: credit,
        announced-sats: announced,
        ustx: ustx,
        swept-sats: (get amount swept),
      }))
      (print (merge { topic: "complete-btc-deposit" } result))
      (ok result)
    )
  )
)

;; Drop an announcement and return its STX leg. Member any time; anyone
;; after ANNOUNCE_TTL burn blocks. Never after sending: the sats are lost.
(define-public (cancel-btc-deposit (address {
  version: (buff 1),
  hashbytes: (buff 32),
}))
  (let (
      (script (unwrap! (get-address-script address) ERR_UNSUPPORTED_ADDRESS))
      (claim (unwrap! (map-get? announcements script) ERR_UNKNOWN_ANNOUNCEMENT))
      (member (get member claim))
      (ustx (get ustx claim))
    )
    (asserts!
      (or
        (is-eq tx-sender member)
        (>= burn-block-height (+ (get announced-at-height claim) ANNOUNCE_TTL))
      )
      ERR_ANNOUNCEMENT_LIVE
    )

    (map-delete announcements script)
    (try! (contract-call? .bond-staker abandon-bridged-deposit (get sats claim)))
    (try! (as-contract? ((with-stx ustx)) (try! (stx-transfer? ustx tx-sender member))))

    (let ((result {
        member: member,
        address: address,
        script: script,
        sats: (get sats claim),
        ustx: ustx,
      }))
      (print (merge { topic: "cancel-btc-deposit" } result))
      (ok result)
    )
  )
)

;;; Going out

;; Withdraw the caller's released sats to bitcoin: `released - max-fee` goes
;; out, unspent fee stays with the pool. STX leg via `claim-principal`.
(define-public (claim-principal-to-btc
    (recipient {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (max-fee uint)
  )
  (let (
      (member tx-sender)
      ;; Moves the released sats into the pool's withdrawing bucket.
      (locked (try! (contract-call? .bond-staker debit-released-for-bridge member max-fee)))
    )
    (let ((request-id (try! (contract-call? .bond-treasury request-btc-withdrawal (- locked max-fee)
        recipient max-fee
      ))))
      (map-set withdrawals request-id {
        member: member,
        sats: locked,
      })
      (let ((result {
          member: member,
          request-id: request-id,
          sats: locked,
          amount: (- locked max-fee),
          max-fee: max-fee,
          recipient: recipient,
        }))
        (print (merge { topic: "claim-principal-to-btc" } result))
        (ok result)
      )
    )
  )
)

;; Settle a withdrawal the sBTC signers have ruled on. Permissionless.
(define-public (reclaim-btc-withdrawal (request-id uint))
  (let (
      (request (unwrap! (get-withdrawal request-id) ERR_UNKNOWN_WITHDRAWAL))
      (bridged (unwrap!
        (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry
          get-withdrawal-request request-id
        )
        ERR_UNKNOWN_WITHDRAWAL
      ))
      (accepted (unwrap! (get status bridged) ERR_WITHDRAWAL_PENDING))
      (member (get member request))
      (sats (get sats request))
    )
    (map-delete withdrawals request-id)
    ;; Rejected: sBTC is back in the treasury, restore the member's claim.
    ;; Accepted: leftover `max-fee` is unattributed principal.
    (try! (contract-call? .bond-staker settle-bridge-withdrawal member sats accepted))

    (let ((result {
        member: member,
        request-id: request-id,
        sats: sats,
        accepted: accepted,
      }))
      (print (merge { topic: "reclaim-btc-withdrawal" } result))
      (ok result)
    )
  )
)
