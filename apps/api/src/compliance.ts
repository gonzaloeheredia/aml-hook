/**
 * Demo compliance pack — score + Opinion from the Compliance Officer Agent.
 * Agent runs a connected skill/source pipeline; outcomes stay use-case aligned.
 * Includes §3.8 inflow elevation for Wallet D while the keeper is pending.
 */

import {
  dustExampleUsd,
  formatFeePct,
  formatUsdFloor,
  midBandExampleUsd,
  previewSwap,
  readPolicyKnobs,
  usdcToWei,
} from "./chain/index.js";
import { ensureOracleEvaluation } from "./oracle/index.js";
import { ethOutFromSwap, swapUsdcAmount } from "./scoring.js";
import { isKeeperPending } from "./store.js";
import type {
  CompliancePack,
  Decision,
  HookOutput,
  LatencyMitigation,
  RevertReason,
  SwapQuote,
  Wallet,
} from "./types.js";

/**
 * Display-only inflow share. Uses the demo wallet's nominal USDC, not on-chain balance.
 */
export function displayDeltaBps(inflowUsd: number, walletUsdc: number): number {
  if (walletUsdc <= 0) return 0;
  return Math.floor((inflowUsd * 10_000) / walletUsdc);
}

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
  decision: Decision;
  hookOutput: HookOutput;
  source: string;
  keeperPending: boolean;
  latencyMitigation: LatencyMitigation;
  revertReason: RevertReason;
  hasSignificantInflow: boolean;
  deltaBps: number;
  assessedUsd: number;
  inflowUsd: number;
  opsInWindow: number;
  isStale: boolean;
  priceFeedBound: boolean;
}> {
  const usdcIn = swapUsdcAmount(wallet, preferredUsdc);
  const preview = await previewSwap(wallet.address as `0x${string}`, usdcToWei(usdcIn));
  // Display-only: denominator uses the demo wallet's nominal usdc balance, not the real
  // on-chain balance. May diverge from on-chain deltaBps when wallet.usdc is stale.
  // This value is used only for latencySummary UI — it does not affect the compliance decision.
  const deltaBps = displayDeltaBps(preview.inflowUsd, wallet.usdc);

  return {
    oracleScore: preview.risk.score,
    score: preview.neverScored ? 0 : preview.risk.score,
    feeBps: preview.feeBps,
    decision: preview.decision,
    hookOutput: preview.hookOutput,
    source: "onchain",
    keeperPending: isKeeperPending(wallet.id),
    latencyMitigation: preview.latencyMitigation,
    revertReason: preview.revertReason,
    hasSignificantInflow: preview.hasSignificantInflow,
    deltaBps,
    assessedUsd: preview.assessedUsd,
    inflowUsd: preview.inflowUsd,
    opsInWindow: preview.opsInWindow,
    isStale: preview.isStale,
    priceFeedBound: preview.priceFeedBound,
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
  const knobs = await readPolicyKnobs();
  const midPct = formatFeePct(knobs.proportionalFeeBps);
  const highPct = formatFeePct(knobs.punitiveFeeBps);
  const feeFloor = formatUsdFloor(knobs.unscoredFeeThresholdUsd);
  const revertFloor = formatUsdFloor(knobs.unscoredRevertThresholdUsd);
  const { score, feeBps: appliedFeeBps, decision, hookOutput, source } = resolved;
  const opinion = oracle.opinion;
  const auditHash = opinion.auditHash;
  const run = oracle.agentRun!;

  const riskLabel =
    resolved.latencyMitigation === "MAGNITUDE_QUOTE_FAILED"
      ? "No price feed"
      : resolved.latencyMitigation === "INFLOW_MAGNITUDE"
        ? "Inflow · Floor D"
        : resolved.latencyMitigation === "STALE_WITH_POOL_ACTIVITY"
          ? "Stale score · Activity"
          : resolved.latencyMitigation === "ACTIVITY_WINDOW_CAP" ||
              resolved.latencyMitigation === "DAILY_AGGREGATION"
            ? "24h USD · Floor C"
            : wallet.neverScored
              ? decision === "block"
                ? "Unknown · Magnitude block"
                : "Unknown"
              : decision === "block"
                ? resolved.revertReason === "SanctionHit"
                  ? "OFAC · SanctionHit"
                  : resolved.revertReason === "WalletBlocked"
                    ? "Score · WalletBlocked"
                    : "Blocked"
                : resolved.latencyMitigation === "INFLOW_HEURISTIC"
                  ? "Inflow · Latency floor"
                  : decision === "fee_override"
                    ? wallet.hopDistance === 1
                      ? "1-hop · Punitive"
                      : wallet.hopDistance === 2
                        ? "2-hop · Proportional"
                        : "Medium Risk"
                    : "Low Risk";

  const hopFee =
    wallet.hopDistance === 1
      ? highPct
      : wallet.hopDistance === 2
        ? midPct
        : null;
  const hopTag =
    wallet.hopDistance == null
      ? "Clean path"
      : wallet.hopDistance === 0
        ? "Exploit source"
        : `${wallet.hopDistance}-hop decay${hopFee ? ` · ${hopFee}` : ""}`;
  const dust = formatUsdFloor(dustExampleUsd(knobs.unscoredFeeThresholdUsd));
  const midEx = formatUsdFloor(
    midBandExampleUsd(knobs.unscoredFeeThresholdUsd, knobs.unscoredRevertThresholdUsd),
  );

  const topFacts = oracle.scoreResult.triggeringFacts
    .filter((f) => f.dimension !== "MT")
    .slice(0, 2)
    .map((f) => f.type)
    .join(", ");

  const latencySummary =
    resolved.latencyMitigation === "MAGNITUDE_QUOTE_FAILED"
      ? "No bound USD price feed — fail-closed (MagnitudeQuoteFailed)."
      : resolved.latencyMitigation === "INFLOW_MAGNITUDE"
        ? `Inbound USD ${resolved.inflowUsd.toLocaleString("en-US")} ≥ ${revertFloor} → FEE_OVERRIDE ${highPct} (Floor D).`
        : resolved.latencyMitigation === "STALE_WITH_POOL_ACTIVITY"
          ? `Score older than 5 minutes and this wallet already swapped in the hour → Floor B (pass / ${midPct} / ${highPct} by swap USD).`
          : resolved.latencyMitigation === "ACTIVITY_WINDOW_CAP" ||
              resolved.latencyMitigation === "DAILY_AGGREGATION"
            ? `This swap makes the 24-hour USD total cross ${revertFloor} — Floor C REVERT.`
            : resolved.latencyMitigation === "INFLOW_HEURISTIC"
              ? `Inflow heuristic: inbound USD ${resolved.inflowUsd.toLocaleString("en-US")} is ${resolved.deltaBps} bps of current USD → FEE_OVERRIDE ${(appliedFeeBps / 100).toFixed(2)}% (differential).`
              : resolved.latencyMitigation === "SCORE_NEVER_WRITTEN"
                ? `Unknown wallet · this swap USD ${resolved.assessedUsd.toLocaleString("en-US")}; unpublished bag $${wallet.usdc.toLocaleString("en-US")} (Floor D).`
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
        ? wallet.usdc <= 0
          ? "Wallet E is unknown and empty. Fund it from clean C (no hop). Do not use A."
          : `Wallet E is unknown. Floor A is this swap; Floor D is the bag C sent ($${wallet.usdc.toLocaleString("en-US")}). Stricter fee wins.`
        : wallet.exploitConfirmed
          ? "Confirmed exploit — keeper score 100. Pool swaps WalletBlocked (SCORE_REVERT_BAND). Not on OFAC. P2P outflows contaminate B, C, or D. Do not fund E from A."
          : wallet.id === "D" && resolved.keeperPending
            ? "Wallet D: inbound P2P recorded; keeper has not published the decay score yet."
            : wallet.hopDistance
              ? `Contamination at ${wallet.hopDistance} hop(s) from origin ${wallet.originId ?? "A"}${hopFee ? ` · ${hopFee}` : ""}.`
              : wallet.id === "D"
                ? `Wallet D has a published score of 0. Already-held funds ALLOW at 0.30%. Floor B at ${feeFloor} → ${midPct}; C→D ${midEx} → ${midPct}; inbound ${revertFloor} → ${highPct}.`
                : wallet.id === "C"
                  ? `Clean wallet. Fund E (${dust} / ${midEx} / ${revertFloor}) or D (inflow). A→C is 1-hop · ${highPct}.`
                  : "Clean wallet. No contamination from A yet — ALLOW at standard fee.",
      wallet.neverScored && wallet.usdc <= 0
        ? `C→E ${dust} → ${midPct}; ${midEx} then ${feeFloor} swap → ${highPct} (A mid); ${revertFloor} bag → ${highPct} on a small swap; this swap ${revertFloor} → revert.`
        : (latencySummary ?? (topFacts ? `Top facts: ${topFacts}.` : hopTag)),
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
            ? `Wallet E unknown; bag $${wallet.usdc.toLocaleString("en-US")}; ${hookOutput} at ${(appliedFeeBps / 100).toFixed(2)}% (Floor A reverts this swap at ${revertFloor}).`
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
