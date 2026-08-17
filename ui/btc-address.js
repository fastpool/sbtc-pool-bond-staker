// Turn a bitcoin address into the `{ version, hashbytes }` pair the sBTC
// bridge wants, using the same version bytes the pox contracts use:
//
//   0x00 p2pkh        0x01 p2sh          0x02 p2sh-p2wpkh   0x03 p2sh-p2wsh
//   0x04 p2wpkh       0x05 p2wsh         0x06 p2tr
//
// Only the four a wallet will actually hand you are produced here: p2pkh and
// p2sh from base58, p2wpkh/p2wsh from bech32, p2tr from bech32m. Everything
// else is rejected rather than guessed at.

const BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

const bytesToHex = (bytes) =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function base58Decode(text) {
  let value = 0n;
  for (const char of text) {
    const digit = BASE58.indexOf(char);
    if (digit < 0) throw new Error(`not base58: ${char}`);
    value = value * 58n + BigInt(digit);
  }
  const bytes = [];
  while (value > 0n) {
    bytes.unshift(Number(value & 0xffn));
    value >>= 8n;
  }
  // every leading '1' is a leading zero byte
  for (const char of text) {
    if (char !== "1") break;
    bytes.unshift(0);
  }
  return Uint8Array.from(bytes);
}

async function decodeBase58Check(address) {
  const raw = base58Decode(address);
  if (raw.length !== 25) throw new Error("wrong length for a base58 address");
  const body = raw.slice(0, 21);
  const checksum = await sha256(await sha256(body));
  for (let i = 0; i < 4; i++) {
    if (checksum[i] !== raw[21 + i]) throw new Error("bad checksum");
  }

  const prefix = body[0];
  // mainnet p2pkh / testnet p2pkh, then mainnet p2sh / testnet p2sh
  const version =
    prefix === 0x00 || prefix === 0x6f
      ? 0x00
      : prefix === 0x05 || prefix === 0xc4
        ? 0x01
        : null;
  if (version === null) throw new Error(`unknown address prefix 0x${prefix.toString(16)}`);
  return { version, hashbytes: body.slice(1) };
}

function bech32Polymod(values) {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const value of values) {
    const top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ value;
    for (let i = 0; i < 5; i++) {
      if ((top >> i) & 1) chk ^= GEN[i];
    }
  }
  return chk;
}

const bech32Expand = (hrp) => [
  ...Array.from(hrp, (c) => c.charCodeAt(0) >> 5),
  0,
  ...Array.from(hrp, (c) => c.charCodeAt(0) & 31),
];

/** Regroup 5-bit words into 8-bit bytes, dropping the zero padding. */
function fromWords(words) {
  let acc = 0;
  let bits = 0;
  const bytes = [];
  for (const word of words) {
    acc = (acc << 5) | word;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      bytes.push((acc >> bits) & 0xff);
    }
  }
  if (bits >= 5 || ((acc << (8 - bits)) & 0xff) !== 0) {
    throw new Error("bad bech32 padding");
  }
  return Uint8Array.from(bytes);
}

function decodeBech32(address) {
  const lower = address.toLowerCase();
  if (lower !== address && address.toUpperCase() !== address) {
    throw new Error("mixed case address");
  }
  const split = lower.lastIndexOf("1");
  if (split < 1) throw new Error("no separator");
  const hrp = lower.slice(0, split);
  const words = Array.from(lower.slice(split + 1), (c) => {
    const value = BECH32.indexOf(c);
    if (value < 0) throw new Error(`not bech32: ${c}`);
    return value;
  });
  if (words.length < 6) throw new Error("too short");

  // bech32 checks to 1, bech32m to 0x2bc830a3; the witness version picks which
  const checksum = bech32Polymod([...bech32Expand(hrp), ...words]);
  const witnessVersion = words[0];
  const expected = witnessVersion === 0 ? 1 : 0x2bc830a3;
  if (checksum !== expected) throw new Error("bad checksum");

  const program = fromWords(words.slice(1, -6));
  if (witnessVersion === 0) {
    if (program.length === 20) return { version: 0x04, hashbytes: program };
    if (program.length === 32) return { version: 0x05, hashbytes: program };
    throw new Error("bad witness v0 program length");
  }
  if (witnessVersion === 1 && program.length === 32) {
    return { version: 0x06, hashbytes: program };
  }
  throw new Error(`unsupported witness version ${witnessVersion}`);
}

/**
 * @returns {Promise<{version: string, hashbytes: string}>} both hex, ready to
 * be handed to `Cl.bufferFromHex`.
 */
export async function toPoxAddress(address) {
  const trimmed = address.trim();
  if (!trimmed) throw new Error("no address");
  const decoded = /^(bc1|tb1|bcrt1)/i.test(trimmed)
    ? decodeBech32(trimmed)
    : await decodeBase58Check(trimmed);
  return {
    version: decoded.version.toString(16).padStart(2, "0"),
    hashbytes: bytesToHex(decoded.hashbytes),
  };
}
