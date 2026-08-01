/**
 * HTTP client for the AML Hook in-memory demo API (`apps/api/`).
 * Default base: http://localhost:4000 — override with NEXT_PUBLIC_API_URL.
 */

import type { DemoCaseId } from "@/data/cases";
import type { SimWallet, TransferRecord } from "@/lib/hopScoring";

export const API_BASE =
  process.env.NEXT_PUBLIC_API_URL?.replace(/\/$/, "") ||
  "http://localhost:4000";

export type ApiDecision = "allow" | "fee_override" | "block";
export type ApiHookOutput = "ALLOW" | "FEE_OVERRIDE" | "REVERT";

export type ApiWallet = SimWallet & {
  score?: number;
  decision?: ApiDecision;
  hookOutput?: ApiHookOutput;
  appliedFeeBps?: number;
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
  };
}

/**
 * Maps an API wallet list into a Record keyed by A/B/C.
 */
export function walletsRecord(
  list: ApiWallet[],
): Record<DemoCaseId, SimWallet> {
  const out = {} as Record<DemoCaseId, SimWallet>;
  for (const w of list) {
    out[w.id] = toSimWallet(w);
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
    throw new ApiError(
      data.error || `API ${res.status} on ${path}`,
      res.status,
    );
  }
  return data as T;
}

/** GET /health */
export function fetchHealth() {
  return request<{ ok: boolean; mode: string }>(`/health`);
}

/** GET /wallets */
export function fetchWallets() {
  return request<{ wallets: ApiWallet[] }>(`/wallets`);
}

/** GET /transfers */
export function fetchTransfers() {
  return request<{ transfers: TransferRecord[] }>(`/transfers`);
}

/** GET /events */
export function fetchEvents() {
  return request<{ events: ApiHookEvent[] }>(`/events`);
}

/** GET /wallets/:id/compliance */
export function fetchCompliance(id: DemoCaseId) {
  return request<ApiCompliancePack>(`/wallets/${id}/compliance`);
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
    ethReceived?: number;
    compliance: ApiCompliancePack;
  }>(`/swaps`, {
    method: "POST",
    body: JSON.stringify({
      walletId,
      ...(amountUsd != null ? { amountUsd } : {}),
    }),
  });
}

/** POST /reset — reseed A/B/C baseline */
export function postReset() {
  return request<{
    ok: boolean;
    wallets: ApiWallet[];
    transfers: TransferRecord[];
    events: ApiHookEvent[];
  }>(`/reset`, { method: "POST" });
}
