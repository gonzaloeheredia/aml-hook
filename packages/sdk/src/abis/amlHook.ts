/** Minimal AmlHook event ABI for frontend indexers. */
export const amlHookAbi = [
  {
    type: "event",
    name: "SwapObserved",
    inputs: [
      { name: "wallet", indexed: true, type: "address" },
      { name: "score", indexed: false, type: "uint8" },
      { name: "decision", indexed: false, type: "uint8" },
      { name: "feeBps", indexed: false, type: "uint24" },
      { name: "hopDistance", indexed: false, type: "uint8" },
      { name: "origin", indexed: false, type: "address" },
    ],
  },
  {
    type: "event",
    name: "LiquidityObserved",
    inputs: [
      { name: "wallet", indexed: true, type: "address" },
      { name: "score", indexed: false, type: "uint8" },
      { name: "decision", indexed: false, type: "uint8" },
      { name: "seized", indexed: false, type: "bool" },
      { name: "viaTrustedRouter", indexed: false, type: "bool" },
    ],
  },
  {
    type: "event",
    name: "LpExitSeized",
    inputs: [
      { name: "seizeId", indexed: true, type: "uint256" },
      { name: "wallet", indexed: true, type: "address" },
      { name: "poolId", indexed: false, type: "bytes32" },
      { name: "positionKey", indexed: false, type: "bytes32" },
      { name: "principal0", indexed: false, type: "uint256" },
      { name: "principal1", indexed: false, type: "uint256" },
      { name: "fee0", indexed: false, type: "uint256" },
      { name: "fee1", indexed: false, type: "uint256" },
    ],
  },
] as const;
