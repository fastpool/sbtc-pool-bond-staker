import { describe, expect, it } from "vitest";
import { toPoxAddress } from "../lib/btc-address.js";
import { createHash } from "node:crypto";

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const BECH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
const sha = (b) => new Uint8Array(createHash("sha256").update(b).digest());
const hex = (b) => Buffer.from(b).toString("hex");
const unhex = (h) => Uint8Array.from(Buffer.from(h, "hex"));

function b58check(prefix, payload) {
  const body = Uint8Array.from([prefix, ...payload]);
  const sum = sha(sha(body)).slice(0, 4);
  let n = 0n;
  for (const b of [...body, ...sum]) n = (n << 8n) | BigInt(b);
  let out = "";
  while (n > 0n) { out = B58[Number(n % 58n)] + out; n /= 58n; }
  for (const b of [...body, ...sum]) { if (b !== 0) break; out = "1" + out; }
  return out;
}
function polymod(v) {
  const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let c = 1;
  for (const x of v) { const t = c >> 25; c = ((c & 0x1ffffff) << 5) ^ x;
    for (let i = 0; i < 5; i++) if ((t >> i) & 1) c ^= G[i]; }
  return c;
}
function bech32(hrp, witver, program) {
  const words = [witver];
  let acc = 0, bits = 0;
  for (const b of program) { acc = (acc << 8) | b; bits += 8;
    while (bits >= 5) { bits -= 5; words.push((acc >> bits) & 31); } }
  if (bits) words.push((acc << (5 - bits)) & 31);
  const expand = [...hrp].map((c) => c.charCodeAt(0) >> 5).concat([0], [...hrp].map((c) => c.charCodeAt(0) & 31));
  const konst = witver === 0 ? 1 : 0x2bc830a3;
  const chk = polymod([...expand, ...words, 0, 0, 0, 0, 0, 0]) ^ konst;
  const sum = [];
  for (let i = 0; i < 6; i++) sum.push((chk >> (5 * (5 - i))) & 31);
  return hrp + "1" + [...words, ...sum].map((w) => BECH[w]).join("");
}

const h20 = "751e76e8199196d454941c45d1b3a323f1433bd6";
const h32 = "1863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262";

describe("bitcoin address decoding", () => {
  it("round-trips every address shape the sBTC bridge accepts", async () => {
    const cases = [
      [b58check(0x00, unhex(h20)), "00", h20],   // mainnet p2pkh
      [b58check(0x6f, unhex(h20)), "00", h20],   // testnet p2pkh
      [b58check(0x05, unhex(h20)), "01", h20],   // mainnet p2sh
      [b58check(0xc4, unhex(h20)), "01", h20],   // testnet p2sh
      [bech32("bc", 0, unhex(h20)), "04", h20],  // p2wpkh
      [bech32("tb", 0, unhex(h20)), "04", h20],
      [bech32("bc", 0, unhex(h32)), "05", h32],  // p2wsh
      [bech32("bc", 1, unhex(h32)), "06", h32],  // p2tr
    ];
    for (const [address, version, hashbytes] of cases) {
      expect(await toPoxAddress(address)).toEqual({ version, hashbytes });
    }
  });

  it("matches the canonical BIP-173 vector", async () => {
    // anchors the checksum constants against something not of our own making
    expect(
      await toPoxAddress("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"),
    ).toEqual({ version: "04", hashbytes: h20 });
  });

  it("refuses anything it cannot vouch for", async () => {
    const bad = [
      "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5",        // bad checksum
      b58check(0x00, unhex(h20)).slice(0, -1) + "X",        // bad checksum
      b58check(0x1c, unhex(h20)),                           // unknown prefix
      bech32("bc", 2, unhex(h32)),                          // witness v2
      "Bc1Qw508D6QeJxTdG4y5r3zarvary0c5xw7kv8f3t4",         // mixed case
      "hello",
    ];
    for (const address of bad) {
      await expect(toPoxAddress(address)).rejects.toThrow();
    }
  });
});
