import type { DemoCase } from "@/data/cases";
import {
  decisionFromScore,
  ethOutFromSwap,
  feeBpsFromHop,
  hopScore,
  swapUsdcAmount,
  type SimWallet,
} from "@/lib/hopScoring";

/**
 * Formats USDC sell amount for the swap card (thousands separators).
 */
function formatUsdcSell(n: number): string {
  return n.toLocaleString("en-US");
}

/**
 * Formats ETH buy amount for the swap card.
 */
function formatEthBuy(n: number): string {
  if (n <= 0) return "0";
  return n.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  });
}

type Decision = "allow" | "fee_override" | "block";

/**
 * Rebuilds the full Technical compliance opinion from the live MetaMask /
 * N-hop wallet state so the dictamen tracks contamination changes.
 */
function buildLiveTechnicalOpinion(
  wallet: SimWallet,
  score: number,
  decision: Decision,
  appliedFeeBps: number,
  auditHash: string,
): DemoCase["agent"]["technicalOpinion"] {
  const hop = wallet.hopDistance;
  const origin = wallet.originId ?? "C";
  const feePct = (appliedFeeBps / 100).toFixed(2);

  if (wallet.exploitConfirmed || decision === "block") {
    return {
      issued: true,
      objectAndScope: `${wallet.accountLabel} is treated as the exploit / contamination origin (or score ≥ 71). Pool cash-out attempts REVERT; outbound P2P can still contaminate A/B.`,
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
          ? "Treat as elevated EDD. If this wallet sends to another clean account, expect 2-hop score ≈ 42 and 3% fee."
          : "Proportional friction applied. Continue monitoring further downstream hops; score decays toward ALLOW.",
      traceability: `audit_hash ${auditHash} · retention 5 years · hop=${hop} · origin=${origin}.`,
    };
  }

  // ALLOW — clean or decayed below threshold
  return {
    issued: false,
    objectAndScope:
      hop == null
        ? `${wallet.accountLabel} has no inbound contamination from exploit source C. Full dictamen not required.`
        : `${wallet.accountLabel} previously showed hop exposure, but live score ${score} sits in the ALLOW band. Short decision record only.`,
    riskAndScoring: `Score ${score} / 100 · ALLOW band (0–30)${
      hop != null ? ` · hop ${hop} from ${origin}` : ""
    }.`,
    typologies:
      hop == null
        ? "None. No exploit link, no hop exposure."
        : `Prior N-hop link noted; current score below FEE_OVERRIDE threshold.`,
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
        ? "Monitor for inbound P2P from Wallet C. If received, expect 1-hop score ≈ 65 and 8% fee override."
        : "Keep ordinary monitoring. Re-open full opinion if an inbound tainted transfer raises score into FEE_OVERRIDE or REVERT.",
    traceability: `audit_hash ${auditHash} · retention 5 years.`,
  };
}

/**
 * Live SAR annex only when FEE_OVERRIDE or REVERT warrants support drafting.
 */
function buildLiveSarAnnex(
  wallet: SimWallet,
  score: number,
  decision: Decision,
  base: DemoCase,
): DemoCase["agent"]["sarAnnex"] {
  if (decision === "allow") return null;

  if (decision === "block" || wallet.exploitConfirmed) {
    return (
      base.agent.sarAnnex ?? {
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
      }
    );
  }

  // fee_override
  return {
    produced: true,
    status: "support-draft (not filed)",
    activityPeriod: "post-contamination window",
    amountInvolved: `USD ${wallet.usdc.toLocaleString("en-US")} USDC on ledger`,
    operationState: "FEE_OVERRIDE",
    narrativeDescription: `${wallet.accountLabel} shows ${wallet.hopDistance}-hop contamination from origin ${wallet.originId ?? "C"} (score ${score}).`,
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
 * Overlays live MetaMask / N-hop simulation state onto a demo case
 * so Swap / Flow / Audit (including Technical compliance opinion) track
 * contamination changes.
 */
export function withHopOverlay(base: DemoCase, wallet: SimWallet): DemoCase {
  const score = hopScore(wallet);
  const decision = decisionFromScore(score);
  const appliedFeeBps = feeBpsFromHop(score, wallet.hopDistance);
  const feeMultiplier =
    decision === "block" ? 0 : decision === "allow" ? 1 : appliedFeeBps / base.baseFeeBps;

  const usdcIn = swapUsdcAmount(wallet, base.activity.amountUsd);
  const ethOut =
    decision === "block" ? 0 : ethOutFromSwap(usdcIn, appliedFeeBps);

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

  const decisionLabel =
    decision === "block" ? "Block" : decision === "fee_override" ? "Fee override" : "Allow";

  const hopTag =
    wallet.hopDistance == null
      ? "Clean path"
      : wallet.hopDistance === 0
        ? "Exploit source"
        : `${wallet.hopDistance}-hop decay`;

  const hookOutput =
    decision === "block" ? "REVERT" : decision === "fee_override" ? "FEE_OVERRIDE" : "ALLOW";

  const technicalOpinion = buildLiveTechnicalOpinion(
    wallet,
    score,
    decision,
    appliedFeeBps,
    base.agent.auditHash,
  );

  const agentStatus =
    decision === "block"
      ? "Technical opinion · REVERT"
      : decision === "fee_override"
        ? `Technical opinion · ${wallet.hopDistance}-hop FEE_OVERRIDE`
        : "Decision record issued";

  const documentType =
    decision === "allow" ? "decision-record" : "opinion + sar-annex";

  return {
    ...base,
    wallet: wallet.address,
    walletLabel: wallet.accountLabel,
    score,
    riskLabel,
    decision,
    decisionLabel,
    appliedFeeBps,
    feeMultiplier: Number.isFinite(feeMultiplier) ? Number(feeMultiplier.toFixed(2)) : 1,
    exploitConfirmed: wallet.exploitConfirmed,
    activity: {
      ...base.activity,
      hopDistance: wallet.hopDistance,
      origin: wallet.originId ?? "—",
      totalUsd: wallet.usdc,
      amountUsd: usdcIn,
    },
    typology: wallet.exploitConfirmed
      ? "Exploit cash-out"
      : wallet.hopDistance
        ? "N-hop propagation"
        : "None",
    flowPath: decision,
    sellToken: "USDC",
    buyToken: "ETH",
    swapSell: formatUsdcSell(usdcIn),
    swapBuy: formatEthBuy(ethOut),
    summary: [
      wallet.exploitConfirmed
        ? "Keeper confirmed exploit source — REVERT on pool swaps. P2P outflows contaminate A/B."
        : wallet.hopDistance
          ? `Contamination at ${wallet.hopDistance} hop(s) from origin ${wallet.originId ?? "C"} · score ${score}.`
          : "Clean wallet. No contamination from C yet — ALLOW at standard fee.",
      decision === "fee_override"
        ? `lpFeeOverride ${(appliedFeeBps / 100).toFixed(2)}% applied as EDD friction.`
        : decision === "block"
          ? "beforeSwap reverts atomically — no settlement."
          : "Standard pool fee 0.30%.",
      hopTag,
    ],
    signals: [
      {
        label: "Exploit / sanctions",
        value: wallet.exploitConfirmed ? "Exploit cluster" : "Clear",
        tone: wallet.exploitConfirmed ? "bad" : "ok",
      },
      {
        label: "Keeper score",
        value: `${score} / 100`,
        tone: decision === "block" ? "bad" : decision === "fee_override" ? "warn" : "ok",
      },
      {
        label: "Hop distance",
        value: wallet.hopDistance == null ? "—" : String(wallet.hopDistance),
        tone: decision === "allow" ? "ok" : "warn",
      },
      {
        label: "Applied fee",
        value:
          decision === "block" ? "— (revert)" : `${(appliedFeeBps / 100).toFixed(2)}%`,
        tone: decision === "allow" ? "ok" : "warn",
      },
    ],
    tags: [
      {
        label: hopTag,
        tone: decision === "block" ? "bad" : decision === "fee_override" ? "warn" : "ok",
      },
      {
        label: hookOutput,
        tone: decision === "block" ? "bad" : decision === "fee_override" ? "warn" : "ok",
      },
    ],
    agent: {
      ...base.agent,
      status: agentStatus,
      hookOutput,
      documentType,
      confidence: decision === "allow" ? "HIGH" : decision === "fee_override" ? "MEDIUM" : "HIGH",
      humanReview: decision !== "allow",
      technicalOpinion,
      sarAnnex: buildLiveSarAnnex(wallet, score, decision, base),
      decisionRecord: {
        ...base.agent.decisionRecord,
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
              : "On inbound transfer from C or other tainted wallet",
      },
    },
  };
}
