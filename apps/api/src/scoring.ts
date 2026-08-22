/**
 * N-hop decay scoring and fee helpers for the AML Hook.
 * Same rules as the frontend / use-case doc (decay 0.65, ternary bands).
 *
 * Score / fee sources (hybrid beforeSwap path for the demo):
 * 1. REAL on-chain — ComplianceOracle.getRisk (score + feeBps) when SCORE_SOURCE=onchain
 * 2. MOCK memory — COA ScoreResult (finalScore + recommendedFeeBps)
 * 3. Formula fallback — hopScore() / feeBpsFromHop()
 */

import {
  preferOnChainScore,
  readRiskFromChain,
  type ScoreSource,
} from "./oracle/onchainReader.js";
import { getOracleFeeBps, getOracleScore } from "./oracle/store.js";
import type {
  Decision,
  LatencyMitigation,
  RevertReason,
  Wallet,
  WalletId,
} from "./types.js";

/** Contamination weight retained per hop. */
export const DECAY_FACTOR = 0.65;
/** Score assigned to a confirmed exploit origin (Wallet A). */
export const ORIGIN_EXPLOIT_SCORE = 100;
/** Demo mark: 1 ETH = 1,000 USDC. */
export const ETH_USD = 1_000;
/** Default swap size in USDC (capped by wallet balance). */
export const DEFAULT_SWAP_USDC = 1_000;
/** Exploit / tainted source wallet in this demo. */
export const EXPLOIT_SOURCE: WalletId = "A";
/** Standard pool fee in basis points (0.30%). */
export const BASE_FEE_BPS = 30;
/** §3.8 latency / inflow floor when keeper feeBps is absent (8%). */
export const LATENCY_FEE_BPS = 800;
/** Inbound USD share (bps of current USD bag) that flags a medium-risk increment. */
export const INFLOW_THRESHOLD_BPS = 5000;
/** Wallet E: assessed USD below this pays 3%. */
export const UNSCORED_FEE_THRESHOLD_USD = 1_000;
/** Wallet E: assessed USD at or above this reverts. */
export const UNSCORED_REVERT_THRESHOLD_USD = 25_000;
/** Wallet E dust band (under $1,000). */
export const UNSCORED_DUST_FEE_BPS = 300;
/** Wallet E mid band ($1,000–$24,999) and D inflow floor. */
export const UNSCORED_MID_FEE_BPS = 800;

/**
 * Fallback N-hop score when the oracle has not written a value yet.
 * - Confirmed exploit → 100
 * - No hops → 0
 * - With hops → 100 × 0.65^hops
 */
export function hopScore(wallet: Wallet): number {
  if (wallet.neverScored) return 0;
  if (wallet.exploitConfirmed) return ORIGIN_EXPLOIT_SCORE;
  if (wallet.hopDistance == null) return 0;
  return Math.round(
    ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** wallet.hopDistance * 1.0,
  );
}

/**
 * Sync score for paths that cannot await (prefer memory COA, else hop).
 * Prefer `resolveWalletScore` for beforeSwap / quotes when on-chain is enabled.
 */
export function walletScore(wallet: Wallet): number {
  const oracle = getOracleScore(wallet.id);
  if (oracle != null) return oracle;
  return hopScore(wallet);
}

/**
 * beforeSwap-style resolution: on-chain getRisk (if updatedAt>0) → memory COA → hop.
 * Unset oracle rows score=0; ignore those so demo still works before first publish.
 */
export async function resolveWalletScore(
  wallet: Wallet,
): Promise<{ score: number; source: ScoreSource }> {
  const resolved = await resolveWalletRisk(wallet);
  return { score: resolved.score, source: resolved.source };
}

/**
 * Score + applied fee from COA/oracle. Fee prefers COA recommendedFeeBps / on-chain feeBps.
 */
export async function resolveWalletRisk(wallet: Wallet): Promise<{
  score: number;
  feeBps: number;
  source: ScoreSource;
}> {
  if (wallet.neverScored) {
    return { score: 0, feeBps: 0, source: "unscored" };
  }
  if (preferOnChainScore()) {
    const risk = await readRiskFromChain(wallet.address);
    if (risk != null && risk.updatedAt > 0) {
      const score = risk.score;
      const feeBps =
        risk.feeBps > 0 ? risk.feeBps : feeBpsFromHop(score, wallet.hopDistance);
      return { score, feeBps, source: "onchain" };
    }
  }
  const memoryScore = getOracleScore(wallet.id);
  const memoryFee = getOracleFeeBps(wallet.id);
  if (memoryScore != null) {
    return {
      score: memoryScore,
      feeBps:
        memoryFee != null
          ? memoryFee
          : feeBpsFromHop(memoryScore, wallet.hopDistance),
      source: "memory",
    };
  }
  const score = hopScore(wallet);
  return {
    score,
    feeBps: feeBpsFromHop(score, wallet.hopDistance),
    source: "hop",
  };
}

/**
 * Maps a numeric score to the hook's ternary decision:
 * ALLOW (0–30), FEE_OVERRIDE (31–70), or REVERT/block (71–100).
 */
export function decisionFromScore(score: number): Decision {
  if (score >= 71) return "block";
  if (score >= 31) return "fee_override";
  return "allow";
}

/**
 * COA fee schedule helper (also used as fallback when oracle feeBps is unset).
 * Clean 0.30% · 1-hop 8% · 2-hop 3% · REVERT 0.
 */
export function feeBpsFromHop(score: number, hopDistance: number | null): number {
  if (score >= 71) return 0;
  if (score <= 30) return BASE_FEE_BPS;
  if (hopDistance === 1) return 800;
  if (hopDistance === 2) return 300;
  return score >= 55 ? 800 : 300;
}

/** ALLOW / FEE / REVERT band — keeper writes on a tier/fee-band change, or when the last write aged out. */
export function scoreTier(score: number): "allow" | "fee" | "revert" {
  if (score >= 71) return "revert";
  if (score >= 31) return "fee";
  return "allow";
}

export function feeBand(feeBps: number): 30 | 300 | 800 | 0 {
  if (feeBps >= 550) return 800;
  if (feeBps >= 100) return 300;
  if (feeBps > 0) return 30;
  return 0;
}

/**
 * Whether the keeper should call `updateScore`.
 * Write on first publish, on an ALLOW/FEE/REVERT or 3%/8% band change, or when the
 * last write is at least as old as Floor B's window — so `updatedAt` cannot freeze
 * under a skip and trip Floor B on a stable clean wallet (whitepaper §8.4).
 */
export function shouldPublishScore(input: {
  neverScored: boolean;
  priorScore: number | null;
  nextScore: number;
  priorFeeBps: number | null;
  nextFeeBps: number;
  lastScoreAt: number | null;
  now: number;
  stalenessMs: number;
}): boolean {
  if (input.neverScored) return false;
  if (input.priorScore == null || input.lastScoreAt == null) return true;
  if (input.now - input.lastScoreAt >= input.stalenessMs) return true;
  return (
    scoreTier(input.priorScore) !== scoreTier(input.nextScore) ||
    feeBand(input.priorFeeBps ?? 0) !== feeBand(input.nextFeeBps)
  );
}

/**
 * RiskPolicy.decide + hook-local Mitigation C, same order as AmlHookLogic.
 */
export function applyFullPolicy(input: {
  score: number;
  hopDistance: number | null;
  recommendedFeeBps: number;
  neverScored: boolean;
  assessedUsd: number;
  inflowUsd: number;
  hasSignificantInflow: boolean;
  isStale: boolean;
  operationCount: number;
  priceFeedBound: boolean;
}): {
  decision: Decision;
  feeBps: number;
  latencyMitigation: LatencyMitigation;
  revertReason: RevertReason;
} {
  if (input.score >= 71) {
    return {
      decision: "block",
      feeBps: 0,
      latencyMitigation: null,
      revertReason: "WalletBlocked",
    };
  }

  if (input.neverScored) {
    if (!input.priceFeedBound) {
      return {
        decision: "block",
        feeBps: 0,
        latencyMitigation: "MAGNITUDE_QUOTE_FAILED",
        revertReason: "MagnitudeQuoteFailed",
      };
    }
    const bands = applyUnscoredBands(input.assessedUsd);
    return {
      ...bands,
      revertReason:
        bands.decision === "block" ? "UnscoredMagnitudeBlocked" : null,
    };
  }

  if (input.inflowUsd > 0 && !input.priceFeedBound) {
    return {
      decision: "block",
      feeBps: 0,
      latencyMitigation: "MAGNITUDE_QUOTE_FAILED",
      revertReason: "MagnitudeQuoteFailed",
    };
  }

  if (input.inflowUsd >= UNSCORED_REVERT_THRESHOLD_USD) {
    return {
      decision: "block",
      feeBps: 0,
      latencyMitigation: "INFLOW_MAGNITUDE",
      revertReason: "InflowMagnitudeBlocked",
    };
  }

  if (input.score >= 31) {
    const feeBps =
      input.recommendedFeeBps > 0 && input.recommendedFeeBps !== BASE_FEE_BPS
        ? input.recommendedFeeBps
        : feeBpsFromHop(input.score, input.hopDistance);
    return {
      decision: "fee_override",
      feeBps,
      latencyMitigation: null,
      revertReason: null,
    };
  }

  if (input.hasSignificantInflow) {
    return {
      decision: "fee_override",
      feeBps: LATENCY_FEE_BPS,
      latencyMitigation: "INFLOW_HEURISTIC",
      revertReason: null,
    };
  }

  if (input.isStale && input.operationCount > 0) {
    return {
      decision: "fee_override",
      feeBps: LATENCY_FEE_BPS,
      latencyMitigation: "STALE_WITH_POOL_ACTIVITY",
      revertReason: null,
    };
  }

  // Default Mitigation C cap (on-chain `maxOpsInWindow`; hook governor retunes).
  if (input.operationCount >= 3) {
    return {
      decision: "fee_override",
      feeBps: LATENCY_FEE_BPS,
      latencyMitigation: "ACTIVITY_WINDOW_CAP",
      revertReason: null,
    };
  }

  return {
    decision: "allow",
    feeBps: BASE_FEE_BPS,
    latencyMitigation: null,
    revertReason: null,
  };
}

/**
 * Picks how much USDC to sell in a swap: min(preferred, available balance).
 */
export function swapUsdcAmount(wallet: Wallet, preferred = DEFAULT_SWAP_USDC): number {
  return Math.min(preferred, Math.max(0, Math.floor(wallet.usdc)));
}

/**
 * Computes ETH received after selling `usdcIn` USDC, net of pool fee (bps).
 */
export function ethOutFromSwap(usdcIn: number, feeBps: number): number {
  if (usdcIn <= 0) return 0;
  const netUsdc = usdcIn * (1 - feeBps / 10_000);
  return netUsdc / ETH_USD;
}

/**
 * Maps an internal decision to the on-chain hook output label
 * (ALLOW / FEE_OVERRIDE / REVERT).
 */
export function toHookOutput(decision: Decision): "ALLOW" | "FEE_OVERRIDE" | "REVERT" {
  if (decision === "block") return "REVERT";
  if (decision === "fee_override") return "FEE_OVERRIDE";
  return "ALLOW";
}

/**
 * Type guard: returns true when `value` is a demo wallet id (A–E).
 */
export function isWalletId(value: string): value is WalletId {
  return (
    value === "A" ||
    value === "B" ||
    value === "C" ||
    value === "D" ||
    value === "E"
  );
}

/**
 * Mitigation A — unknown wallet (Wallet E). Size quoted 1:1 USDC → USD.
 */
export function applyUnscoredBands(assessedUsd: number): {
  decision: Decision;
  feeBps: number;
  latencyMitigation: LatencyMitigation;
} {
  if (assessedUsd >= UNSCORED_REVERT_THRESHOLD_USD) {
    return {
      decision: "block",
      feeBps: 0,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    };
  }
  if (assessedUsd >= UNSCORED_FEE_THRESHOLD_USD) {
    return {
      decision: "fee_override",
      feeBps: UNSCORED_MID_FEE_BPS,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    };
  }
  return {
    decision: "fee_override",
    feeBps: UNSCORED_DUST_FEE_BPS,
    latencyMitigation: "SCORE_NEVER_WRITTEN",
  };
}

/**
 * Inflow heuristic (§3.8 Mitigation D / Wallet D): inbound USD / current USD in bps.
 * Demo USDC is quoted 1:1, so this is the USD share the hook uses on-chain.
 */
export function inflowDeltaBps(currentUsdc: number, lastKnownUsdc: number): number {
  if (currentUsdc <= 0) return 0;
  const delta = currentUsdc > lastKnownUsdc ? currentUsdc - lastKnownUsdc : 0;
  return Math.floor((delta * 10_000) / currentUsdc);
}

/**
 * Applies §3.8 FEE_OVERRIDE floors on top of the score-band decision.
 * Elevates ALLOW only; never softens REVERT or an existing FEE_OVERRIDE.
 */
export function applyLatencyFloor(input: {
  score: number;
  feeBps: number;
  hasSignificantInflow: boolean;
}): {
  decision: Decision;
  feeBps: number;
  latencyMitigation: LatencyMitigation;
} {
  const baseDecision = decisionFromScore(input.score);
  if (baseDecision === "block") {
    return { decision: "block", feeBps: 0, latencyMitigation: null };
  }
  if (baseDecision === "fee_override") {
    return {
      decision: "fee_override",
      feeBps: input.feeBps,
      latencyMitigation: null,
    };
  }
  if (input.hasSignificantInflow) {
    const feeBps =
      input.feeBps > 0 && input.feeBps !== BASE_FEE_BPS
        ? input.feeBps
        : LATENCY_FEE_BPS;
    return {
      decision: "fee_override",
      feeBps: feeBps > 0 ? feeBps : LATENCY_FEE_BPS,
      latencyMitigation: "INFLOW_HEURISTIC",
    };
  }
  return {
    decision: "allow",
    feeBps: BASE_FEE_BPS,
    latencyMitigation: null,
  };
}
