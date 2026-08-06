/**
 * Demo compliance pack — score + Opinion from the off-chain oracle COA.
 * Opinion / COA skills are MOCK (deterministic TypeScript, no live LLM).
 * Numeric score may be REAL on-chain when SCORE_SOURCE=onchain (see resolveWalletScore).
 */

import { ensureOracleEvaluation } from "./oracle/index.js";
import {
  decisionFromScore,
  ethOutFromSwap,
  resolveWalletRisk,
  swapUsdcAmount,
  toHookOutput,
} from "./scoring.js";
import type { CompliancePack, SwapQuote, Wallet } from "./types.js";

/**
 * Builds the full live compliance pack (Opinion) for a wallet.
 * Score + fee prefer COA / on-chain oracle (recommendedFeeBps).
 */
export async function buildCompliancePack(wallet: Wallet): Promise<CompliancePack> {
  const oracle = await ensureOracleEvaluation(wallet.id);
  const { score, feeBps: appliedFeeBps, source } = await resolveWalletRisk(wallet);
  const decision = decisionFromScore(score);
  const hookOutput = toHookOutput(decision);
  const opinion = oracle.opinion;
  const auditHash = opinion.auditHash;

  const riskLabel =
    decision === "block"
      ? "Blocked"
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
    summary: [
      `Score ${score}/100 · source=${source} · ${hookOutput} (${oracle.scoreResult.flow}).`,
      wallet.exploitConfirmed
        ? "Keeper confirmed exploit source — REVERT on pool swaps. P2P outflows contaminate B/C."
        : wallet.hopDistance
          ? `Contamination at ${wallet.hopDistance} hop(s) from origin ${wallet.originId ?? "A"}.`
          : "Clean wallet. No contamination from A yet — ALLOW at standard fee.",
      topFacts ? `Top facts: ${topFacts}.` : hopTag,
    ],
    agent: {
      status: opinion.status,
      documentType: opinion.documentType,
      confidence: opinion.confidence,
      humanReview: opinion.humanReview,
      retentionYears: opinion.retentionYears,
      auditHash,
      technicalOpinion: opinion.technicalOpinion,
      sarAnnex: opinion.sarAnnex,
      decisionRecord: opinion.decisionRecord,
      note: opinion.note,
    },
  };
}

/**
 * Preview a USDC→ETH swap against current wallet state (no mutation).
 * Score + fee follow beforeSwap resolution (on-chain COA fee → memory → hop).
 */
export async function buildSwapQuote(
  wallet: Wallet,
  preferredUsdc?: number,
): Promise<SwapQuote> {
  const { score, feeBps } = await resolveWalletRisk(wallet);
  const decision = decisionFromScore(score);
  const usdcIn = swapUsdcAmount(wallet, preferredUsdc);
  const ethOut = decision === "block" ? 0 : ethOutFromSwap(usdcIn, feeBps);

  return {
    walletId: wallet.id,
    usdcIn,
    ethOut: Math.round(ethOut * 10_000) / 10_000,
    feeBps,
    feePercent: Number((feeBps / 100).toFixed(2)),
    decision,
    hookOutput: toHookOutput(decision),
    score,
    canSettle: decision !== "block" && usdcIn > 0 && wallet.usdc >= usdcIn,
  };
}
