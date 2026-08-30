/**
 * OpenZeppelin-compatible sorted-pair merkle tree for LpCompensationVault leaves.
 * Leaf = keccak256(bytes.concat(keccak256(abi.encode(account, token, amount)))).
 */

import { concat, encodeAbiParameters, keccak256, type Address, type Hex } from "viem";

export function compensationLeaf(account: Address, token: Address, amount: bigint): Hex {
  const inner = keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
      ],
      [account, token, amount],
    ),
  );
  return keccak256(inner);
}

function hashPair(a: Hex, b: Hex): Hex {
  return a.toLowerCase() < b.toLowerCase()
    ? keccak256(concat([a, b]))
    : keccak256(concat([b, a]));
}

export function buildMerkle(leaves: Hex[]): { root: Hex; proofs: Hex[][] } {
  if (leaves.length === 0) throw new Error("no merkle leaves");
  if (leaves.length === 1) return { root: leaves[0], proofs: [[]] };

  const layers: Hex[][] = [leaves];
  let layer = leaves;
  while (layer.length > 1) {
    const next: Hex[] = [];
    for (let i = 0; i < layer.length; i += 2) {
      if (i + 1 === layer.length) next.push(layer[i]);
      else next.push(hashPair(layer[i], layer[i + 1]));
    }
    layers.push(next);
    layer = next;
  }

  const proofs = leaves.map((_, index) => {
    const proof: Hex[] = [];
    let i = index;
    for (let l = 0; l < layers.length - 1; l++) {
      const row = layers[l];
      const pair = i % 2 === 0 ? i + 1 : i - 1;
      if (pair < row.length) proof.push(row[pair]);
      i = Math.floor(i / 2);
    }
    return proof;
  });
  return { root: layer[0], proofs };
}

/** Split `pot` across recipients; the last address receives the remainder. */
export function splitPot(pot: bigint, recipients: Address[]): bigint[] {
  if (recipients.length === 0) return [];
  const n = BigInt(recipients.length);
  const share = pot / n;
  const amounts = recipients.map(() => share);
  amounts[amounts.length - 1] = pot - share * (n - 1n);
  return amounts;
}
