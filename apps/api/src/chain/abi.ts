/**
 * Minimal ABIs for the demo adapter. Quotes go through previewSwap — not a TS policy.
 */

export const hookAbi = [
  {
    type: "function",
    name: "previewSwap",
    stateMutability: "view",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [
      { name: "decision", type: "uint8" },
      { name: "feeBps", type: "uint24" },
      {
        name: "risk",
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
    type: "function",
    name: "observeSwap",
    stateMutability: "nonpayable",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [
      { name: "decision", type: "uint8" },
      { name: "feeBps", type: "uint24" },
      {
        name: "risk",
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
    type: "function",
    name: "syncBaseline",
    stateMutability: "nonpayable",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setPriceFeed",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "feed", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "priceFeeds",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "stalenessThreshold",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "inflowThresholdBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "unscoredFeeThreshold",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "unscoredRevertThreshold",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "proportionalFeeBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint24" }],
  },
  {
    type: "function",
    name: "punitiveFeeBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint24" }],
  },
  {
    type: "function",
    name: "poolImpactThresholdBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "poolActivity",
    stateMutability: "view",
    inputs: [{ name: "wallet", type: "address" }],
    outputs: [
      { name: "windowStart", type: "uint64" },
      { name: "opCount", type: "uint32" },
      { name: "lastSwapAt", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "lastKnownBalance",
    stateMutability: "view",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "lastKnownBalanceTimestamp",
    stateMutability: "view",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
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
    type: "error",
    name: "WalletBlocked",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "score", type: "uint8" },
      { name: "reason", type: "string" },
    ],
  },
  {
    type: "error",
    name: "SanctionHit",
    inputs: [{ name: "wallet", type: "address" }],
  },
  {
    type: "error",
    name: "UnscoredMagnitudeBlocked",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "assessedUsd", type: "uint256" },
      { name: "threshold", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "InflowMagnitudeBlocked",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "inflowUsd", type: "uint256" },
      { name: "threshold", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "MagnitudeQuoteFailed",
    inputs: [
      { name: "token", type: "address" },
      { name: "reason", type: "bytes32" },
    ],
  },
  {
    type: "error",
    name: "DailyAggregationBlocked",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "assessedUsd", type: "uint256" },
      { name: "threshold", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "StalePoolImpactBlocked",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "poolImpactBps", type: "uint256" },
      { name: "threshold", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "UnscoredPoolImpactBlocked",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "poolImpactBps", type: "uint256" },
      { name: "threshold", type: "uint256" },
    ],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "transfer",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

export const escrowAbi = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "token", type: "address" },
      { name: "swapFingerprint", type: "bytes32" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "escrowId", type: "uint256" }],
  },
  {
    type: "function",
    name: "nextEscrowId",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "getEscrow",
    stateMutability: "view",
    inputs: [{ name: "escrowId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "wallet", type: "address" },
          { name: "token", type: "address" },
          { name: "amount", type: "uint256" },
          { name: "depositedAt", type: "uint64" },
          { name: "swapFingerprint", type: "bytes32" },
          { name: "status", type: "uint8" },
          { name: "blockedAt", type: "uint64" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "resolveCheckpoint2",
    stateMutability: "nonpayable",
    inputs: [
      { name: "escrowId", type: "uint256" },
      { name: "illicitConfirmed", type: "bool" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "recoverBlocked",
    stateMutability: "nonpayable",
    inputs: [{ name: "escrowId", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "complianceReserve",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "lpCompensationFund",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

export const oracleAbi = [
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
    name: "attestationHash",
    stateMutability: "view",
    inputs: [
      { name: "wallet", type: "address" },
      { name: "score", type: "uint8" },
      { name: "hopDistance", type: "uint8" },
      { name: "origin", type: "address" },
      { name: "feeBps", type: "uint24" },
      { name: "updatedAt", type: "uint64" },
    ],
    outputs: [{ name: "", type: "bytes32" }],
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
] as const;

export const registryAbi = [
  {
    type: "function",
    name: "setSanctioned",
    stateMutability: "nonpayable",
    inputs: [
      { name: "account", type: "address" },
      { name: "sanctioned", type: "bool" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "isSanctioned",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;
