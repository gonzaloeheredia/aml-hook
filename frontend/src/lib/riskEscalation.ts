import type { DemoCase } from "@/data/cases";

/** Rolling 24h transferred-USD threshold that triggers a one-step risk upgrade. */
export const VOLUME_THRESHOLD_USD = 3_000;

export type RiskTier = "low" | "medium" | "high";

/**
 * Maps a demo case onto the three AML risk bands used by the hook.
 * ALLOW 0–30 · FEE_DIFERENCIAL 31–70 · REVERT 71–100.
 */
export function riskTierOf(demoCase: DemoCase): RiskTier {
  if (demoCase.decision === "block" || demoCase.score >= 71) return "high";
  if (demoCase.decision === "surcharge" || demoCase.score >= 31) return "medium";
  return "low";
}

/**
 * Next band after a volume breach. High is the ceiling (no further upgrade).
 */
function nextTier(tier: RiskTier): RiskTier {
  if (tier === "low") return "medium";
  return "high";
}

/**
 * Applies Medium-Risk / FEE_DIFERENCIAL presentation on top of a base wallet case.
 */
function asMedium(base: DemoCase, tradedUsd: number, swapCount: number): DemoCase {
  const totalUsd = base.structuring.totalUsd + tradedUsd;
  const txCount = base.structuring.txCount + swapCount;

  return {
    ...base,
    label: "Volume threshold — differential fee",
    shortLabel: base.id === "clean" ? "Elevated risk" : base.shortLabel,
    score: 54,
    riskLabel: "Medium Risk",
    decision: "surcharge",
    decisionLabel: "Differential fee",
    appliedFeeBps: 90,
    feeMultiplier: 3,
    typology: "Structuring (volume threshold)",
    flowPath: "surcharge",
    swapBuy: "991",
    gasUsed: 214_890,
    totalTimeSec: 2.37,
    structuring: {
      ...base.structuring,
      txCount,
      totalUsd,
      windowLabel: "24h",
    },
    summary: [
      `Transferred USD ${totalUsd.toLocaleString("en-US")} within 24h — crossed the USD ${VOLUME_THRESHOLD_USD.toLocaleString("en-US")} threshold.`,
      "Risk score upgraded from Low to Medium.",
      "Band 31–70: 3x surcharge (0.90%). No hard-block yet.",
    ],
    signals: [
      { label: "OFAC / sanctions", value: "Clear", tone: "ok" },
      { label: "Agent score", value: "54 / 100", tone: "warn" },
      { label: "24h volume", value: `$${totalUsd.toLocaleString("en-US")}`, tone: "warn" },
      { label: "Applied fee", value: "0.90% (3x)", tone: "warn" },
    ],
    tags: [
      { label: "24h threshold breach", tone: "warn" },
      { label: "Score upgraded", tone: "warn" },
      { label: "EDD friction", tone: "warn" },
    ],
    agent: {
      ...base.agent,
      status: "Decision record · score upgraded",
      hookOutput: "FEE_DIFERENCIAL",
      documentType: "decision-record",
      humanReview: false,
      technicalOpinion: {
        ...base.agent.technicalOpinion,
        issued: true,
        objectAndScope:
          "Wallet crossed the USD 3,000 / 24h transferred-volume threshold. Score raised one band.",
        riskAndScoring: "Score 54 · FEE_DIFERENCIAL band (31–70).",
        typologies: "Volume concentration / structuring red flag (FATF VA).",
        sanctionsCheck: "OFAC / UN / EU lists consulted — clear.",
        decisionExecuted: "FEE_DIFERENCIAL · 3x surcharge applied.",
        recommendations: "Monitor for further volume into the REVERT band (≥ USD 3,000 again from Medium).",
        legalBasis: "FATF Rec. risk-based approach · permissive pool policy with EDD friction.",
        traceability: "Retention 5 years (FATF Rec. 11; BSA).",
      },
      sarAnnex: {
        produced: true,
        status: "support-draft (not filed)",
        activityPeriod: "last 24h",
        amountInvolved: `USD ${totalUsd.toLocaleString("en-US")}`,
        operationState: "EXECUTED_WITH_DIFFERENTIAL_FEE",
        narrativeDescription:
          "Wallet transferred above the USD 3,000 rolling 24h threshold via repeated USDC→USDT swaps.",
        narrativeAnalysis:
          "Volume breach alone is enough to move the score into the Medium / FEE_DIFERENCIAL band under pool policy.",
        narrativeEvidence: "Live swap counter · on-chain SwapObserved events · sanctions clear.",
        narrativeConclusion:
          "Reasonable basis for differential fee. Not a finding of criminal liability.",
        warnings: [
          "Do not tip off the evaluated subject",
          "Document status: support draft — not submitted",
        ],
      },
      decisionRecord: {
        score: "54",
        output: "FEE_DIFERENCIAL",
        mainFacts: `24h volume USD ${totalUsd.toLocaleString("en-US")} ≥ ${VOLUME_THRESHOLD_USD}; score upgraded Low → Medium.`,
        basis: "VOLUME_THRESHOLD_24H_BREACH",
        nextReview: "Within 24h or on next swap",
      },
    },
  };
}

/**
 * Applies High-Risk / REVERT presentation on top of a base wallet case.
 */
function asHigh(base: DemoCase, tradedUsd: number, swapCount: number): DemoCase {
  const totalUsd = base.structuring.totalUsd + tradedUsd;
  const txCount = base.structuring.txCount + swapCount;
  const alreadyHigh = riskTierOf(base) === "high";

  if (alreadyHigh) {
    return {
      ...base,
      structuring: {
        ...base.structuring,
        txCount,
        totalUsd: base.sanctioned ? tradedUsd : totalUsd,
        windowLabel: "24h",
      },
    };
  }

  return {
    ...base,
    label: "Volume threshold — transaction blocked",
    shortLabel: "High risk",
    score: 85,
    riskLabel: "High Risk",
    decision: "block",
    decisionLabel: "Block",
    appliedFeeBps: 0,
    feeMultiplier: 0,
    typology: "Structuring (volume threshold)",
    flowPath: "block",
    swapBuy: "0",
    gasUsed: 92_110,
    totalTimeSec: 0.96,
    structuring: {
      ...base.structuring,
      txCount,
      totalUsd,
      windowLabel: "24h",
    },
    summary: [
      `Transferred USD ${totalUsd.toLocaleString("en-US")} within 24h — crossed the USD ${VOLUME_THRESHOLD_USD.toLocaleString("en-US")} threshold.`,
      "Risk score upgraded from Medium to High.",
      "Band 71–100: beforeSwap reverts; no settlement.",
    ],
    signals: [
      { label: "OFAC / sanctions", value: "Clear", tone: "ok" },
      { label: "Agent score", value: "85 / 100", tone: "bad" },
      { label: "24h volume", value: `$${totalUsd.toLocaleString("en-US")}`, tone: "bad" },
      { label: "Applied fee", value: "— (revert)", tone: "bad" },
    ],
    tags: [
      { label: "24h threshold breach", tone: "bad" },
      { label: "Score upgraded", tone: "bad" },
      { label: "Hard block", tone: "bad" },
    ],
    agent: {
      ...base.agent,
      status: "Technical opinion · REVERT",
      hookOutput: "REVERT",
      documentType: "opinion + sar-annex",
      humanReview: true,
      technicalOpinion: {
        ...base.agent.technicalOpinion,
        issued: true,
        objectAndScope:
          "Wallet already in Medium band crossed another USD 3,000 / 24h volume threshold. Score raised to High / REVERT.",
        riskAndScoring: "Score 85 · REVERT band (71–100).",
        typologies: "Sustained structuring / volume evasion pattern.",
        sanctionsCheck: "OFAC / UN / EU lists consulted — clear (behavioral block).",
        decisionExecuted: "REVERT in beforeSwap · no settlement · no fee.",
        recommendations: "Human review. Escalate to Compliance Officer for SAR support.",
        legalBasis: "FATF Rec. risk-based approach · pool fail-closed policy on High band.",
        traceability: "Retention 5 years (FATF Rec. 11; BSA).",
      },
      sarAnnex: {
        produced: true,
        status: "support-draft (not filed)",
        activityPeriod: "last 24h",
        amountInvolved: `USD ${totalUsd.toLocaleString("en-US")}`,
        operationState: "REVERTED",
        narrativeDescription:
          "Repeated swaps pushed 24h transferred volume past the policy threshold while the wallet was already Medium risk.",
        narrativeAnalysis:
          "Second-band upgrade under volume policy indicates reasonable suspicion of threshold evasion.",
        narrativeEvidence: "Live swap counter · prior FEE_DIFERENCIAL events · sanctions clear.",
        narrativeConclusion:
          "Reasonable suspicion supporting REVERT. Not a determination of criminal guilt.",
        warnings: [
          "Do not tip off the evaluated subject",
          "Document status: support draft — not submitted",
        ],
      },
      decisionRecord: {
        score: "85",
        output: "REVERT",
        mainFacts: `24h volume USD ${totalUsd.toLocaleString("en-US")} ≥ ${VOLUME_THRESHOLD_USD}; score upgraded Medium → High.`,
        basis: "VOLUME_THRESHOLD_24H_BREACH_ESCALATION",
        nextReview: "Immediate human review",
      },
    },
  };
}

/**
 * Returns the demo case adjusted for live 24h transferred volume.
 *
 * When `tradedUsd` reaches {@link VOLUME_THRESHOLD_USD}, the wallet’s risk
 * score / decision moves up exactly one category:
 * Low → Medium (FEE_DIFERENCIAL) · Medium → High (REVERT).
 * High (e.g. OFAC) is already at the ceiling.
 */
export function withVolumeEscalation(
  base: DemoCase,
  tradedUsd: number,
  swapCount: number,
): DemoCase {
  const breached = tradedUsd >= VOLUME_THRESHOLD_USD;
  if (!breached) {
    return {
      ...base,
      structuring: {
        ...base.structuring,
        txCount: base.structuring.txCount + swapCount,
        totalUsd: base.structuring.totalUsd + tradedUsd,
      },
    };
  }

  const upgraded = nextTier(riskTierOf(base));
  if (upgraded === "medium") return asMedium(base, tradedUsd, swapCount);
  return asHigh(base, tradedUsd, swapCount);
}
