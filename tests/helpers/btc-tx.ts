// Just enough bitcoin to test `bond-bridge`.
//
// The contract is handed transactions as bitcoin hashes them -- the
// serialization without witnesses -- and ties them together by those hashes, so
// the tests have to build real ones. `lib/btc-tx.js` is what does the
// serializing, here and in the page and in the mainnet simulation; only the
// txid is recomputed below, synchronously, so a test reads as one statement.
//
// Nothing here signs anything: the contract never looks at a scriptSig or a
// witness, only at the outputs a transaction creates and the outpoints its
// inputs name.
import { createHash } from "node:crypto";
import { buildTx, scriptFor } from "../../lib/btc-tx.js";

export { buildTx, scriptFor };

const sha256 = (bytes: Buffer) => createHash("sha256").update(bytes).digest();

/** The txid of a serialized transaction, as an explorer shows it. */
export const txidOf = (tx: string): string =>
  Buffer.from(sha256(sha256(Buffer.from(tx, "hex"))))
    .reverse()
    .toString("hex");

/**
 * A deposit and the parent behind each of its inputs, funded from `sources`.
 *
 * Each source names the address that locked the coin being spent and where in
 * its parent that coin sits, so a test can build a transaction funded from one
 * address, from two, or from an output a long way down a parent's list.
 */
export function fundedDeposit(
  sources: {
    version: string;
    hashbytes: string;
    /** Which output of the parent the deposit spends. */
    vout?: number;
    /** How many outputs the parent has in total. */
    outputs?: number;
    /** How many inputs the parent has. */
    inputs?: number;
    value?: number;
  }[],
  { depositValue = 100_000 }: { depositValue?: number } = {},
) {
  const parents = sources.map((source, index) => {
    const vout = source.vout ?? 0;
    const total = source.outputs ?? vout + 1;
    return buildTx(
      Array.from({ length: source.inputs ?? 1 }, (_, i) => ({
        txid: `${(index + 1).toString(16).padStart(2, "0")}${i
          .toString(16)
          .padStart(2, "0")}`.repeat(16),
        vout: i,
      })),
      Array.from({ length: total }, (_, i) => ({
        value: source.value ?? 200_000,
        // Every other output pays somewhere else entirely, so a test that
        // scans to the wrong one gets a different address rather than a match.
        script:
          i === vout
            ? scriptFor(source.version, source.hashbytes)
            : scriptFor("04", `${(0xd0 + i).toString(16)}`.repeat(20)),
      })),
    );
  });

  const tx = buildTx(
    parents.map((parent, index) => ({
      txid: txidOf(parent),
      vout: sources[index].vout ?? 0,
    })),
    [{ value: depositValue, script: scriptFor("05", "ee".repeat(32)) }],
  );

  return { tx, parents, txid: txidOf(tx) };
}
