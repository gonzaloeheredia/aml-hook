/**
 * Demo compliance pack — score + Opinion from the Compliance Officer Agent.
 * Agent runs a connected skill/source pipeline; outcomes stay use-case aligned.
 * Includes §3.8 inflow elevation for Wallet D while the keeper is pending.
 */

import { ensureOracleEvaluation } from "./oracle/index.js";
import {
  applyFullPolicy,
  ethOutFromSwap,
  inflowDeltaBps,
  INFLOW_THRESHOLD_BPS,
  resolveWalletRisk,
  swapUsdcAmount,
  toHookOutput,
} from "./scoring.js";
import {
  getLastKnownAt,
  getLastKnownUsdc,
  getLastScoreAt,
  isKeeperPending,
  isPriceFeedBound,
  isScoreStale,
  opsInCurrentWindow,
  windowUsd,
} from "./store.js";
import type { CompliancePack, SwapQuote, Wallet } from "./types.js";

/**
 * Resolves beforeSwap decision: unknown-wallet USD bands (E),
 * oracle score/fee, or §3.8 inflow floor (D).
 */
export async function resolveSwapDecision(
  wallet: Wallet,
  preferredUsdc?: number,
): Promise<{
  oracleScore: number;
  score: number;
  feeBps: number;
  decision: ReturnType<typeof applyFullPolicy>["decision"];
  hookOutput: ReturnType<typeof toHookOutput>;
  source: string;
  keeperPending: boolean;
  latencyMitigation: ReturnType<typeof applyFullPolicy>["latencyMitigation"];
  revertReason: ReturnType<typeof applyFullPolicy>["revertReason"];
  hasSignificantInflow: boolean;
  deltaBps: number;
  assessedUsd: number;
  inflowUsd: number;
  opsInWindow: number;
  isStale: boolean;
  priceFeedBound: boolean;
}> {
  const usdcIn = swapUsdcAmount(wallet, preferredUsdc);
  const ops = opsInCurrentWindow(wallet.id);
  const priceFeedBound = isPriceFeedBound();
  const lastKnown = getLastKnownUsdc(wallet.id);
  const lastScoreAt = getLastScoreAt(wallet.id) ?? 0;
  const lastKnownAt = getLastKnownAt(wallet.id);
  const inflowLive = lastScoreAt <= lastKnownAt;
  const rawInflow = wallet.usdc > lastKnown ? wallet.usdc - lastKnown : 0;
  const inflowUsd = inflowLive ? rawInflow : 0;
  const deltaBps = inflowLive ? inflowDeltaBps(wallet.usdc, lastKnown) : 0;

  if (wallet.neverScored) {
    const assessedUsd = usdcIn + windowUsd(wallet.id);
    const floored = applyFullPolicy({
      score: 0,
      hopDistance: null,
      recommendedFeeBps: 0,
      neverScored: true,
      assessedUsd,
      inflowUsd: 0,
      hasSignificantInflow: false,
      isStale: true,
      operationCount: ops,
      priceFeedBound,
    });
    return {
      oracleScore: 0,
      score: 0,
      feeBps: floored.feeBps,
      decision: floored.decision,
      hookOutput: toHookOutput(floored.decision),
      source: "unscored",
      keeperPending: false,
      latencyMitigation: floored.latencyMitigation,
      revertReason: floored.revertReason,
      hasSignificantInflow: false,
      deltaBps: 0,
      assessedUsd,
      inflowUsd: 0,
      opsInWindow: ops,
      isStale: true,
      priceFeedBound,
    };
  }

  const { score: oracleScore, feeBps: oracleFeeBps, source } =
    await resolveWalletRisk(wallet);
  const keeperPending = isKeeperPending(wallet.id);
  const isStale = isScoreStale(wallet.id);
  const hasSignificantInflow = deltaBps > INFLOW_THRESHOLD_BPS;

  const floored = applyFullPolicy({
    score: oracleScore,
    hopDistance: wallet.hopDistance,
    recommendedFeeBps: oracleFeeBps,
    neverScored: false,
    assessedUsd: usdcIn,
    inflowUsd,
    hasSignificantInflow,
    isStale,
    operationCount: ops,
    priceFeedBound,
  });

  return {
    oracleScore,
    score: oracleScore,
    feeBps: floored.feeBps,
    decision: floored.decision,
    hookOutput: toHookOutput(floored.decision),
    source,
    keeperPending,
    latencyMitigation: floored.latencyMitigation,
    revertReason: floored.revertReason,
    hasSignificantInflow,
    deltaBps,
    assessedUsd: usdcIn,
    inflowUsd,
    opsInWindow: ops,
    isStale,
    priceFeedBound,
  };
}

/**
 * Builds the full live compliance pack (Opinion) for a wallet.
 * Score + fee prefer COA / on-chain oracle; Wallet D may show inflow FEE_OVERRIDE.
 */
export async function buildCompliancePack(
  wallet: Wallet,
  preferredUsdc?: number,
): Promise<CompliancePack> {
  const oracle = await ensureOracleEvaluation(wallet.id);
  const resolved = await resolveSwapDecision(wallet, preferredUsdc);
  const { score, feeBps: appliedFeeBps, decision, hookOutput, source } = resolved;
  const opinion = oracle.opinion;
  const auditHash = opinion.auditHash;
  const run = oracle.agentRun!;

  const riskLabel =
    resolved.latencyMitigation === "MAGNITUDE_QUOTE_FAILED"
      ? "No price feed"
      : resolved.latencyMitigation === "INFLOW_MAGNITUDE"
        ? "Inflow · Magnitude block"
        : resolved.latencyMitigation === "STALE_WITH_POOL_ACTIVITY"
          ? "Stale score · Activity"
          : resolved.latencyMitigation === "ACTIVITY_WINDOW_CAP"
            ? "Burst · Activity window"
            : wallet.neverScored
              ? decision === "block"
                ? "Unknown · Magnitude block"
                : "Unknown"
              : decision === "block"
                ? "Blocked"
                : resolved.latencyMitigation === "INFLOW_HEURISTIC"
                  ? "Inflow · Latency floor"
                  : decision === "fee_override"
                    ? wallet.hopDistance === 1
                      ? "1-hop · Punitive"
                      : wallet.hopDistance === 2
                        ? "2-hop · Proportional"
                        : "Medium Risk"
                    : "Low Risk";

  const hopTag =
    wallet.hopDistance == null
      ? "Clean path"
      : wallet.hopDistance === 0
        ? "Exploit source"
        : `${wallet.hopDistance}-hop decay`;

  const topFacts = oracle.scoreResult.triggeringFacts
    .filter((f) => f.dimension !== "MT")
    .slice(0, 2)
    .map((f) => f.type)
    .join(", ");

  const latencySummary =
    resolved.latencyMitigation === "MAGNITUDE_QUOTE_FAILED"
      ? "No bound USD price feed — fail-closed (MagnitudeQuoteFailed)."
      : resolved.latencyMitigation === "INFLOW_MAGNITUDE"
        ? `Inbound USD ${resolved.inflowUsd.toLocaleString("en-US")} ≥ $25,000 → REVERT (InflowMagnitudeBlocked).`
        : resolved.latencyMitigation === "STALE_WITH_POOL_ACTIVITY"
          ? "Score older than 120s and this wallet already swapped in the hour → FEE_OVERRIDE 8%."
          : resolved.latencyMitigation === "ACTIVITY_WINDOW_CAP"
            ? `Already ${resolved.opsInWindow} ops in the hour (cap 3) → FEE_OVERRIDE 8% on this swap.`
            : resolved.latencyMitigation === "INFLOW_HEURISTIC"
              ? `Inflow heuristic: inbound USD ${resolved.inflowUsd.toLocaleString("en-US")} is ${resolved.deltaBps} bps of current USD → FEE_OVERRIDE ${(appliedFeeBps / 100).toFixed(2)}% (differential).`
              : resolved.latencyMitigation === "SCORE_NEVER_WRITTEN"
                ? `Unknown wallet · assessed USD ${resolved.assessedUsd.toLocaleString("en-US")} (this swap + 1h window).`
                : resolved.keeperPending
                  ? "Keeper updateScore pending for this wallet (latency window)."
                  : null;

  return {
    walletId: wallet.id,
    address: wallet.address,
    accountLabel: wallet.accountLabel,
    score,
    decision,
    hookOutput,
    appliedFeeBps,
    feePercent: Number((appliedFeeBps / 100).toFixed(2)),
    hopDistance: wallet.hopDistance,
    originId: wallet.originId,
    exploitConfirmed: wallet.exploitConfirmed,
    usdc: wallet.usdc,
    eth: wallet.eth,
    riskLabel,
    keeperPending: resolved.keeperPending,
    latencyMitigation: resolved.latencyMitigation,
    revertReason: resolved.revertReason,
    assessedUsd: resolved.assessedUsd,
    opsInWindow: resolved.opsInWindow,
    isStale: resolved.isStale,
    priceFeedBound: resolved.priceFeedBound,
    summary: [
      `Score ${score}/100 · source=${source} · ${hookOutput} (${oracle.scoreResult.flow}).`,
      `COA ${run.runId}: ${run.skills.length} skills · ${run.sourcesConsulted.length} sources · ${run.durationMs}ms.`,
      wallet.neverScored
        ? "Wallet E is unknown (no oracle row). Swap size decides 3%, 8%, or REVERT."
        : wallet.exploitConfirmed
          ? "Exploit source — REVERT on pool swaps. P2P outflows contaminate B, C, or D."
          : wallet.id === "D" && resolved.keeperPending
            ? "Wallet D: inbound P2P recorded; keeper has not published the decay score yet."
            : wallet.hopDistance
              ? `Contamination at ${wallet.hopDistance} hop(s) from origin ${wallet.originId ?? "A"}.`
              : wallet.id === "D"
                ? "Wallet D has a published score of 0. Already-held funds ALLOW at 0.30%."
                : "Clean wallet. No contamination from A yet — ALLOW at standard fee.",
      latencySummary ?? (topFacts ? `Top facts: ${topFacts}.` : hopTag),
    ].filter(Boolean) as string[],
    agent: {
      status:
        resolved.latencyMitigation === "SCORE_NEVER_WRITTEN"
          ? decision === "block"
            ? "Technical opinion · REVERT (unknown)"
            : "Technical opinion · FEE_OVERRIDE (unknown)"
          : resolved.latencyMitigation === "INFLOW_HEURISTIC"
            ? "Technical opinion · FEE_OVERRIDE (inflow)"
            : opinion.status,
      documentType: opinion.documentType,
      confidence: opinion.confidence,
      humanReview: opinion.humanReview || resolved.latencyMitigation != null,
      retentionYears: opinion.retentionYears,
      auditHash,
      technicalOpinion: opinion.technicalOpinion,
      sarAnnex: opinion.sarAnnex,
      decisionRecord: {
        ...opinion.decisionRecord,
        output: hookOutput,
        basis:
          resolved.latencyMitigation === "SCORE_NEVER_WRITTEN"
            ? "UNKNOWN_WALLET_USD_BANDS"
            : resolved.latencyMitigation === "INFLOW_HEURISTIC"
              ? "ORACLE_LATENCY_INFLOW_HEURISTIC"
              : opinion.decisionRecord.basis,
        mainFacts:
          resolved.latencyMitigation === "SCORE_NEVER_WRITTEN"
            ? `Wallet E unknown; no oracle row; ${hookOutput} at ${(appliedFeeBps / 100).toFixed(2)}% (or revert at $25,000).`
            : resolved.latencyMitigation === "INFLOW_HEURISTIC"
              ? `WHO ${wallet.accountLabel}; stale oracle score ${score}; inflow deltaBps=${resolved.deltaBps}; FEE_OVERRIDE ${(appliedFeeBps / 100).toFixed(2)}%.`
              : opinion.decisionRecord.mainFacts,
        nextReview:
          resolved.keeperPending
            ? "Keeper catch-up → expect decay score ~65 (1-hop from A)"
            : opinion.decisionRecord.nextReview,
      },
      note: opinion.note,
      run: {
        runId: run.runId,
        role: run.role,
        flow: run.flow,
        durationMs: run.durationMs,
        skillsExecuted: run.skills.map((s) => s.skill),
        sourcesConsulted: run.sourcesConsulted,
        publishTxHash: oracle.onChainPublish?.txHash,
        publishStatus: oracle.onChainPublish?.status,
      },
    },
  };
}

/**
 * Preview a USDC→ETH swap against current wallet state (no mutation).
 * Applies §3.8 inflow floor when Wallet D swaps under a stale score.
 */
export async function buildSwapQuote(
  wallet: Wallet,
  preferredUsdc?: number,
): Promise<SwapQuote> {
  const resolved = await resolveSwapDecision(wallet, preferredUsdc);
  const usdcIn = swapUsdcAmount(wallet, preferredUsdc);
  const ethOut =
    resolved.decision === "block" ? 0 : ethOutFromSwap(usdcIn, resolved.feeBps);

  return {
    walletId: wallet.id,
    usdcIn,
    ethOut: Math.round(ethOut * 10_000) / 10_000,
    feeBps: resolved.feeBps,
    feePercent: Number((resolved.feeBps / 100).toFixed(2)),
    decision: resolved.decision,
    hookOutput: resolved.hookOutput,
    score: resolved.oracleScore,
    canSettle:
      resolved.decision !== "block" && usdcIn > 0 && wallet.usdc >= usdcIn,
    oracleScore: resolved.oracleScore,
    keeperPending: resolved.keeperPending,
    latencyMitigation: resolved.latencyMitigation,
    revertReason: resolved.revertReason,
    assessedUsd: resolved.assessedUsd,
    opsInWindow: resolved.opsInWindow,
    isStale: resolved.isStale,
    priceFeedBound: resolved.priceFeedBound,
  };
}
