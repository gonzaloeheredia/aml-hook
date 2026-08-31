/**
 * HTTP client for the AML Hook in-memory demo API (`apps/api/`).
 * Default base: http://localhost:4000. Hosted Sepolia: set NEXT_PUBLIC_API_URL
 * to the Railway API (e.g. https://aml-hook-api-production.up.railway.app).
 */

import type { DemoCaseId } from "@/data/cases";
import {
  initialSimWallets,
  type SimWallet,
  type TransferRecord,
} from "@/lib/hopScoring";

export const API_BASE =
  process.env.NEXT_PUBLIC_API_URL?.replace(/\/$/, "") ||
  "http://localhost:4000";

export type ApiDecision = "allow" | "fee_override" | "block";
export type ApiHookOutput = "ALLOW" | "FEE_OVERRIDE" | "REVERT";

export type ApiLatencyMitigation =
  | "INFLOW_HEURISTIC"
  | "INFLOW_MAGNITUDE"
  | "SCORE_NEVER_WRITTEN"
  | "STALE_WITH_POOL_ACTIVITY"
  | "ACTIVITY_WINDOW_CAP"
  | "DAILY_AGGREGATION"
  | "MAGNITUDE_QUOTE_FAILED"
  | null;

export type ApiRevertReason =
  | "WalletBlocked"
  | "UnscoredMagnitudeBlocked"
  | "InflowMagnitudeBlocked"
  | "MagnitudeQuoteFailed"
  | "DailyAggregationBlocked"
  | "StalePoolImpactBlocked"
  | "UnscoredPoolImpactBlocked"
  | "SanctionHit"
  | null;

export type ApiWallet = SimWallet & {
  score?: number;
  decision?: ApiDecision;
  hookOutput?: ApiHookOutput;
  appliedFeeBps?: number;
  keeperPending?: boolean;
  latencyMitigation?: ApiLatencyMitigation;
};

export type ApiTechnicalOpinion = {
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
  normativeCitations?: ApiNormativeCitation[];
};

export type ApiNormativeCitation = {
  id: string;
  title: string;
  framework: "FATF" | "OFAC" | "MICA" | "TFR" | "FINCEN" | "TREASURY" | "WOLFSBERG";
  series: string;
  publicationDate: string;
  retrievedAt: string;
  sha256: string;
};

export type ApiCompliancePack = {
  walletId: DemoCaseId;
  address: string;
  accountLabel: string;
  score: number;
  decision: ApiDecision;
  hookOutput: ApiHookOutput;
  appliedFeeBps: number;
  feePercent: number;
  hopDistance: number | null;
  originId: DemoCaseId | null;
  exploitConfirmed: boolean;
  usdc: number;
  eth: number;
  riskLabel: string;
  keeperPending: boolean;
  latencyMitigation: ApiLatencyMitigation;
  revertReason?: ApiRevertReason;
  assessedUsd?: number;
  opsInWindow?: number;
  isStale?: boolean;
  priceFeedBound?: boolean;
  summary: string[];
  agent: {
    status: string;
    documentType: string;
    confidence: "HIGH" | "MEDIUM" | "LOW";
    humanReview: boolean;
    retentionYears: number;
    auditHash: string;
    technicalOpinion: ApiTechnicalOpinion;
    sarAnnex: {
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
    decisionRecord: {
      score: string;
      output: ApiHookOutput;
      mainFacts: string;
      basis: string;
      nextReview: string;
    };
    note: string;
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

export type ApiHookEvent = {
  id: string;
  walletId: DemoCaseId;
  address: string;
  score: number;
  decision: ApiHookOutput;
  feeBps: number;
  amountUsd: number;
  hopDistance: number | null;
  origin: string;
  at: string;
  kind: "SwapObserved" | "WalletBlocked";
  txHash?: string;
  blockNumber?: number;
  source?: "chain" | "demo";
};

export type ApiSwapQuote = {
  walletId: DemoCaseId;
  usdcIn: number;
  ethOut: number;
  feeBps: number;
  feePercent: number;
  decision: ApiDecision;
  hookOutput: ApiHookOutput;
  score: number;
  canSettle: boolean;
  oracleScore?: number;
  keeperPending?: boolean;
  latencyMitigation?: ApiLatencyMitigation;
  revertReason?: ApiRevertReason;
  assessedUsd?: number;
  opsInWindow?: number;
  isStale?: boolean;
  priceFeedBound?: boolean;
};

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

/**
 * Strips live scoring fields so the client keeps the SimWallet ledger shape.
 */
export function toSimWallet(w: ApiWallet): SimWallet {
  return {
    id: w.id,
    accountLabel: w.accountLabel,
    role: w.role,
    address: w.address,
    usdc: w.usdc,
    eth: w.eth,
    hopDistance: w.hopDistance,
    originId: w.originId,
    exploitConfirmed: w.exploitConfirmed,
    keeperPending: w.keeperPending,
    neverScored: w.neverScored,
    lastKnownUsdc: w.lastKnownUsdc,
    lastScoreAt: w.lastScoreAt,
    lastKnownAt: w.lastKnownAt,
    opsInWindow: w.opsInWindow,
    windowUsd: w.windowUsd,
    windowStart: w.windowStart,
  };
}

/**
 * Maps an API wallet list into a Record keyed by A–E (fills missing seeds).
 */
export function walletsRecord(
  list: ApiWallet[],
): Record<DemoCaseId, SimWallet> {
  const out = initialSimWallets();
  for (const w of list) {
    out[w.id] = {
      ...out[w.id],
      ...toSimWallet(w),
      lastKnownUsdc: w.lastKnownUsdc ?? out[w.id].lastKnownUsdc,
    };
  }
  return out;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${API_BASE}${path}`, {
      ...init,
      headers: {
        Accept: "application/json",
        ...(init?.body ? { "Content-Type": "application/json" } : {}),
        ...init?.headers,
      },
    });
  } catch {
    throw new ApiError(
      `Cannot reach API at ${API_BASE}. Is the backend running?`,
      0,
    );
  }

  const data = (await res.json().catch(() => ({}))) as {
    error?: string;
  } & T;

  if (!res.ok) {
    const body = data as { error?: string; message?: string };
    throw new ApiError(
      body.message || body.error || `API ${res.status} on ${path}`,
      res.status,
    );
  }
  return data as T;
}

/** GET /health */
export type ApiPolicyKnobs = {
  unscoredFeeThresholdUsd: number;
  unscoredRevertThresholdUsd: number;
  proportionalFeeBps: number;
  punitiveFeeBps: number;
  poolImpactThresholdBps: number;
};

export function fetchHealth() {
  return request<{
    ok: boolean;
    mode: string;
    chain?: { ok: boolean; hook: string | null; reason?: string };
    policy?: ApiPolicyKnobs;
    agent?: {
      live?: boolean;
      model?: string | null;
      opinion?: string;
    };
  }>(`/health`);
}

export function fetchPolicy() {
  return request<{ policy: ApiPolicyKnobs }>(`/policy`);
}

export type ApiEscrowRow = {
  id: number;
  wallet: string;
  walletId: DemoCaseId | null;
  token: string;
  amountUsdc: number;
  depositedAt: number;
  swapFingerprint: string;
  status: string;
  kind?: "RiskFee" | "LpPrincipal";
  blockedAt: number;
};

export function fetchEscrow() {
  return request<{ rows: ApiEscrowRow[] }>(`/escrow`);
}

export function postEscrowCheckpoint2(id: number, illicit: boolean) {
  return request<{ ok: boolean; txHash: string; rows: ApiEscrowRow[] }>(
    `/escrow/${id}/checkpoint2`,
    { method: "POST", body: JSON.stringify({ illicit }) },
  );
}

export function postEscrowRecover(id: number) {
  return request<{ ok: boolean; txHash: string; rows: ApiEscrowRow[] }>(
    `/escrow/${id}/recover`,
    { method: "POST" },
  );
}

export type ApiCompensationLeaf = {
  account: string;
  amountUsdc: number;
  proof: string[];
  claimed: boolean;
};

export type ApiCompensationEpoch = {
  id: number;
  openedAt: number;
  closedAt: number;
  claimUntil: number;
  merkleRoot: string;
  potUsdc: number;
  open: boolean;
  leaves: ApiCompensationLeaf[];
};

export type ApiCompensation = {
  vault: string;
  recipients: string[];
  accountedUsdc: number;
  balanceUsdc: number;
  openEpochId: number;
  epochs: ApiCompensationEpoch[];
};

export function fetchCompensation(account?: string) {
  const q = account ? `?account=${encodeURIComponent(account)}` : "";
  return request<ApiCompensation>(`/compensation${q}`);
}

export function postCompensationCloseEpoch() {
  return request<{ ok: boolean; txHash: string; epochId: number } & ApiCompensation>(
    `/compensation/close-epoch`,
    { method: "POST" },
  );
}

export function postCompensationClaim(epochId: number, account: string) {
  return request<{ ok: boolean; txHash: string } & ApiCompensation>(`/compensation/claim`, {
    method: "POST",
    body: JSON.stringify({ epochId, account }),
  });
}

export type ApiTreasuryPayout = {
  id: number;
  account: "LP_PRINCIPAL" | "ILLICIT_RISK_FEE";
  amountUsdc: number;
  to: string;
  memo: string;
  proposedAt: number;
  status: "Pending" | "Executed" | "Cancelled";
};

export type ApiTreasury = {
  treasury: string;
  payoutDelaySec: number;
  lpPrincipalUsdc: number;
  illicitRiskFeeUsdc: number;
  payouts: ApiTreasuryPayout[];
};

export function fetchTreasury() {
  return request<ApiTreasury>(`/treasury`);
}

export function postTreasuryPropose(body: {
  account: "LP_PRINCIPAL" | "ILLICIT_RISK_FEE";
  amountUsdc: number;
  to: string;
  memo?: string;
}) {
  return request<{ ok: boolean; payoutId: number } & ApiTreasury>(`/treasury/propose`, {
    method: "POST",
    body: JSON.stringify(body),
  });
}

export function postTreasuryExecute(id: number) {
  return request<{ ok: boolean; txHash: string } & ApiTreasury>(`/treasury/${id}/execute`, {
    method: "POST",
  });
}

export function postTreasuryCancel(id: number) {
  return request<{ ok: boolean; txHash: string } & ApiTreasury>(`/treasury/${id}/cancel`, {
    method: "POST",
  });
}

/** GET /wallets */
export function fetchWallets() {
  return request<{ wallets: ApiWallet[] }>(`/wallets`);
}

/** GET /transfers */
export function fetchTransfers() {
  return request<{ transfers: TransferRecord[] }>(`/transfers`);
}

/** GET /events — A–D default to the API trail, E to SwapObserved logs. */
export function fetchEvents(walletId?: DemoCaseId, address?: string) {
  const params = new URLSearchParams();
  if (walletId) params.set("walletId", walletId);
  if (address) params.set("address", address);
  const q = params.toString() ? `?${params.toString()}` : "";
  return request<{ events: ApiHookEvent[] }>(`/events${q}`);
}

/** GET /wallets/:id/compliance */
export function fetchCompliance(id: DemoCaseId, amountUsd?: number) {
  const q =
    amountUsd != null && Number.isFinite(amountUsd)
      ? `?amountUsd=${Math.round(amountUsd)}`
      : "";
  return request<ApiCompliancePack>(`/wallets/${id}/compliance${q}`);
}

/** POST /transfers */
export function postTransfer(
  from: DemoCaseId,
  to: DemoCaseId,
  amountUsd: number,
) {
  return request<{
    transfer: TransferRecord;
    wallets: ApiWallet[];
    recipientCompliance: ApiCompliancePack;
    keeperPending?: boolean;
  }>(`/transfers`, {
    method: "POST",
    body: JSON.stringify({ from, to, amountUsd }),
  });
}

/** POST /swaps */
export function postSwap(walletId: DemoCaseId, amountUsd?: number) {
  return request<{
    settled: boolean;
    reason?: string;
    quote: ApiSwapQuote;
    wallet: ApiWallet;
    event?: ApiHookEvent;
    ethReceived?: number;
    compliance: ApiCompliancePack;
    keeperCatchUp?: { published: boolean; score: number; feeBps: number } | null;
  }>(`/swaps`, {
    method: "POST",
    body: JSON.stringify({
      walletId,
      ...(amountUsd != null ? { amountUsd } : {}),
    }),
  });
}

/** POST /oracle/:id/catch-up: publish deferred keeper score (Wallet D). */
export function postKeeperCatchUp(id: DemoCaseId) {
  return request<{
    ok: boolean;
    keeperPending: boolean;
    compliance: ApiCompliancePack;
  }>(`/oracle/${id}/catch-up`, { method: "POST" });
}

/** POST /demo/elapse: advance demo clock (301s makes a published score stale). */
export function postDemoElapse(seconds = 301) {
  return request<{ ok: boolean; now: number; elapsedSeconds: number }>(
    `/demo/elapse`,
    {
      method: "POST",
      body: JSON.stringify({ seconds }),
    },
  );
}

/** POST /demo/mint: mint MockUSDC or MockWETH to a demo wallet A–E. */
export function postDemoMint(
  walletId: SimWallet["id"],
  token: "usdc" | "eth",
  amount: number,
) {
  return request<{
    ok: boolean;
    token: "usdc" | "eth";
    amount: number;
    txHash: string;
    wallets: ApiWallet[];
  }>(`/demo/mint`, {
    method: "POST",
    body: JSON.stringify({ walletId, token, amount }),
  });
}

/** POST /demo/wallet-e: bind Wallet E to a live Sepolia EOA. */
export function postBindWalletE(address: string) {
  return request<{ ok: boolean; address: string; wallets: ApiWallet[] }>(
    `/demo/wallet-e`,
    {
      method: "POST",
      body: JSON.stringify({ address }),
    },
  );
}

/** POST /demo/mint: faucet, 1,000 MockUSDC + 1 MockWETH to an arbitrary address. */
export function postDemoFaucet(address: string) {
  return request<{
    ok: boolean;
    faucet: true;
    address: string;
    usdc: number;
    eth: number;
    usdcTx: string;
    ethTx: string;
  }>(`/demo/mint`, {
    method: "POST",
    body: JSON.stringify({ address }),
  });
}

/** POST /demo/price-feed: bind or unbind the demo USDC/USD feed. */
export function postDemoPriceFeed(bound: boolean) {
  return request<{ ok: boolean; priceFeedBound: boolean }>(`/demo/price-feed`, {
    method: "POST",
    body: JSON.stringify({ bound }),
  });
}

/** POST /reset: reseed A–E baseline */
export function postReset() {
  return request<{
    ok: boolean;
    wallets: ApiWallet[];
    transfers: TransferRecord[];
    events: ApiHookEvent[];
  }>(`/reset`, { method: "POST" });
}
