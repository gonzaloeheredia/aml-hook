/**
 * Minimal ABI for ComplianceOracle.updateScore / getRisk (Layer 2).
 * Mirrors contracts/src/interfaces/oracles/IComplianceOracle.sol
 * The COA emits the score; `_ORACLE_KEEPER` publishes it (`updateScore` is AccessManaged).
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
      { name: "feeBps", type: "uint24" },
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
          { name: "feeBps", type: "uint24" },
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
      { name: "feeBps", indexed: false, type: "uint24" },
      { name: "updatedAt", indexed: false, type: "uint64" },
    ],
  },
] as const;
