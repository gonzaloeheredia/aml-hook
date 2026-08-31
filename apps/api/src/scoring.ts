/**
 * N-hop decay scoring and fee helpers for the AML Hook.
 * Same rules as the frontend / use-case doc (decay 0.65, ternary bands).
 *
 * Score / fee sources:
 * 1. On-chain ComplianceOracle.getRisk (agent-published score + feeBps)
 * 2. Memory COA ScoreResult after the keeper write
 * 3. hopScore() only when the live agent is off (tests / no key)
 */

import {
  DEFAULT_POLICY_KNOBS,
  formatFeePct,
  getPolicyKnobsSync,
  type PolicyKnobs,
} from "./chain/policy.js";
import { isMockDemoWallet } from "./demoMode.js";
import {
  preferOnChainScore,
  readRiskFromChain,
  type ScoreSource,
} from "./oracle/onchainReader.js";
import { isLiveCoaEnabled } from "./oracle/liveOpinion.js";
import { getOracleFeeBps, getOracleScore } from "./oracle/store.js";
import type {
  Decision,
  LatencyMitigation,
  Wallet,
  WalletId,
} from "./types.js";

export { formatFeePct };
export type { PolicyKnobs };

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
/** Deploy-default latency / inflow floor when keeper feeBps is absent (8%). Live value: `punitiveFeeBps`. */
export const LATENCY_FEE_BPS = DEFAULT_POLICY_KNOBS.punitiveFeeBps;
/** Inbound USD share (bps of current USD bag) that flags a medium-risk increment. */
export const INFLOW_THRESHOLD_BPS = 5000;
/** Wallet E deploy-default fee floor. Live value: hook `unscoredFeeThreshold`. */
export const UNSCORED_FEE_THRESHOLD_USD = DEFAULT_POLICY_KNOBS.unscoredFeeThresholdUsd;
/** Wallet E deploy-default revert floor. Live value: hook `unscoredRevertThreshold`. */
export const UNSCORED_REVERT_THRESHOLD_USD = DEFAULT_POLICY_KNOBS.unscoredRevertThresholdUsd;
/** Wallet E dust band deploy default. Live value: `proportionalFeeBps`. */
export const UNSCORED_DUST_FEE_BPS = DEFAULT_POLICY_KNOBS.proportionalFeeBps;
/** Wallet E mid band deploy default. Live value: `punitiveFeeBps`. */
export const UNSCORED_MID_FEE_BPS = DEFAULT_POLICY_KNOBS.punitiveFeeBps;

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
 * When the live agent is on, never invent a hop formula score.
 */
export function walletScore(wallet: Wallet): number {
  const hop = hopScore(wallet);
  const oracle = getOracleScore(wallet.id);
  if (isMockDemoWallet(wallet.id)) {
    return Math.max(oracle ?? 0, hop);
  }
  if (oracle != null) return oracle;
  if (isLiveCoaEnabled()) return 0;
  return hop;
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
  if (preferOnChainScore() && !isMockDemoWallet(wallet.id)) {
    const risk = await readRiskFromChain(wallet.address);
    if (risk != null && risk.updatedAt > 0) {
      const score = risk.score;
      const feeBps = risk.feeBps;
      return { score, feeBps, source: "onchain" };
    }
  }
  const memoryScore = getOracleScore(wallet.id);
  const memoryFee = getOracleFeeBps(wallet.id);
  if (memoryScore != null) {
    return {
      score: memoryScore,
      feeBps: memoryFee != null ? memoryFee : 0,
      source: "memory",
    };
  }
  if (isLiveCoaEnabled()) {
    return { score: 0, feeBps: 0, source: "unscored" };
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
 * Clean 0.30% · 1-hop punitive · 2-hop proportional · REVERT 0.
 * Hop fees follow live floor fees when the hook has been retuned.
 */
export function feeBpsFromHop(
  score: number,
  hopDistance: number | null,
  knobs: PolicyKnobs = getPolicyKnobsSync(),
): number {
  if (score >= 71) return 0;
  if (score <= 30) return BASE_FEE_BPS;
  if (hopDistance === 1) return knobs.punitiveFeeBps;
  if (hopDistance === 2) return knobs.proportionalFeeBps;
  return score >= 55 ? knobs.punitiveFeeBps : knobs.proportionalFeeBps;
}

/** ALLOW / FEE / REVERT band. The keeper writes on a tier or fee-band change, or when the last write aged out. */
export function scoreTier(score: number): "allow" | "fee" | "revert" {
  if (score >= 71) return "revert";
  if (score >= 31) return "fee";
  return "allow";
}

export function feeBand(feeBps: number, knobs: PolicyKnobs = getPolicyKnobsSync()): number {
  if (feeBps >= knobs.punitiveFeeBps) return knobs.punitiveFeeBps;
  if (knobs.proportionalFeeBps > 0 && feeBps >= knobs.proportionalFeeBps) {
    return knobs.proportionalFeeBps;
  }
  if (feeBps > 0) return 30;
  return 0;
}

/**
 * Whether the keeper should call `updateScore`.
 * Write on first publish, on an ALLOW/FEE/REVERT or 3%/8% band change, or when the
 * last write is at least as old as Floor B's window, so `updatedAt` cannot freeze
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
  /** Keeper heartbeat: always write so on-chain updatedAt stays fresh. */
  force?: boolean;
}): boolean {
  if (input.neverScored) return false;
  if (input.force) return true;
  if (input.priorScore == null || input.lastScoreAt == null) return true;
  if (input.now - input.lastScoreAt >= input.stalenessMs) return true;
  return (
    scoreTier(input.priorScore) !== scoreTier(input.nextScore) ||
    feeBand(input.priorFeeBps ?? 0) !== feeBand(input.nextFeeBps)
  );
}

/**
 * Picks how much USDC to sell in a swap: min(preferred, available balance).
 */
export function swapUsdcAmount(wallet: Wallet, preferred = DEFAULT_SWAP_USDC): number {
  return Math.min(preferred, Math.max(0, Math.floor(wallet.usdc)));
}

/**
 * Computes ETH received after selling `usdcIn` USDC, net of pool fee (bps).
 * Uses a constant-product approximation with a hardcoded ETH_USD rate. Demo only.
 * SwapQuote.ethOut values are illustrative, not real Uniswap v4 pool quotes.
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
 * Mitigation A: unknown wallet (Wallet E). Size quoted 1:1 USDC → USD.
 */
export function applyUnscoredBands(
  assessedUsd: number,
  knobs: PolicyKnobs = getPolicyKnobsSync(),
): {
  decision: Decision;
  feeBps: number;
  latencyMitigation: LatencyMitigation;
} {
  if (assessedUsd >= knobs.unscoredRevertThresholdUsd) {
    return {
      decision: "block",
      feeBps: 0,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    };
  }
  if (assessedUsd >= knobs.unscoredFeeThresholdUsd) {
    return {
      decision: "fee_override",
      feeBps: knobs.punitiveFeeBps,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    };
  }
  return {
    decision: "fee_override",
    feeBps: knobs.proportionalFeeBps,
    latencyMitigation: "SCORE_NEVER_WRITTEN",
  };
}

/** Floor B/D: dust pass, mid proportional, high punitive. */
export function publishedUsdBandFee(
  usd: number,
  knobs: PolicyKnobs = getPolicyKnobsSync(),
): number {
  if (usd >= knobs.unscoredRevertThresholdUsd) return knobs.punitiveFeeBps;
  if (usd >= knobs.unscoredFeeThresholdUsd) return knobs.proportionalFeeBps;
  return 0;
}

/**
 * Never-written wallet: Floor A (this swap) + Floor D (bag). Stricter fee wins.
 */
export function applyNeverScoredFloors(
  assessedUsd: number,
  bagUsd: number,
  knobs: PolicyKnobs = getPolicyKnobsSync(),
): {
  decision: Decision;
  feeBps: number;
  latencyMitigation: LatencyMitigation;
} {
  const a = applyUnscoredBands(assessedUsd, knobs);
  if (a.decision === "block") return a;
  const dFee = publishedUsdBandFee(bagUsd, knobs);
  return {
    decision: "fee_override",
    feeBps: a.feeBps > dFee ? a.feeBps : dFee,
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

