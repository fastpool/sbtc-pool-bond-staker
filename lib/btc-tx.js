// Serialize a bitcoin transaction the way bitcoin hashes it, and turn a
// `{version, hashbytes}` address into the scriptPubKey it locks to.
//
// `bond-bridge-v2.complete-btc-deposit` is handed the deposit transaction and
// the parent behind each of its inputs. It reads them with Clarity's
// `get-bitcoin-tx-output?`, which takes either serialization, so an explorer's
// `/tx/:txid/hex` goes through untouched -- what `parseTx` is for here is
// finding the outpoints, so a client knows which parents to fetch.
//
// Txids are handled the way an explorer shows them: reversed from the order
// they are hashed and stored in. That is also the order the sBTC registry keys
// its deposits by, so it is the order the contract wants.

const bytesToHex = (bytes) =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

const hexToBytes = (hex) =>
  Uint8Array.from(
    (hex.replace(/^0x/, "").match(/../g) ?? []).map((b) => parseInt(b, 16)),
  );

const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
};

const uintLe = (value, size) => {
  const out = new Uint8Array(size);
  let left = BigInt(value);
  for (let i = 0; i < size; i++) {
    out[i] = Number(left & 0xffn);
    left >>= 8n;
  }
  return out;
};

/** A bitcoin varint: one byte under 253, otherwise a marker and 2, 4 or 8. */
export function varint(value) {
  if (value < 0xfd) return Uint8Array.from([value]);
  if (value <= 0xffff) return concat(Uint8Array.from([0xfd]), uintLe(value, 2));
  if (value <= 0xffffffff)
    return concat(Uint8Array.from([0xfe]), uintLe(value, 4));
  return concat(Uint8Array.from([0xff]), uintLe(value, 8));
}

const withLength = (hex) => {
  const script = hexToBytes(hex ?? "");
  return concat(varint(script.length), script);
};

/**
 * Serialize a transaction as bitcoin hashes it. Returns hex.
 *
 * Inputs name their parent by the txid an explorer shows; this flips it.
 */
export function buildTx(inputs, outputs, { version = 2, locktime = 0 } = {}) {
  return bytesToHex(
    concat(
      uintLe(version, 4),
      varint(inputs.length),
      ...inputs.map((input) =>
        concat(
          hexToBytes(input.txid).reverse(),
          uintLe(input.vout, 4),
          withLength(input.script),
          uintLe(input.sequence ?? 0xfffffffd, 4),
        ),
      ),
      varint(outputs.length),
      ...outputs.map((output) =>
        concat(uintLe(output.value, 8), withLength(output.script)),
      ),
      uintLe(locktime, 4),
    ),
  );
}

/** Read a transaction back, ignoring the witnesses if it carries any. */
export function parseTx(hex) {
  const bytes = hexToBytes(hex);
  let at = 0;
  const take = (n) => bytes.slice(at, (at += n));
  const readVarint = () => {
    const marker = bytes[at++];
    if (marker < 0xfd) return marker;
    const size = marker === 0xfd ? 2 : marker === 0xfe ? 4 : 8;
    let value = 0;
    for (let i = size - 1; i >= 0; i--) value = value * 256 + bytes[at + i];
    at += size;
    return value;
  };
  const readUint = (size) => {
    let value = 0;
    for (let i = size - 1; i >= 0; i--) value = value * 256 + bytes[at + i];
    at += size;
    return value;
  };

  const version = readUint(4);
  let segwit = false;
  if (bytes[at] === 0x00 && bytes[at + 1] === 0x01) {
    segwit = true;
    at += 2;
  }
  const inputs = [];
  for (let i = readVarint(); i > 0; i--) {
    const txid = bytesToHex(take(32).reverse());
    const vout = readUint(4);
    const script = bytesToHex(take(readVarint()));
    inputs.push({ txid, vout, script, sequence: readUint(4) });
  }
  const outputs = [];
  for (let i = readVarint(); i > 0; i--) {
    const value = readUint(8);
    outputs.push({ value, script: bytesToHex(take(readVarint())) });
  }
  if (segwit) {
    for (let i = 0; i < inputs.length; i++) {
      for (let items = readVarint(); items > 0; items--) take(readVarint());
    }
  }
  return { version, segwit, inputs, outputs, locktime: readUint(4) };
}

/**
 * The txid of a serialized transaction, as an explorer shows it.
 *
 * The plain double-SHA256, so this is only the txid of a serialization without
 * witnesses -- the form `buildTx` produces. For the canonical txid of an
 * arbitrary one, ask the contract: `get-txid` reads it the way the chain does.
 */
export async function txidOf(hex) {
  const once = await crypto.subtle.digest("SHA-256", hexToBytes(hex));
  const twice = await crypto.subtle.digest("SHA-256", once);
  return bytesToHex(new Uint8Array(twice).reverse());
}

/**
 * The scriptPubKey a `{version, hashbytes}` address locks to -- the six shapes
 * `bond-bridge-v2.get-address-script` builds, and the same version bytes
 * `btc-address.js` produces.
 */
export function scriptFor(version, hashbytes) {
  const hash = hashbytes.replace(/^0x/, "");
  const script = {
    "00": `76a914${hash}88ac`,
    "01": `a914${hash}87`,
    "02": `a914${hash}87`,
    "03": `a914${hash}87`,
    "04": `0014${hash}`,
    "05": `0020${hash}`,
    "06": `5120${hash}`,
  }[version.replace(/^0x/, "")];
  if (!script) throw new Error(`no script for address version ${version}`);
  return script;
}
