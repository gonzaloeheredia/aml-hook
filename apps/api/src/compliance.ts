/**
 * Demo compliance pack — score + Opinion from the Compliance Officer Agent.
 * Agent runs a connected skill/source pipeline; outcomes stay use-case aligned.
 * Includes §3.8 inflow elevation for Wallet D while the keeper is pending.
 */

import { ensureOracleEvaluation } from "./oracle/index.js";
import {
  applyLatencyFloor,
  ethOutFromSwap,
  inflowDeltaBps,
  INFLOW_THRESHOLD_BPS,
  resolveWalletRisk,
  swapUsdcAmount,
  toHookOutput,
} from "./scoring.js";
import { getLastKnownUsdc, isKeeperPending } from "./store.js";
import type { CompliancePack, SwapQuote, Wallet } from "./types.js";

/**
 * Resolves beforeSwap decision: oracle score/fee + §3.8 inflow floor (Wallet D).
 */
export async function resolveSwapDecision(wallet: Wallet): Promise<{
  oracleScore: number;
  score: number;
  feeBps: number;
  decision: ReturnType<typeof applyLatencyFloor>["decision"];
  hookOutput: ReturnType<typeof toHookOutput>;
  source: string;
  keeperPending: boolean;
  latencyMitigation: ReturnType<typeof applyLatencyFloor>["latencyMitigation"];
  hasSignificantInflow: boolean;
  deltaBps: number;
}> {
  const { score: oracleScore, feeBps: oracleFeeBps, source } =
    await resolveWalletRisk(wallet);
  const keeperPending = isKeeperPending(wallet.id);
  const deltaBps = inflowDeltaBps(wallet.usdc, getLastKnownUsdc(wallet.id));
  // Inflow fires when delta exceeds threshold and the keeper has not caught up
  // (Wallet D), or when ledger hop exists but oracle still reads as clean ALLOW.
  const hasSignificantInflow =
    deltaBps > INFLOW_THRESHOLD_BPS &&
    (keeperPending || (wallet.hopDistance != null && oracleScore <= 30));

  const floored = applyLatencyFloor({
    score: oracleScore,
    feeBps: oracleFeeBps,
    hasSignificantInflow,
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
    hasSignificantInflow,
    deltaBps,
  };
}

/**
 * Builds the full live compliance pack (Opinion) for a wallet.
 * Score + fee prefer COA / on-chain oracle; Wallet D may show inflow FEE_OVERRIDE.
 */
export async function buildCompliancePack(wallet: Wallet): Promise<CompliancePack> {
  const oracle = await ensureOracleEvaluation(wallet.id);
  const resolved = await resolveSwapDecision(wallet);
  const { score, feeBps: appliedFeeBps, decision, hookOutput, source } = resolved;
  const opinion = oracle.opinion;
  const auditHash = opinion.auditHash;
  const run = oracle.agentRun!;

  const riskLabel =
    decision === "block"
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
    resolved.latencyMitigation === "INFLOW_HEURISTIC"
      ? `§3.8 inflow heuristic: delta ${resolved.deltaBps} bps → FEE_OVERRIDE ${(appliedFeeBps / 100).toFixed(2)}% under stale oracle score ${score}.`
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
    summary: [
      `Score ${score}/100 · source=${source} · ${hookOutput} (${oracle.scoreResult.flow}).`,
      `COA ${run.runId}: ${run.skills.length} skills · ${run.sourcesConsulted.length} sources · ${run.durationMs}ms.`,
      wallet.exploitConfirmed
        ? "Compliance Officer Agent confirmed exploit source — REVERT on pool swaps. P2P outflows contaminate B/C/D."
        : wallet.id === "D" && resolved.keeperPending
          ? "Wallet D latency path: inbound P2P recorded; keeper has not published decay score yet."
          : wallet.hopDistance
            ? `Contamination at ${wallet.hopDistance} hop(s) from origin ${wallet.originId ?? "A"}.`
            : "Clean wallet. No contamination from A yet — ALLOW at standard fee.",
      latencySummary ?? (topFacts ? `Top facts: ${topFacts}.` : hopTag),
    ].filter(Boolean) as string[],
    agent: {
      status:
        resolved.latencyMitigation === "INFLOW_HEURISTIC"
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
          resolved.latencyMitigation === "INFLOW_HEURISTIC"
            ? "ORACLE_LATENCY_INFLOW_HEURISTIC"
            : opinion.decisionRecord.basis,
        mainFacts:
          resolved.latencyMitigation === "INFLOW_HEURISTIC"
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
  const resolved = await resolveSwapDecision(wallet);
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
  };
}
