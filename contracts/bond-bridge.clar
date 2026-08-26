;; Bitcoin Staking Bond bridge, version 2
;;
;; The pool's L1 on-ramp and off-ramp. A member who holds bitcoin rather than
;; sBTC joins and leaves through here, and never has to handle sBTC at all.
;;
;; Coming in
;;
;; An sBTC deposit is a bare mint: the bridge's signers credit whichever
;; principal the bitcoin transaction named, and call nothing. A deposit
;; addressed to the pool therefore arrives with no record of who sent it, and
;; nothing on chain ties it to a member.
;;
;; So the member ties it themselves, in advance:
;;
;;   1. `commit-btc-address`    a hash of the address, on Stacks
;;   2. `reveal-btc-address`    the address itself, on Stacks
;;   3. broadcast               the bitcoin transaction, on L1
;;   4. wait                    for the sBTC signers to sweep it
;;   5. `complete-btc-deposit`  credit the member, on Stacks
;;
;; ...or, for an address whose key they can sign with, steps 1 and 2 collapse
;; into `claim-btc-address`: one call, no delay, and nothing to hide, because
;; a signature is not something a watcher can copy. See `the fast lane` below
;; for which addresses that covers and why the other four keep the commitment.
;;
;; What changed from version 1
;;
;; Version 1 committed to the *transaction*: a hash of its txid, then a reveal,
;; then the broadcast. A txid only exists once the transaction has been built
;; and signed, so the member had to drive their wallet in two halves -- sign
;; now, broadcast two Stacks transactions later -- and every wallet that cannot
;; hand back a signed-but-unbroadcast transaction was shut out.
;;
;; Version 2 commits to the *address* the bitcoin will come from. The member
;; already has one, so steps 1 and 2 need nothing built, and step 3 can then be
;; any wallet, any route, a plain "send" button.
;;
;; The commitment stays, because what it defends against has not changed. The
;; claim is made on Stacks, and anything sent to Stacks in the clear is visible
;; in the mempool before it confirms: an onlooker who saw an address announced
;; there could resend the same announcement with a higher fee, take the address,
;; and be credited for the bitcoin that followed. The commit closes that window
;; -- a salted digest names nothing -- and the reveal, one burn block later,
;; closes the copy of it: a commitment made after seeing the reveal is behind
;; that reveal, and first reveal takes the address.
;;
;; What the commitment cannot do is make an address secret that already is not.
;; An address seen anywhere on bitcoin can be committed to by anyone, at any
;; time, and revealed before its owner gets there. That costs the owner nothing
;; but the attempt: their reveal fails, they have sent no bitcoin, and any other
;; address of theirs will do -- a fresh one is not knowable at all. It costs the
;; squatter the STX leg for as long as they hold it.
;;
;; So the rule for the member is the same as version 1's, and just as strict:
;; do not send until the reveal has confirmed, and then send only from the
;; address it revealed.
;;
;; None of which the fast lane needs. A signature proves the address is yours
;; rather than hiding it until you have claimed it, so there is nothing for a
;; watcher to take: the claim names the member, and it only verifies against
;; the key the address hashes to. Where it can be used, it should be.
;;
;; Commitments are keyed by member as well as digest, so copying someone's
;; digest out of the mempool cannot deny them their own commit.
;;
;; Proving whose bitcoin it was
;;
;; A revealed address is only worth something if the pool can tell, on chain,
;; which address funded a given deposit. It can: at step 5 the caller hands over
;; the deposit transaction itself, and the parent transaction behind each of its
;; inputs. The chain of txids proves the rest.
;;
;;   the sBTC registry names a txid it swept -- authenticated by the signers
;;   the deposit transaction deserializes to that txid -- so those are its real
;;     inputs
;;   each parent deserializes to the txid its input names -- so those are its
;;     real outputs, and the one being spent carries the scriptPubKey that
;;     locked it
;;
;; `get-bitcoin-tx-output?` does the deserializing and reports the txid, so
;; every link is the node's own, not a hand-rolled parser's. No merkle proof and
;; no block header: the deposit is anchored by the registry, and everything else
;; is anchored to it.
;;
;; Every input must be locked to the revealed address. Not "at least one": a
;; transaction funded from two addresses would otherwise be claimable by either,
;; and an onlooker who saw it on bitcoin could commit to whichever of the two
;; was still free and take the deposit. Requiring all of them leaves exactly one
;; address that can ever claim a transaction, and the member fixed it before
;; they sent it.
;;
;; A deposit whose announcement has lapsed can still be finished by committing
;; to the address again, as long as the reveal happens before the sBTC signers
;; sweep it -- `complete-btc-deposit` will not credit an announcement younger
;; than the sweep. That is the guard against the one theft this shape would
;; otherwise allow: watching bitcoin for a swept deposit, then claiming the
;; address that funded it after the fact.
;;
;; What this costs the member is the bytes: a deposit may have at most
;; MAX_INPUTS inputs, and every one of them means handing its parent over too.
;; Nothing bounds the parents themselves -- an output three hundred down an
;; exchange payout batch is read as readily as the first -- and either
;; serialization will do, witnesses or not, so a client can pass an explorer's
;; hex through untouched.
;;
;; Going out
;;
;; `claim-principal-to-btc` hands a member's released principal to the sBTC
;; signers to pay out on bitcoin. The request is made by `bond-treasury`, not by
;; this contract: the bridge unlocks sBTC back to the *requester* when it
;; rejects a request, and that has to land somewhere the pool counts as
;; principal. `reclaim-btc-withdrawal` then settles the outcome.
;;
;; Where this contract sits
;;
;;   bond-treasury   holds the sBTC principal
;;   bond-staker     the ledger: members, epochs, shares, the bond position
;;   bond-bridge  this contract; calls the two above, and is called by
;;                   neither
;;
;; Deploy it last. It holds nothing but the STX legs of announcements that have
;; not been completed yet.

(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_INVALID_AMOUNT (err u301))
(define-constant ERR_UNKNOWN_ANNOUNCEMENT (err u302))
(define-constant ERR_ADDRESS_ANNOUNCED (err u303))
(define-constant ERR_DEPOSIT_NOT_SWEPT (err u304))
(define-constant ERR_DEPOSIT_MISDIRECTED (err u305))
;; Retired: a deposit short of its announcement is credited for what arrived.
;; The number stays reserved so the rest do not shift under existing clients.
;; (define-constant ERR_DEPOSIT_TOO_SMALL (err u306))
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

;; The codes the input check reports through its fold, which cannot return an
;; `err` from inside.
(define-constant CHECK_OK u0)
(define-constant CHECK_MALFORMED u317)
(define-constant CHECK_PARENT u319)
(define-constant CHECK_FOREIGN u320)

;; How long a revealed announcement holds its allocation and its address before
;; anyone may cancel it and hand the STX leg back. A sweep takes hours; a week
;; of slack means a deposit in flight is never cancelled from under its owner,
;; while an announcement that goes nowhere cannot squat on the pool's room --
;; or on an address -- forever.
(define-constant ANNOUNCE_TTL u1000)

;; The same, for a commitment that was never revealed -- and much shorter,
;; because a commitment is not a deposit in flight. Nothing has been sent, and
;; the member is not waiting on bitcoin to do anything: in the ordinary flow the
;; reveal follows a couple of blocks later. Six hours is generous against a stalled
;; wallet while leaving a squatter far less room to hold the pool's allocation
;; -- or somebody's address -- for.
;;
;; It costs the squatter either way, the STX leg being locked for as long as the
;; commitment stands, but a week of that per commit is a lot of leverage for the
;; price.
(define-constant COMMIT_TTL u36)

;; How long a commitment has to sit before it may be revealed.
;;
;; What it is for: an announcement is settled by whichever reveal is mined
;; first, and a reveal names the address in the clear, so an onlooker who sees
;; one in the mempool can open their own commitment against it and race. The
;; delay is the margin the honest reveal has to get mined in -- the attacker
;; has to fit a commit *and* a reveal around the same wait, so they only win if
;; the reveal they are copying stays unmined for longer than the delay.
;;
;; Burn blocks, because a burn block is the one clock an attacker cannot pay to
;; speed up. In Stacks blocks the same two-step sequence closes in seconds, and
;; seconds is a margin fee competition eats: the copier bids both of their
;; transactions to the front while the reveal they are racing sits where it
;; was.
;;
;; Two rather than one, because `burn-block-height` is per *tenure* and every
;; Stacks block within a tenure reports the same one. At u1 a commit landing in
;; the last Stacks block of tenure N can reveal in the first of tenure N+1,
;; seconds later -- so the guaranteed margin was zero and the expected one was
;; however long until the next bitcoin block. At u2 the whole of tenure N+1 has
;; to pass whenever in its tenure the commit landed, so the floor is a full
;; bitcoin block rather than a ceiling.
;;
;; It does not make the race unwinnable, and it is not what protects the
;; member's money: a lost race costs nothing to anyone who follows the rule
;; above and waits for their reveal to confirm before sending. What it buys is
;; that losing takes a reveal genuinely stuck for ten minutes rather than one
;; unlucky moment, which is a fee problem a member can see and fix.
;;
;; BNS-V2 asks the same of a name -- `> created-at + u1`, so two -- for what is
;; the same race over a scarcer thing. It can afford to lean on the delay less
;; than this contract can: a contested name there is settled by comparing
;; preorder heights, so mining order decides nothing, while an announcement
;; here is settled by whoever inserts first.
;;
;; The cost is up to two bitcoin blocks before sending, against a deposit that
;; then waits on the sBTC sweep, which is hours. Members whose address can be
;; proven skip all of it -- see `claim-btc-address`.
(define-constant REVEAL_DELAY u2)

;;; The fast lane
;;
;; Everything above races for an address. This proves one instead: a member who
;; can sign with the address's own key does not have to hide it first, because
;; nobody else can produce the signature. No commit, no delay, no window for an
;; onlooker to squat in -- one call.
;;
;; It covers every shape whose `hashbytes` can be rebuilt from a public key and
;; nothing else, which is three of the seven:
;;
;;   p2pkh         hash160 of the key, in either encoding
;;   p2sh-p2wpkh   hash160 of the key's own witness program, which is itself
;;                 hash160 of the key -- a hash of a hash, and no more
;;   p2wpkh        hash160 of the key
;;
;; The other four cannot be. Plain p2sh and p2sh-p2wsh hash a script this
;; contract never sees; p2wsh the same; p2tr holds a key tweaked by one, and
;; Clarity has no curve arithmetic to undo the tweak. They keep the commit and
;; the reveal, which is why both paths stay.
;;
;; p2tr is the near miss. A key-path output key is a real point, so an ECDSA
;; signature over it would verify -- but a wallet signing a taproot message
;; produces Schnorr, and there is no `schnorr-verify` to check it with.
;;
;; A legacy p2pkh may hash the *uncompressed* key, which is a different 65
;; bytes and so a different address. `secp256k1-decompress?` turns the one the
;; caller hands over into the other, so an old key reaches its old address
;; without the caller having to say which encoding it was made with. Segwit
;; allows only the compressed form, so the question does not arise for the
;; other two.

;; Lowercase hex, one byte per digit.
(define-constant HEX_DIGITS 0x30313233343536373839616263646566)

;; What bitcoin puts in front of anything a wallet signs with `signmessage`:
;; a length byte and then "Bitcoin Signed Message:\n". Signing the claim in
;; that format is what lets an ordinary wallet produce it at all -- the same
;; reason version 2 commits to an address rather than a transaction.
(define-constant BTC_SIGNED_MESSAGE 0x18426974636f696e205369676e6564204d6573736167653a0a)

;; "fastpool bond address claim: ", the readable half of what gets signed. The
;; 40 hex digits after it bring the message to 69 bytes, hence the 0x45 length
;; that follows the prefix above.
(define-constant CLAIM_PREFIX 0x66617374706f6f6c20626f6e64206164647265737320636c61696d3a20)
(define-constant CLAIM_LENGTH 0x45)

;; How many inputs a deposit transaction may have. Each one costs a parent
;; transaction to hand over and a scriptPubKey to check, and a transaction with
;; more is refused rather than half-read. Nothing bounds the *parents*: the
;; builtin that reads them takes a transaction of any size.
(define-constant MAX_INPUTS u8)

;; Loop driver. Clarity has no counted loop; `fold` over a buffer runs its step
;; once per byte, and this one is never read -- only counted.
(define-constant INPUT_SLOTS 0x0000000000000000)

;; Positions in a list of inputs, for the one pass that has to walk two lists
;; -- the inputs and their parents -- side by side.
(define-constant INPUT_INDEXES (list u0 u1 u2 u3 u4 u5 u6 u7))

;; Keyed by member as well as digest: a digest is public from the moment the
;; commit is in the mempool, and keying on it alone would let anyone insert it
;; first and lock the member out of committing at all. They still could not
;; reveal it -- that needs the salt -- but the member would be stuck.
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

;; Announcements are keyed by the scriptPubKey the address locks to, not by the
;; address itself. That is the form the check has in hand -- it reads scripts
;; out of parent transactions -- and it is the form that cannot disagree with
;; itself: the three p2sh-shaped address versions all lock to the same script,
;; and keying on the script makes them the same announcement rather than three
;; that could be held by three different members.
(define-map announcements
  (buff 34)
  {
    member: principal,
    sats: uint,
    ustx: uint,
    announced-at-height: uint,
  }
)

;; Deposits already credited, so one bitcoin output cannot be claimed twice
;; whatever is announced afterwards.
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
;;
;; `get-bitcoin-tx-output?` does the reading: hand it a serialized transaction
;; and an output index and it gives back that output's scriptPubKey and amount,
;; and the transaction's canonical txid. It takes a witness serialization or a
;; stripped one and returns the same txid either way, so a caller can pass an
;; explorer's hex through untouched, and it is the node's own deserializer --
;; not a hand-rolled one that might disagree with it about where an output
;; begins.
;;
;; What it does not do is inputs, and the outpoints of the deposit transaction
;; are the whole point: they say which parents to look at. So that one walk
;; stays here, over bytes the builtin has already deserialized and whose txid
;; the sBTC registry has already vouched for -- a transaction bitcoin itself
;; accepted, well formed by definition.
;;
;; Reads past the end of the buffer come back as zero rather than failing, which
;; is safe for exactly that reason: those bytes cannot run short. The one bound
;; that is checked is the input count, which a well-formed transaction can
;; exceed and which costs a parent transaction each.

;; A little-endian integer of `size` bytes at `at`. Bitcoin writes every number
;; this way; `size` is never more than 8 here.
(define-private (read-le
    (tx (buff 65536))
    (at uint)
    (size uint)
  )
  (buff-to-uint-le (unwrap-panic (as-max-len? (default-to 0x00 (slice? tx at (+ at size))) u16)))
)

;; A bitcoin varint: one byte under 253, otherwise a marker and 2, 4 or 8 bytes.
;; Returns the value and the offset just past it.
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

;; Just past the input at `at`: 32 bytes of parent txid, 4 of output index, a
;; length-prefixed scriptSig, 4 of sequence.
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
              ;; The parent's txid as the transaction carries it, which is the
              ;; internal order `get-bitcoin-tx-output?` returns -- so the two
              ;; compare directly, with no reversal.
              txid: (unwrap-panic (as-max-len? (default-to 0x (slice? tx at (+ at u32))) u32)),
              index: (read-le tx (+ at u32) u4),
            })
            u8
          )),
      })
    )
  )
)

;; Every input of a transaction, as the parent txid it spends and the output
;; index within it. `none` if there are more inputs than this contract will
;; take one parent each for.
(define-private (parse-inputs (tx (buff 65536)))
  (let (
      ;; Past the version, and past the marker and flag if this is a witness
      ;; serialization. A legacy transaction cannot be mistaken for one: those
      ;; two bytes are its input count, which is never zero.
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

;; One input against its parent: the parent has to be the transaction the input
;; names -- which is the txid the builtin returns, not the caller's word for it
;; -- and the output it spends has to be locked to `script`. Positions past the
;; end of the input list are nothing to check.
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

;; 32 bytes, back to front: the builtin hands back a txid in bitcoin's internal
;; order, and the sBTC registry keys deposits by the order bitcoin displays.
;; `fold` walks a buffer forwards, so prepending each byte reverses it.
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

;; The address to bridge to. Never `bond-staker`'s: sBTC arriving there is
;; taken for reward and split among the members.
(define-read-only (get-deposit-address)
  .bond-treasury
)

;; The scriptPubKey a bitcoin address locks its coins to, which is what the
;; input check compares against and what an announcement is keyed by.
;;
;; The address arrives in the same `{version, hashbytes}` shape the sBTC bridge
;; takes for withdrawals, so a client that can already build one of those has
;; nothing new to write. `none` for anything this contract cannot turn into a
;; script, which is anything but the six shapes below.
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
          ;; p2sh, and the two p2sh-wrapped segwit shapes, which are p2sh on
          ;; the chain and differ only in what the redeem script says.
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

;; What to commit to. The salt is the member's to choose and to keep until the
;; reveal; 32 random bytes. Computing it here rather than off chain means a
;; client cannot disagree with the contract about what it committed to.
;;
;; Taken over the script rather than the address, so that the three p2sh-shaped
;; versions of one address commit to one digest -- the same reason the
;; announcement is keyed that way.
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

;; The exact bytes a member signs with their bitcoin key to claim an address.
;;
;; Built here rather than off chain for the same reason `get-address-digest`
;; is: a client cannot then disagree with the contract about what it signed.
;; Show the user this, verbatim -- it is ASCII, and it is what their wallet
;; will display.
;;
;; What it binds is the member and this contract, and nothing else. It does not
;; name the address, and does not need to: the signature is checked against the
;; key the address hashes to, so a signature made for one address cannot verify
;; against another. One message per member, whatever addresses they bring.
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

;; ...and the digest bitcoin's own message signing takes over it. A wallet's
;; `signmessage` computes exactly this; it is here so a test, or a client that
;; would rather check than trust, can compare.
(define-read-only (get-address-claim-digest (member principal))
  (sha256 (sha256
    (concat BTC_SIGNED_MESSAGE CLAIM_LENGTH (get-address-claim-message member))
  ))
)

;; Whether an address is one this contract can hold a member to by signature.
;; See `HEX_DIGITS` above for why the other four shapes are not.
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

;; Whether `public-key` is the key this address was made from.
;;
;; Every shape here is `hashbytes` = some fixed recipe over the key, so the
;; check is to run the recipe and compare. Which recipe is the whole of what
;; the version byte means.
;;
;; Answers false rather than erroring for a shape it cannot rebuild, so the
;; caller gets `is-provable-address`'s error for that and this one's for a key
;; that simply is not the address's.
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
      ;; Either encoding: a legacy address may have been made from the
      ;; uncompressed key, which is a different 65 bytes and a different hash.
      (or
        (is-eq hash keyhash)
        (is-eq hash (hash160 (unwrap! (secp256k1-decompress? public-key) false)))
      )
      (if (is-eq version 0x02)
        ;; The redeem script is the key's own p2wpkh witness program, so the
        ;; address is a hash of a hash and needs nothing this contract does not
        ;; already have.
        (is-eq hash (hash160 (concat 0x0014 keyhash)))
        ;; p2wpkh, and compressed only -- segwit allows nothing else.
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

;; The same, for a caller that already has the script -- an indexer reading the
;; events, say, which carry the script rather than the address.
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

;; What the sBTC registry says about a deposit: `none` until the signers have
;; swept it.
(define-read-only (get-swept-deposit
    (txid (buff 32))
    (vout-index uint)
  )
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-registry
    get-completed-deposit txid vout-index
  )
)

;; The STX a deposit of `sats` has to be accompanied by, for the bond the pool
;; is bound to.
(define-read-only (get-required-ustx (sats uint))
  (contract-call? .bond-staker get-required-ustx sats)
)

;; The txid of a transaction, in the byte order the sBTC registry keys deposits
;; by -- which is the order bitcoin *displays*, the reverse of the order it
;; hashes in and the reverse of the order an input names its parent in.
;;
;; The witnesses, if the serialization carries any, are not part of it: the
;; builtin returns the canonical txid either way, so a client may hand over
;; whichever form its explorer gave it.
(define-read-only (get-txid (tx (buff 65536)))
  (match (get-bitcoin-tx-output? tx u0)
    output (ok (reverse-32 (get txid output)))
    parse-error ERR_MALFORMED_TX
  )
)

;; What `complete-btc-deposit` will make of a transaction and its parents,
;; without moving anything: the scriptPubKey every input is locked to, or the
;; error the call would fail with. For a client to check its arguments before
;; it pays for them.
;;
;; This says nothing about *which* transaction it read -- `complete-btc-deposit`
;; is where `tx` is held to a txid the sBTC signers swept.
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
        ;; That the first parent is the transaction the input names is checked
        ;; again in the pass below, along with every other input. Here it only
        ;; has to be refused early, so an unrelated transaction cannot pick out
        ;; a script for the announcement lookup.
        (named (asserts! (is-eq (get txid funding) (get txid first)) ERR_PARENT_MISMATCH))
        ;; An output locked to something longer than the longest address shape
        ;; is not an address this contract can have taken an announcement for.
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

;; Step 1. Commit to the bitcoin address you are about to send from, and pay
;; the deposit's STX leg. The digest comes from `get-address-digest`; keep the
;; salt until step 2.
;;
;; The sats hold allocation room in the pool from here on. Which address this is
;; has not left your wallet.
(define-public (commit-btc-address
    (digest (buff 32))
    (sats uint)
  )
  (let (
      (member tx-sender)
      ;; Reserves the pool's room and tells us what the STX leg comes to.
      ;; Rejects a member on the way out, a bond that has started, and a
      ;; deposit the pool has no room for.
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

    ;; The STX leg is paid now and held here until the sats arrive.
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

;; Step 2. Name the address the commitment was for, and take it.
;;
;; Do this *before* sending. The address becomes public here, already yours: a
;; watcher who sees it has no commitment to open against it, and one made now is
;; behind this reveal, which took the address first.
;;
;; Send once this has confirmed -- step 3 -- and every input of what you send
;; has to be locked to this address, or the pool cannot tell the deposit is
;; yours.
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
    ;; First reveal takes the address. A second one -- from anyone, including a
    ;; member who committed to the same address -- finds it gone, and finds out
    ;; before any bitcoin has moved.
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

;; Steps 1 and 2 at once, for an address you can sign with.
;;
;; The commit exists because the reveal is a claim anyone watching the mempool
;; could copy. A signature is not copyable: it names the member, and it only
;; verifies against the key the address hashes to. So there is nothing to hide
;; and nothing to wait for -- sign `get-address-claim-message`, send it here,
;; and the address is yours in one transaction.
;;
;; Send once this has confirmed, exactly as with a reveal, and from this
;; address only.
;;
;; What this does *not* do is take an address back. If someone got here first
;; through the slow lane -- which they can, having only to name an address
;; rather than prove it -- this fails with ERR_ADDRESS_ANNOUNCED and the
;; address is theirs until ANNOUNCE_TTL runs out. It costs them the STX leg the
;; whole time, and it costs the member nothing but the use of one address they
;; have others of. Letting a proof evict an unproven claim would be the better
;; end state and is not worth the displacement path it would take to get there.
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
      ;; Reserves the pool's room and tells us what the STX leg comes to, the
      ;; same call the commit makes. Nothing here has committed anything yet:
      ;; every assert below unwinds it.
      (ustx (try! (contract-call? .bond-staker reserve-bridged-deposit member sats)))
    )
    (asserts! (> sats u0) ERR_INVALID_AMOUNT)
    (asserts! (is-provable-address address) ERR_UNPROVABLE_ADDRESS)
    ;; The key is the address: rebuild the address from it and the two have to
    ;; agree before its signature means anything about this address at all.
    (asserts! (address-matches-key address public-key) ERR_WRONG_KEY)
    (asserts!
      (secp256k1-verify (get-address-claim-digest member) signature public-key)
      ERR_BAD_SIGNATURE
    )

    ;; First claim takes the address, proven or not -- the same map and the
    ;; same rule the reveal plays by.
    (asserts!
      (map-insert announcements script {
        member: member,
        sats: sats,
        ustx: ustx,
        announced-at-height: burn-block-height,
      })
      ERR_ADDRESS_ANNOUNCED
    )

    ;; The STX leg is paid now and held here until the sats arrive, as it would
    ;; have been at the commit.
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

;; Give up on a commitment that was never revealed and take its STX leg back.
;; The member may do this whenever; anyone may once COMMIT_TTL burn blocks have
;; passed, so a commitment that goes nowhere cannot hold the pool's room for
;; long. Both arguments are public from the commit onwards.
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

;; Step 5. Queue a revealed deposit now that the sBTC signers have swept it.
;;
;; `tx` is the deposit transaction as bitcoin hashes it -- the serialization
;; without witnesses, the one whose double-SHA256 is the txid. `parents` is one
;; transaction per input of `tx`, in the same order: the transaction each input
;; spends an output of, again as bitcoin hashes it. Nothing else is needed; the
;; hashes tie them together and the sBTC registry vouches for the txid at the
;; end of the chain.
;;
;; Permissionless: the sats go to whoever revealed the funding address, so
;; anyone can finish the job for them.
;;
;; A completion that lands after the bond has been staked queues for the bond
;; after it, priced by the STX paid at announcement -- so it may be scaled back
;; by that roll like any other under-funded position.
(define-public (complete-btc-deposit
    (txid (buff 32))
    (vout-index uint)
    (tx (buff 65536))
    (parents (list 8 (buff 65536)))
  )
  (let (
      (swept (unwrap! (get-swept-deposit txid vout-index) ERR_DEPOSIT_NOT_SWEPT))
      ;; The transaction has to be the one the registry names. This comes first
      ;; because everything after it reads `tx` as authenticated: the signers
      ;; vouched for the txid, and the txid is what these bytes deserialize to.
      (authentic (asserts! (is-eq (try! (get-txid tx)) txid) ERR_TXID_MISMATCH))
      ;; The address every input is locked to, proven back to that txid. This is
      ;; the whole of the argument that the deposit is the announcer's.
      (script (try! (get-funding-script tx parents)))
      (claim (unwrap! (map-get? announcements script) ERR_UNKNOWN_ANNOUNCEMENT))
      (member (get member claim))
      (announced (get sats claim))
      (ustx (get ustx claim))
      ;; What the pool actually received, which is what it can credit.
      (credit (if (< (get amount swept) announced)
        (get amount swept)
        announced
      ))
    )
    ;; The signers minted to whoever the deposit named. Only the treasury will
    ;; do: anywhere else and the pool does not have the sats.
    (asserts! (is-eq (get recipient swept) (get-deposit-address))
      ERR_DEPOSIT_MISDIRECTED
    )
    ;; The announcement has to predate the sweep. Without this, an onlooker who
    ;; saw a swept deposit on bitcoin could read the address that funded it,
    ;; claim that address -- free again, since the owner's own announcement
    ;; had been completed or had lapsed -- and be credited for someone else's
    ;; bitcoin. Announcing first is the one thing they cannot do after the fact.
    (asserts! (< (get announced-at-height claim) (get sweep-burn-height swept))
      ERR_ANNOUNCED_TOO_LATE
    )
    ;; A deposit is credited for what arrived, not for what was announced.
    ;;
    ;; The two differ in the ordinary case: the sBTC signers take their bitcoin
    ;; fee out of the deposit, so what they mint is a little less than what was
    ;; sent. Refusing the difference would strand the deposit -- the sats are
    ;; already swept, and no cancellation puts those back in a wallet -- leaving
    ;; the STX leg here with no way out and the sats in the treasury attributed
    ;; to nobody.
    ;;
    ;; An overpayment is not credited: the excess is in the treasury as
    ;; unattributed principal, the same as any other unannounced sats.
    (asserts! (> (get amount swept) u0) ERR_INVALID_AMOUNT)
    ;; One credit per bitcoin output. A backstop behind the rule above rather
    ;; than a rule that bites on its own -- a second claim needs a second
    ;; announcement, which is necessarily younger than the sweep -- but the
    ;; ledger should not depend on that argument holding for every future
    ;; deposit shape.
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
    ;; The shortfall never arrived, so the room it was holding goes back to the
    ;; pool rather than staying reserved against a deposit that is now closed.
    (if (< credit announced)
      (try! (contract-call? .bond-staker abandon-bridged-deposit (- announced credit)))
      true
    )
    ;; Hand the STX leg over first, so the ledger holds it before it counts it.
    ;;
    ;; All of it, priced on the announcement rather than re-priced on the
    ;; shortfall: it is the member's own STX either way -- it comes back to them
    ;; as released principal when they leave -- and a leg sized to more sats than
    ;; the position holds can only leave them further from STX-limited, never
    ;; nearer. Re-pricing here would mean reading a bond that may have rolled
    ;; since the announcement.
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

;; Give up on a revealed address and take its STX leg back. The member may do
;; this whenever; anyone may once ANNOUNCE_TTL burn blocks have passed, so an
;; address that never receives its deposit cannot be held for good.
;;
;; Do not cancel a deposit you have already sent. The bitcoin will still arrive
;; and still be swept, and until the sBTC signers do that you can commit to the
;; address again -- but between the cancellation and the sweep it is anyone's to
;; take, and after the sweep nothing can attribute those sats to you at all.
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

;; Take your released principal out as bitcoin instead of sBTC.
;;
;; `max-fee` is the most of it you will let the sBTC signers spend on the
;; bitcoin transaction; it comes out of the amount, so `released - max-fee` is
;; sent and the rest covers the fee. Anything the signers do not spend stays
;; with the pool as unattributed principal rather than coming back to you --
;; keep `max-fee` tight.
;;
;; Only you can call this: it spends your sats on a fee and picks the address
;; they land at.
;;
;; If the signers reject the request, `reclaim-btc-withdrawal` puts the whole
;; amount back on your claim. The STX leg is untouched -- `bond-staker`'s
;; `claim-principal` still hands that back on Stacks, the only place STX exists.
(define-public (claim-principal-to-btc
    (recipient {
      version: (buff 1),
      hashbytes: (buff 32),
    })
    (max-fee uint)
  )
  (let (
      (member tx-sender)
      ;; Moves the member's released sats into the pool's "withdrawing"
      ;; bucket and tells us how much that was.
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

;; Settle a bitcoin withdrawal the sBTC signers have ruled on. Permissionless,
;; and worth calling either way -- a rejected request has to be put back on the
;; member's claim before they can do anything with it, and an accepted one is
;; still holding a place in the pool's books until this runs.
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
    ;; Rejected: the sBTC bridge has unlocked the lot back to the treasury, so
    ;; put it back on the member's claim. Accepted: the bitcoin went out, and
    ;; whatever was left of `max-fee` is unattributed principal.
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
