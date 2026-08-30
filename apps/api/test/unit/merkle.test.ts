import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { keccak256, concat, type Address, type Hex } from "viem";
import { buildMerkle, compensationLeaf, splitPot } from "../../src/chain/merkle.js";

const A = "0x1111111111111111111111111111111111111111" as Address;
const B = "0x2222222222222222222222222222222222222222" as Address;
const T = "0x3333333333333333333333333333333333333333" as Address;

function hashPair(a: Hex, b: Hex): Hex {
  return a.toLowerCase() < b.toLowerCase() ? keccak256(concat([a, b])) : keccak256(concat([b, a]));
}

describe("compensation merkle", () => {
  it("single leaf is the root with an empty proof", () => {
    const leaf = compensationLeaf(A, T, 10n);
    const { root, proofs } = buildMerkle([leaf]);
    assert.equal(root, leaf);
    assert.deepEqual(proofs[0], []);
  });

  it("two leaves verify against the sorted pair", () => {
    const left = compensationLeaf(A, T, 1n);
    const right = compensationLeaf(B, T, 2n);
    const { root, proofs } = buildMerkle([left, right]);
    assert.equal(root, hashPair(left, right));
    assert.deepEqual(proofs[0], [right]);
    assert.deepEqual(proofs[1], [left]);
  });

  it("splitPot gives remainder to the last recipient", () => {
    const amounts = splitPot(10n, [A, B, T]);
    assert.deepEqual(amounts, [3n, 3n, 4n]);
  });
});
