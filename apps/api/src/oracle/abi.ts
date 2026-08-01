/**
 * Minimal ABI for ComplianceOracle.updateScore / getScore (Layer 2).
 * Mirrors contracts/src/interfaces/IComplianceOracle.sol
 */

export const complianceOracleAbi = [
  {
    type: "function",
    name: "updateScore",
    stateMutability: "nonpayable",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "score", type: "uint8" },
      { name: "hopDistance", type: "uint8" },
      { name: "origin", type: "address" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "getScore",
    stateMutability: "view",
    inputs: [{ name: "wallet", type: "address" }],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "getRisk",
    stateMutability: "view",
    inputs: [{ name: "wallet", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "score", type: "uint8" },
          { name: "hopDistance", type: "uint8" },
          { name: "origin", type: "address" },
          { name: "updatedAt", type: "uint64" },
        ],
      },
    ],
  },
  {
    type: "event",
    name: "ScoreUpdated",
    inputs: [
      { name: "wallet", indexed: true, type: "address" },
      { name: "score", indexed: false, type: "uint8" },
      { name: "hopDistance", indexed: false, type: "uint8" },
      { name: "origin", indexed: false, type: "address" },
      { name: "updatedAt", indexed: false, type: "uint64" },
    ],
  },
] as const;
