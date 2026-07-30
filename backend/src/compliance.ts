/**
 * Live compliance pack (dictamen) derived from current wallet state.
 * Replaces frontend `withHopOverlay` agent / technical opinion logic for the API.
 */

import {
  decisionFromScore,
  ethOutFromSwap,
  feeBpsFromHop,
  hopScore,
  swapUsdcAmount,
  toHookOutput,
} from "./scoring.js";
import type {
  CompliancePack,
  Decision,
  SarAnnex,
  SwapQuote,
  TechnicalOpinion,
  Wallet,
} from "./types.js";

const AUDIT_HASH: Record<string, string> = {
  A: "0xae01…xplt",
  B: "0xb0c1…000b",
  C: "0xc0c1…000c",
};

/**
 * Builds the Technical compliance opinion fields from live wallet risk state.
 * Content changes with ALLOW / FEE_OVERRIDE / REVERT bands.
 */
function buildTechnicalOpinion(
  wallet: Wallet,
  score: number,
  decision: Decision,
  appliedFeeBps: number,
  auditHash: string,
): TechnicalOpinion {
  const hop = wallet.hopDistance;
  const origin = wallet.originId ?? "A";
  const feePct = (appliedFeeBps / 100).toFixed(2);

  if (wallet.exploitConfirmed || decision === "block") {
    return {
      issued: true,
      objectAndScope: `${wallet.accountLabel} is treated as the exploit / contamination origin (or score ≥ 71). Pool cash-out attempts REVERT; outbound P2P can still contaminate B/C.`,
      riskAndScoring: `Score ${score} / 100 · REVERT band (71–100). Hop ${hop ?? 0} · origin ${origin}.`,
      typologies:
        "Exploit cash-out. Confirmed exposure — fail-closed; no discretion to settle on-pool.",
      sanctionsCheck:
        "Exploit event / keeper detection drives fail-closed treatment. Layer-1 screen reviewed.",
      sourcesConsulted: [
        "Keeper exploit-detection feed (confirmed cash-out cluster)",
        "Layer-1 on-chain sanctions screen (OFAC SDN / UN / EU mirrors)",
        `Off-chain score oracle — live score ${score} / hop ${hop ?? 0}`,
        `Outbound P2P graph (${wallet.id} → downstream wallets)`,
        "beforeSwap WalletBlocked emit + pool REVERT policy band (71–100)",
      ],
      decisionExecuted: "REVERT in beforeSwap · WalletBlocked · no settlement.",
      legalBasis: "Fail-closed RWA pool policy on confirmed exploit exposure.",
      recommendations:
        "Human review required. Watch outbound P2P for 1-hop fee overrides on recipients; then second-hop decay.",
      traceability: `audit_hash ${auditHash} · retention 5 years.`,
    };
  }

  if (decision === "fee_override") {
    return {
      issued: true,
      objectAndScope: `${wallet.accountLabel} received contaminated funds at ${hop}-hop from origin ${origin}. Full technical opinion issued for FEE_OVERRIDE path.`,
      riskAndScoring: `Score ${score} / 100 · FEE_OVERRIDE band (31–70). ${hop}-hop decay from origin ${origin}.`,
      typologies: `N-hop propagation (${hop}-hop). Exposure proportioned by decay factor 0.65^${hop}.`,
      sanctionsCheck:
        "Layer-1 screen clear for this address; risk is hop-derived from exploit origin, not a direct SDN hit.",
      sourcesConsulted: [
        "Layer-1 on-chain sanctions screen (OFAC SDN / UN / EU mirrors)",
        `Off-chain keeper score oracle (live score ${score} · ${hop}-hop)`,
        `P2P transfer graph (${wallet.accountLabel} ← origin ${origin})`,
        "Pool SwapObserved event log + lpFeeOverride receipt",
        "RWA pool policy bands (ALLOW 0–30 · FEE_OVERRIDE 31–70 · REVERT 71–100)",
      ],
      decisionExecuted: `FEE_OVERRIDE · lpFeeOverride ${feePct}% applied as EDD friction.`,
      legalBasis:
        "FATF risk-based approach · proportional fee friction on intermediate hop exposure.",
      recommendations:
        hop === 1
          ? "Treat as elevated EDD. If this wallet sends to the other clean peer (B↔C), expect 2-hop score ≈ 42 and 3% fee."
          : "Proportional friction applied. Continue monitoring further downstream hops; score decays toward ALLOW.",
      traceability: `audit_hash ${auditHash} · retention 5 years · hop=${hop} · origin=${origin}.`,
    };
  }

  return {
    issued: true,
    objectAndScope:
      hop == null
        ? `${wallet.accountLabel} has no inbound contamination from exploit source A. Legal opinion issued for the ALLOW path.`
        : `${wallet.accountLabel} previously showed hop exposure, but live score ${score} sits in the ALLOW band. Legal opinion issued for the ALLOW path.`,
    riskAndScoring: `Score ${score} / 100 · ALLOW band (0–30)${
      hop != null ? ` · hop ${hop} from ${origin}` : ""
    }.`,
    typologies:
      hop == null
        ? "None. No exploit link, no hop exposure."
        : "Prior N-hop link noted; current score below FEE_OVERRIDE threshold.",
    sanctionsCheck: "Layer-1 screen clear.",
    sourcesConsulted: [
      "Layer-1 on-chain sanctions screen (OFAC SDN / UN / EU mirrors)",
      `Off-chain keeper score oracle (live score ${score}${
        hop != null ? ` · ${hop}-hop` : " · clean"
      })`,
      `P2P transfer graph (${wallet.accountLabel}${
        origin && hop != null ? ` ← origin ${origin}` : " · no inbound contamination"
      })`,
      "Pool SwapObserved / WalletBlocked event log",
      "RWA pool policy bands (ALLOW 0–30 · FEE_OVERRIDE 31–70 · REVERT 71–100)",
    ],
    decisionExecuted: "ALLOW · standard pool fee 0.30%.",
    legalBasis: "FATF risk-based approach · permissive RWA pool policy.",
    recommendations:
      hop == null
        ? "Monitor for inbound P2P from Wallet A (or contaminated B). If received, expect N-hop decay fees."
        : "Keep ordinary monitoring. Re-open full technical opinion if an inbound tainted transfer raises score into FEE_OVERRIDE or REVERT.",
    traceability: `audit_hash ${auditHash} · retention 5 years.`,
  };
}

/**
 * Builds an optional SAR-support annex when FEE_OVERRIDE or REVERT applies.
 * Returns null for clean ALLOW wallets.
 */
function buildSarAnnex(
  wallet: Wallet,
  score: number,
  decision: Decision,
): SarAnnex {
  if (decision === "allow") return null;

  if (decision === "block" || wallet.exploitConfirmed) {
    return {
      produced: true,
      status: "support-draft (not filed)",
      activityPeriod: "exploit window",
      amountInvolved: `USD ${wallet.usdc.toLocaleString("en-US")} (ledger)`,
      operationState: "REVERTED",
      narrativeDescription:
        "Exploit source / REVERT-band wallet blocked from pool swaps; may still move funds P2P.",
      narrativeAnalysis:
        "Direct exploit cash-out or score ≥ 71 is dispositive for REVERT.",
      narrativeEvidence: `Keeper detection · score ${score} · beforeSwap revert.`,
      narrativeConclusion:
        "Reasonable basis for immediate REVERT. Hop fees apply only after outbound transfers.",
      warnings: [
        "Confidentiality — no tip-off",
        "Document status: support draft — not submitted",
      ],
    };
  }

  return {
    produced: true,
    status: "support-draft (not filed)",
    activityPeriod: "post-contamination window",
    amountInvolved: `USD ${wallet.usdc.toLocaleString("en-US")} USDC on ledger`,
    operationState: "FEE_OVERRIDE",
    narrativeDescription: `${wallet.accountLabel} shows ${wallet.hopDistance}-hop contamination from origin ${wallet.originId ?? "A"} (score ${score}).`,
    narrativeAnalysis:
      "Intermediate hop exposure warrants proportional fee friction and an internal evidence pack — not an autonomous filing.",
    narrativeEvidence: `P2P graph · keeper oracle score ${score} · lpFeeOverride ${(feeBpsFromHop(score, wallet.hopDistance) / 100).toFixed(2)}%.`,
    narrativeConclusion:
      "Reasonable suspicion for enhanced monitoring. Human decides whether BSA filing is required.",
    warnings: [
      "Confidentiality — no tip-off",
      "Document status: support draft — not submitted",
    ],
  };
}

/**
 * Builds the full live compliance pack (dictamen) for a wallet:
 * risk summary, technical opinion, SAR annex, and decision record.
 */
export function buildCompliancePack(wallet: Wallet): CompliancePack {
  const score = hopScore(wallet);
  const decision = decisionFromScore(score);
  const appliedFeeBps = feeBpsFromHop(score, wallet.hopDistance);
  const hookOutput = toHookOutput(decision);
  const auditHash = AUDIT_HASH[wallet.id] ?? "0xdemo…0000";

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
      wallet.exploitConfirmed
        ? "Keeper confirmed exploit source — REVERT on pool swaps. P2P outflows contaminate B/C."
        : wallet.hopDistance
          ? `Contamination at ${wallet.hopDistance} hop(s) from origin ${wallet.originId ?? "A"} · score ${score}.`
          : "Clean wallet. No contamination from A yet — ALLOW at standard fee.",
      decision === "fee_override"
        ? `lpFeeOverride ${(appliedFeeBps / 100).toFixed(2)}% applied as EDD friction.`
        : decision === "block"
          ? "beforeSwap reverts atomically — no settlement."
          : "Standard pool fee 0.30%.",
      hopTag,
    ],
    agent: {
      status:
        decision === "block"
          ? "Technical opinion · REVERT"
          : decision === "fee_override"
            ? `Technical opinion · ${wallet.hopDistance}-hop FEE_OVERRIDE`
            : "Legal opinion · ALLOW",
      documentType:
        decision === "allow" ? "legal-opinion" : "opinion + sar-annex",
      confidence:
        decision === "allow" ? "HIGH" : decision === "fee_override" ? "MEDIUM" : "HIGH",
      humanReview: decision !== "allow",
      retentionYears: 5,
      auditHash,
      technicalOpinion: buildTechnicalOpinion(
        wallet,
        score,
        decision,
        appliedFeeBps,
        auditHash,
      ),
      sarAnnex: buildSarAnnex(wallet, score, decision),
      decisionRecord: {
        score: String(score),
        output: hookOutput,
        mainFacts: `${wallet.accountLabel}; hop=${wallet.hopDistance ?? "none"}; origin=${wallet.originId ?? "—"}; USDC=${wallet.usdc.toLocaleString("en-US")}; ETH=${wallet.eth}.`,
        basis:
          decision === "block"
            ? "EXPLOIT_CASH_OUT_FAIL_CLOSED"
            : decision === "fee_override"
              ? "N_HOP_DECAY_FEE_OVERRIDE"
              : "SCORE_BELOW_FEE_OVERRIDE_THRESHOLD",
        nextReview:
          decision === "block"
            ? "Immediate human review · watch outbound P2P"
            : decision === "fee_override"
              ? "On further hop transfer or score band change"
              : "On inbound transfer from A or other tainted wallet",
      },
      note: "Internal operator documentation. The agent never files with any authority.",
    },
  };
}

/**
 * Preview a USDC→ETH swap against current wallet state (no mutation).
 */
export function buildSwapQuote(wallet: Wallet, preferredUsdc?: number): SwapQuote {
  const score = hopScore(wallet);
  const decision = decisionFromScore(score);
  const feeBps = feeBpsFromHop(score, wallet.hopDistance);
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
