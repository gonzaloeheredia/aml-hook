/**
 * Hardcoded demo scenarios for the AML Hook frontend.
 * Each case maps to a fake wallet and drives the swap UI, flow simulator,
 * fee panel, and audit / compliance-agent report.
 */

export type Decision = "allow" | "surcharge" | "block";

export type DemoCaseId = "clean" | "structuring" | "ofac";

export interface DemoCase {
  id: DemoCaseId;
  label: string;
  shortLabel: string;
  wallet: string;
  walletLabel: string;
  score: number;
  riskLabel: string;
  decision: Decision;
  decisionLabel: string;
  baseFeeBps: number;
  appliedFeeBps: number;
  feeMultiplier: number;
  sanctioned: boolean;
  structuring: {
    txCount: number;
    windowLabel: string;
    totalUsd: number;
    amountUsd: number;
    counterparty: string;
    uniformAmounts: boolean;
  };
  typology: string;
  summary: string[];
  signals: { label: string; value: string; tone: "ok" | "warn" | "bad" }[];
  tags: { label: string; tone: "ok" | "warn" | "bad" }[];
  flowPath: "allow" | "surcharge" | "block";
  swapSell: string;
  swapBuy: string;
  sellToken: string;
  buyToken: string;
  /** Hardcoded gas / latency metrics for the demo */
  gasUsed: number;
  totalTimeSec: number;
  stepTimesSec: {
    sign: number;
    unlock: number;
    before: number;
    l1: number;
    l2: number;
    decide: number;
    out: number;
  };
  /**
   * Hardcoded Compliance Officer Agent report products
   * (task-regulatory-report outputs for the pool Compliance Officer).
   */
  agent: {
    status: string;
    hookOutput: "ALLOW" | "FEE_DIFERENCIAL" | "REVERT";
    documentType: string;
    recipient: string;
    confidence: "HIGH" | "MEDIUM" | "LOW";
    humanReview: boolean;
    retentionYears: number;
    auditHash: string;
    /** A. Technical compliance opinion sections */
    technicalOpinion: {
      issued: boolean;
      objectAndScope: string;
      riskAndScoring: string;
      typologies: string;
      sanctionsCheck: string;
      decisionExecuted: string;
      legalBasis: string;
      recommendations: string;
      traceability: string;
    };
    /** B. SAR support annex (draft only — never filed by the agent) */
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
    /** C. Decision record (short log for non-dictamen decisions) */
    decisionRecord: {
      score: string;
      output: string;
      mainFacts: string;
      basis: string;
      nextReview: string;
    };
    /** D. Pool aggregate monitoring snapshot (demo excerpt) */
    poolReport: {
      period: string;
      swapsEvaluated: string;
      outputDistribution: string;
      reasonableSuspicionCases: string;
    };
    note: string;
  };
}

/**
 * Display order of the three selectable demo wallets / risk cases.
 */
export const CASE_ORDER: DemoCaseId[] = ["clean", "structuring", "ofac"];

/**
 * Full hardcoded dataset keyed by case id.
 * Replace with live oracle / agent responses when the backend is wired.
 */
export const DEMO_CASES: Record<DemoCaseId, DemoCase> = {
  clean: {
    id: "clean",
    label: "Below threshold — standard fee",
    shortLabel: "Low risk",
    wallet: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    walletLabel: "Clean wallet",
    score: 18,
    riskLabel: "Low Risk",
    decision: "allow",
    decisionLabel: "Allow",
    baseFeeBps: 30,
    appliedFeeBps: 30,
    feeMultiplier: 1,
    sanctioned: false,
    structuring: {
      txCount: 2,
      windowLabel: "24h",
      totalUsd: 2100,
      amountUsd: 1000,
      counterparty: "0xRouter…aa12",
      uniformAmounts: false,
    },
    typology: "None",
    summary: [
      "Compliance Agent score is below the surcharge threshold (31).",
      "No OFAC match on Layer 1.",
      "Structuring counter within the normal band (1–5).",
    ],
    signals: [
      { label: "OFAC / sanctions", value: "Clear", tone: "ok" },
      { label: "Agent score", value: "18 / 100", tone: "ok" },
      { label: "Structuring txs", value: "2 in 24h", tone: "ok" },
      { label: "Applied fee", value: "0.30%", tone: "ok" },
    ],
    tags: [
      { label: "Clean history", tone: "ok" },
      { label: "Standard fee", tone: "ok" },
    ],
    flowPath: "allow",
    swapSell: "1.000",
    swapBuy: "1.000",
    sellToken: "USDC",
    buyToken: "USDT",
    gasUsed: 187_432,
    totalTimeSec: 1.84,
    stepTimesSec: {
      sign: 0.12,
      unlock: 0.18,
      before: 0.21,
      l1: 0.15,
      l2: 0.42,
      decide: 0.28,
      out: 0.48,
    },
    agent: {
      status: "Decision record issued",
      hookOutput: "ALLOW",
      documentType: "decision-record",
      recipient: "Pool operator Compliance Officer",
      confidence: "HIGH",
      humanReview: false,
      retentionYears: 5,
      auditHash: "0x8f3a…c21e",
      technicalOpinion: {
        issued: false,
        objectAndScope:
          "Not required — decision below reasonable-suspicion and REVERT thresholds.",
        riskAndScoring: "Score 18 · ALLOW band (0–30).",
        typologies: "None triggered.",
        sanctionsCheck: "OFAC / UN / EU lists consulted — clear.",
        decisionExecuted: "ALLOW · standard pool fee.",
        legalBasis: "FATF Rec. risk-based approach · permissive pool policy.",
        recommendations: "Minimal file logging. No escalation.",
        traceability: "Retention 5 years (FATF Rec. 11; BSA).",
      },
      sarAnnex: null,
      decisionRecord: {
        score: "18",
        output: "ALLOW",
        mainFacts:
          "Clean history; no mixer exposure; structuring count 2/24h within normal band.",
        basis: "SCORE_BELOW_SURCHARGE_THRESHOLD",
        nextReview: "On next material score change",
      },
      poolReport: {
        period: "2026-07-01 → 2026-07-26",
        swapsEvaluated: "1,284 / 1,310 pool swaps (98%)",
        outputDistribution: "ALLOW 91% · FEE_DIFERENCIAL 7% · REVERT 2%",
        reasonableSuspicionCases: "3 elevated · 1 SAR-support annex drafted",
      },
      note: "Internal operator documentation. The agent never files reports with any authority.",
    },
  },
  structuring: {
    id: "structuring",
    label: "Structuring — 3x differential fee",
    shortLabel: "Risky wallet",
    wallet: "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD",
    walletLabel: "Risky wallet",
    score: 54,
    riskLabel: "Medium Risk",
    decision: "surcharge",
    decisionLabel: "Differential fee",
    baseFeeBps: 30,
    appliedFeeBps: 90,
    feeMultiplier: 3,
    sanctioned: false,
    structuring: {
      txCount: 18,
      windowLabel: "24h",
      totalUsd: 18000,
      amountUsd: 1000,
      counterparty: "0xSameDest…9c4e",
      uniformAmounts: true,
    },
    typology: "Structuring (smurfing)",
    summary: [
      "18 swaps of ~USD 1,000 to the same destination within 24h.",
      "Artificially uniform amount sizes.",
      "Band 16–25: 3x surcharge (0.90%). No legal duty to hard-block.",
    ],
    signals: [
      { label: "OFAC / sanctions", value: "Clear", tone: "ok" },
      { label: "Agent score", value: "54 / 100", tone: "warn" },
      { label: "Structuring txs", value: "18 in 24h", tone: "warn" },
      { label: "Applied fee", value: "0.90% (3x)", tone: "warn" },
    ],
    tags: [
      { label: "Structuring detected", tone: "warn" },
      { label: "Uniform amounts", tone: "warn" },
      { label: "Same counterparty", tone: "warn" },
      { label: "EDD friction", tone: "warn" },
    ],
    flowPath: "surcharge",
    swapSell: "1.000",
    swapBuy: "991",
    sellToken: "USDC",
    buyToken: "USDT",
    gasUsed: 214_890,
    totalTimeSec: 2.37,
    stepTimesSec: {
      sign: 0.14,
      unlock: 0.19,
      before: 0.24,
      l1: 0.16,
      l2: 0.58,
      decide: 0.41,
      out: 0.65,
    },
    agent: {
      status: "Technical opinion + SAR support annex",
      hookOutput: "FEE_DIFERENCIAL",
      documentType: "opinion + sar-annex",
      recipient: "Pool operator Compliance Officer",
      confidence: "HIGH",
      humanReview: false,
      retentionYears: 5,
      auditHash: "0xb91c…44a0",
      technicalOpinion: {
        issued: true,
        objectAndScope:
          "Evaluated swap series (~USD 1,000 × 18) to a repeated recipient within 24h. Hop depth 3. Analytics judgment treated as third-party input.",
        riskAndScoring: "Score 54 · FEE_DIFERENCIAL band (31–70). Reasonable suspicion threshold reached on behavioral dimension.",
        typologies:
          "Structuring / smurfing — FATF VA red-flag indicators (2020) · FinCEN 31 U.S.C. § 5324. Alternative legit explanations discarded (no payroll / OTC desk pattern).",
        sanctionsCheck: "OFAC SDN, UN, EU lists consulted — clear. Negative findings recorded.",
        decisionExecuted:
          "FEE_DIFERENCIAL · 3x surcharge applied on-chain. No custody. SwapObserved event emitted.",
        legalBasis:
          "FATF Rec. risk-based approach · BSA monitoring expectations · no hard-block duty without sanctions hit.",
        recommendations:
          "Monitor for window completion to block band (≥26). Human decision if pattern continues. Legal advice if operator may be a BSA-covered VASP.",
        traceability:
          "audit_hash 0xb91c…44a0 · on-chain events listed · sources timestamped · retention 5 years.",
      },
      sarAnnex: {
        produced: true,
        status: "support-draft (not filed)",
        activityPeriod: "2026-07-25 → 2026-07-26",
        amountInvolved: "USD 18,000",
        operationState: "EXECUTED_WITH_DIFFERENTIAL_FEE",
        narrativeDescription:
          "Sequence of 18 near-identical USDC→USDT swaps of ~USD 1,000 to the same destination address within 24 hours.",
        narrativeAnalysis:
          "Uniform sizing under reporting thresholds plus counterparty concentration is inconsistent with ordinary retail flow and matches structuring typology.",
        narrativeEvidence:
          "Swap hashes and blocks in evidence file · structuring counter on-chain · sanctions lists clear.",
        narrativeConclusion:
          "Reasonable suspicion of structuring for threshold evasion. Conclusion concerns suspicion, not a finding of criminal liability.",
        warnings: [
          "30-day clock from initial detection if operator is BSA-obligated",
          "Do not tip off the evaluated subject",
          "Filing depends on operator’s legal classification under the BSA",
          "Document status: support draft — not submitted",
        ],
      },
      decisionRecord: {
        score: "54",
        output: "FEE_DIFERENCIAL",
        mainFacts:
          "18 uniform swaps; same counterparty; score in medium band; no sanctions hit.",
        basis: "STRUCTURING_PATTERN_EDD_FRICTION",
        nextReview: "Within 24h or on next swap",
      },
      poolReport: {
        period: "2026-07-01 → 2026-07-26",
        swapsEvaluated: "1,284 / 1,310 pool swaps (98%)",
        outputDistribution: "ALLOW 91% · FEE_DIFERENCIAL 7% · REVERT 2%",
        reasonableSuspicionCases: "3 elevated · 1 SAR-support annex drafted",
      },
      note: "Support material for the Compliance Officer. The agent never files with FinCEN or any authority.",
    },
  },
  ofac: {
    id: "ofac",
    label: "OFAC — transaction blocked",
    shortLabel: "Blocked",
    wallet: "0x8576aCC5C05D6Ce88f4e49bf65BdF0C62F91353C",
    walletLabel: "Sanctioned wallet",
    score: 100,
    riskLabel: "Blocked",
    decision: "block",
    decisionLabel: "Block",
    baseFeeBps: 30,
    appliedFeeBps: 0,
    feeMultiplier: 0,
    sanctioned: true,
    structuring: {
      txCount: 0,
      windowLabel: "24h",
      totalUsd: 0,
      amountUsd: 1000,
      counterparty: "—",
      uniformAmounts: false,
    },
    typology: "Sanctions match (OFAC)",
    summary: [
      "Layer 1: address present on the on-chain OFAC list.",
      "beforeSwap reverts before the swap executes.",
      "No fee applied: the operation never reaches settlement.",
    ],
    signals: [
      { label: "OFAC / sanctions", value: "MATCH", tone: "bad" },
      { label: "Agent score", value: "100 / 100", tone: "bad" },
      { label: "Structuring txs", value: "N/A", tone: "bad" },
      { label: "Applied fee", value: "— (revert)", tone: "bad" },
    ],
    tags: [
      { label: "OFAC sanctioned", tone: "bad" },
      { label: "Hard block", tone: "bad" },
      { label: "Layer 1 screen", tone: "bad" },
    ],
    flowPath: "block",
    swapSell: "1.000",
    swapBuy: "0",
    sellToken: "USDC",
    buyToken: "USDT",
    gasUsed: 92_110,
    totalTimeSec: 0.96,
    stepTimesSec: {
      sign: 0.11,
      unlock: 0.17,
      before: 0.2,
      l1: 0.22,
      l2: 0.08,
      decide: 0.09,
      out: 0.09,
    },
    agent: {
      status: "Technical opinion · REVERT",
      hookOutput: "REVERT",
      documentType: "opinion + sar-annex",
      recipient: "Pool operator Compliance Officer",
      confidence: "HIGH",
      humanReview: true,
      retentionYears: 5,
      auditHash: "0xde01…9f2b",
      technicalOpinion: {
        issued: true,
        objectAndScope:
          "Single swap attempt by a wallet with a confirmed OFAC SDN match. Domain analysis stopped after sanctions precedence.",
        riskAndScoring: "Score 100 · REVERT band (71–100).",
        typologies: "Sanctions exposure · OFAC SDN. No concurrent behavioral typology required for block.",
        sanctionsCheck:
          "OFAC SDN match confirmed at query block. UN/EU also screened. Hit drives fail-closed REVERT.",
        decisionExecuted:
          "REVERT in beforeSwap · WalletBlocked event · no settlement · no fee.",
        legalBasis:
          "OFAC IEEPA / 31 CFR Part 501 · OFAC virtual currency guidance (2021) · absolute sanctions override.",
        recommendations:
          "Human review of blocking file. Legal advice on blocked-property handling if operator holds any related assets. Do not tip off subject.",
        traceability:
          "audit_hash 0xde01…9f2b · sanctions list versions recorded · retention 5 years.",
      },
      sarAnnex: {
        produced: true,
        status: "support-draft (not filed)",
        activityPeriod: "2026-07-26",
        amountInvolved: "USD 1,000 (attempted)",
        operationState: "REVERTED",
        narrativeDescription:
          "Wallet attempted a USDC→USDT swap; Layer-1 OFAC screen returned an SDN match before execution.",
        narrativeAnalysis:
          "Sanctions match is dispositive under fail-closed policy. No need to prove structuring for the REVERT outcome.",
        narrativeEvidence:
          "Sanctions oracle hit · beforeSwap revert receipt · list version and block of query.",
        narrativeConclusion:
          "Reasonable basis for immediate block due to confirmed sanctions exposure. Not a determination of criminal guilt.",
        warnings: [
          "30-day clock if operator is BSA-obligated and elects to file",
          "Confidentiality — no tip-off",
          "Filing depends on operator BSA classification",
          "Document status: support draft — not submitted",
        ],
      },
      decisionRecord: {
        score: "100",
        output: "REVERT",
        mainFacts: "OFAC SDN match; absolute precedence; swap never settled.",
        basis: "SANCTIONS_HIT_FAIL_CLOSED",
        nextReview: "Periodic sanctions re-check per policy (90d)",
      },
      poolReport: {
        period: "2026-07-01 → 2026-07-26",
        swapsEvaluated: "1,284 / 1,310 pool swaps (98%)",
        outputDistribution: "ALLOW 91% · FEE_DIFERENCIAL 7% · REVERT 2%",
        reasonableSuspicionCases: "3 elevated · sanctions blocks: 2",
      },
      note: "Internal evidence file. The agent never responds to authorities or files SARs.",
    },
  },
};
