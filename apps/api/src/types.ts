/**
 * Shared types for the in-memory AML Hook demo API.
 * Mirrors the frontend use-case model:
 * A exploit · B/C N-hop · D published score 0 · E unknown (never written).
 */

/** Demo wallet identifiers used across the use case. */
export type WalletId = "A" | "B" | "C" | "D" | "E";

/** §3.8 latency mitigation reason when ALLOW is elevated to FEE_OVERRIDE. */
export type LatencyMitigation =
  | "INFLOW_HEURISTIC"
  | "INFLOW_MAGNITUDE"
  | "SCORE_NEVER_WRITTEN"
  | "STALE_WITH_POOL_ACTIVITY"
  | "ACTIVITY_WINDOW_CAP"
  | "MAGNITUDE_QUOTE_FAILED"
  | null;

/** On-chain-style revert selector when beforeSwap denies the swap. */
export type RevertReason =
  | "WalletBlocked"
  | "UnscoredMagnitudeBlocked"
  | "InflowMagnitudeBlocked"
  | "MagnitudeQuoteFailed"
  | "SanctionHit"
  | null;

/** Internal ternary decision used by scoring / settlement. */
export type Decision = "allow" | "fee_override" | "block";

/** On-chain-style hook output label. */
export type HookOutput = "ALLOW" | "FEE_OVERRIDE" | "REVERT";

/** Ledger + contamination state for one demo wallet. */
export type Wallet = {
  id: WalletId;
  accountLabel: string;
  role: string;
  address: string;
  usdc: number;
  eth: number;
  hopDistance: number | null;
  originId: WalletId | null;
  exploitConfirmed: boolean;
  /** True when the oracle has never published a row (Wallet E). */
  neverScored: boolean;
};

/** Record of a completed P2P USDC transfer. */
export type TransferRecord = {
  id: string;
  from: WalletId;
  to: WalletId;
  amountUsd: number;
  at: string;
  resultingScore: number;
  hopDistance: number;
};

/** Simulated hook emit stored in the event trail. */
export type HookEvent = {
  id: string;
  walletId: WalletId;
  address: string;
  score: number;
  decision: HookOutput;
  feeBps: number;
  amountUsd: number;
  hopDistance: number | null;
  origin: string;
  at: string;
  kind: "SwapObserved" | "WalletBlocked";
};

/** Fields of the technical compliance opinion (section A). */
export type TechnicalOpinion = {
  issued: boolean;
  objectAndScope: string;
  riskAndScoring: string;
  typologies: string;
  sanctionsCheck: string;
  sourcesConsulted: string[];
  decisionExecuted: string;
  legalBasis: string;
  recommendations: string;
  traceability: string;
};

/** Optional SAR-support annex, or null when not required. */
export type SarAnnex = {
  produced: boolean;
  status: string;
  activityPeriod: string;
  amountInvolved: string;
  operationState: string;
  narrativeDescription: string;
  narrativeAnalysis: string;
  narrativeEvidence: string;
  narrativeConclusion: string;
  warnings: string[];
} | null;

/** Full live compliance pack returned by GET /wallets/:id/compliance. */
export type CompliancePack = {
  walletId: WalletId;
  address: string;
  accountLabel: string;
  score: number;
  decision: Decision;
  hookOutput: HookOutput;
  appliedFeeBps: number;
  feePercent: number;
  hopDistance: number | null;
  originId: WalletId | null;
  exploitConfirmed: boolean;
  usdc: number;
  eth: number;
  riskLabel: string;
  /** True while A→D (or inbound to D) awaits keeper updateScore. */
  keeperPending: boolean;
  /** §3.8 floor applied on the current quote path, if any. */
  latencyMitigation: LatencyMitigation;
  revertReason: RevertReason;
  assessedUsd: number;
  opsInWindow: number;
  isStale: boolean;
  priceFeedBound: boolean;
  summary: string[];
  agent: {
    status: string;
    documentType: string;
    confidence: "HIGH" | "MEDIUM" | "LOW";
    humanReview: boolean;
    retentionYears: number;
    auditHash: string;
    technicalOpinion: TechnicalOpinion;
    sarAnnex: SarAnnex;
    decisionRecord: {
      score: string;
      output: HookOutput;
      mainFacts: string;
      basis: string;
      nextReview: string;
    };
    note: string;
    /** Virtual COA run metadata (skills + connected sources). */
    run?: {
      runId: string;
      role: string;
      flow: string;
      durationMs: number;
      skillsExecuted: string[];
      sourcesConsulted: string[];
      publishTxHash?: string;
      publishStatus?: string;
    };
  };
};

/** Preview of a USDC→ETH swap without mutating balances. */
export type SwapQuote = {
  walletId: WalletId;
  usdcIn: number;
  ethOut: number;
  feeBps: number;
  feePercent: number;
  decision: Decision;
  hookOutput: HookOutput;
  score: number;
  canSettle: boolean;
  /** Oracle/keeper score before §3.8 floors (may still be stale 0 for Wallet D). */
  oracleScore: number;
  keeperPending: boolean;
  latencyMitigation: LatencyMitigation;
  revertReason: RevertReason;
  assessedUsd: number;
  opsInWindow: number;
  isStale: boolean;
  priceFeedBound: boolean;
};
