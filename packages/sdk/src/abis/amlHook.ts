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
] as const;
