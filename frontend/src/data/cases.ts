/**
 * Hardcoded demo scenarios for the AML Hook frontend.
 *
 * Use case (`docs/AML-Hook_Use_of_Case.txt`):
 * - A = exploit attacker → REVERT
 * - B and C both start clean (ALLOW)
 * - A→B or A→C → 1-hop · ~65 · 8%; tainted peer → 2-hop · ~42 · 3%
 * Live hop state comes from MetaMask simulation (`hopScoring` + `withHopOverlay`).
 */

export type Decision = "allow" | "fee_override" | "block";

export type DemoCaseId = "A" | "B" | "C";

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
  exploitConfirmed: boolean;
  activity: {
    hopDistance: number | null;
    origin: string;
    windowLabel: string;
    totalUsd: number;
    amountUsd: number;
    txCount: number;
  };
  typology: string;
  summary: string[];
  signals: { label: string; value: string; tone: "ok" | "warn" | "bad" }[];
  tags: { label: string; tone: "ok" | "warn" | "bad" }[];
  flowPath: "allow" | "fee_override" | "block";
  swapSell: string;
  swapBuy: string;
  sellToken: string;
  buyToken: string;
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
  agent: {
    status: string;
    hookOutput: "ALLOW" | "FEE_OVERRIDE" | "REVERT";
    documentType: string;
    recipient: string;
    confidence: "HIGH" | "MEDIUM" | "LOW";
    humanReview: boolean;
    retentionYears: number;
    auditHash: string;
    technicalOpinion: {
      issued: boolean;
      objectAndScope: string;
      riskAndScoring: string;
      typologies: string;
      sanctionsCheck: string;
      sourcesConsulted: string[];
      decisionExecuted: string;
      legalBasis: string;
      recommendations: string;
      traceability: string;
    };
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
    decisionRecord: {
      score: string;
      output: string;
      mainFacts: string;
      basis: string;
      nextReview: string;
    };
    poolReport: {
      period: string;
      swapsEvaluated: string;
      outputDistribution: string;
      reasonableSuspicionCases: string;
    };
    note: string;
  };
}

/** Display order: C baseline → A exploit → B (demo walkthrough order) */
export const CASE_ORDER: DemoCaseId[] = ["C", "A", "B"];

const CLEAN_AGENT_NOTE =
  "Internal operator documentation. The agent never files with any authority.";

const SHARED_POOL_REPORT = {
  period: "2026-07-01 → 2026-07-27",
  swapsEvaluated: "1,284 / 1,310 pool swaps (98%)",
  outputDistribution: "ALLOW 91% · FEE_OVERRIDE 7% · REVERT 2%",
  reasonableSuspicionCases: "Exploit source A monitored · N-hop decay active",
} as const;

/**
 * Baseline payloads. Live contamination is applied via withHopOverlay(simWallet).
 */
export const DEMO_CASES: Record<DemoCaseId, DemoCase> = {
  A: {
    id: "A",
    label: "Exploit cash-out — REVERT",
    shortLabel: "Wallet A · Exploit",
    wallet: "0x8576aCC5C05D6Ce88f4e49bf65BdF0C62F91353C",
    walletLabel: "Wallet A · Exploit source",
    score: 100,
    riskLabel: "Blocked",
    decision: "block",
    decisionLabel: "Block",
    baseFeeBps: 30,
    appliedFeeBps: 0,
    feeMultiplier: 0,
    exploitConfirmed: true,
    activity: {
      hopDistance: 0,
      origin: "A",
      windowLabel: "24h",
      totalUsd: 10_000_000,
      amountUsd: 1000,
      txCount: 0,
    },
    typology: "Exploit cash-out",
    summary: [
      "Keeper score 100 — exploit cluster confirmed.",
      "Pool swaps REVERT (fail-closed). P2P outflows to B start N-hop contamination.",
      "Origin score for decay: 100 × 0.65^hops.",
    ],
    signals: [
      { label: "Exploit / sanctions", value: "MATCH", tone: "bad" },
      { label: "Keeper score", value: "100 / 100", tone: "bad" },
      { label: "Hop distance", value: "0 (source)", tone: "bad" },
      { label: "Applied fee", value: "— (revert)", tone: "bad" },
    ],
    tags: [
      { label: "Exploit source", tone: "bad" },
      { label: "REVERT", tone: "bad" },
      { label: "Fail-closed", tone: "bad" },
    ],
    flowPath: "block",
    swapSell: "1,000",
    swapBuy: "0",
    sellToken: "USDC",
    buyToken: "ETH",
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
      auditHash: "0xae01…xplt",
      technicalOpinion: {
        issued: true,
        objectAndScope:
          "Wallet A holds exploit proceeds and is the contamination origin. Pool cash-out attempts REVERT; P2P to B propagates N-hop scores.",
        riskAndScoring: "Score 100 · REVERT band (71–100). Origin for downstream decay.",
        typologies: "Exploit cash-out. Confirmed exposure — no discretion to allow on-pool.",
        sanctionsCheck: "Exploit event / keeper detection drives fail-closed treatment.",
        sourcesConsulted: [
          "Keeper exploit-detection feed (confirmed cash-out cluster)",
          "Layer-1 on-chain sanctions screen (OFAC SDN / UN / EU mirrors)",
          "Off-chain score oracle — origin wallet score 100 / hop 0",
          "Outbound P2P graph (A → B contamination edges)",
          "beforeSwap WalletBlocked emit + pool REVERT policy band (71–100)",
        ],
        decisionExecuted: "REVERT in beforeSwap · WalletBlocked · no settlement.",
        legalBasis: "Fail-closed RWA pool policy on confirmed exploit exposure.",
        recommendations:
          "Human review. Watch A→B P2P for 1-hop fee override; then B→C for 2-hop.",
        traceability: "audit_hash 0xae01…xplt · retention 5 years.",
      },
      sarAnnex: {
        produced: true,
        status: "support-draft (not filed)",
        activityPeriod: "exploit window",
        amountInvolved: "USD 10,000,000 (tainted ledger)",
        operationState: "REVERTED",
        narrativeDescription:
          "Exploit source wallet blocked from pool swaps; may still move funds P2P to clean intermediaries.",
        narrativeAnalysis:
          "Direct exploit cash-out is dispositive for REVERT. Downstream wallets only become risky after receiving from A.",
        narrativeEvidence: "Keeper exploit detection · score 100 · beforeSwap revert.",
        narrativeConclusion:
          "Reasonable basis for immediate REVERT on A. Hop fees apply only after outbound transfers.",
        warnings: [
          "Confidentiality — no tip-off",
          "Document status: support draft — not submitted",
        ],
      },
      decisionRecord: {
        score: "100",
        output: "REVERT",
        mainFacts: "Exploit source A; pool blocked; origin for B/C contamination via P2P.",
        basis: "EXPLOIT_CASH_OUT_FAIL_CLOSED",
        nextReview: "Track outbound P2P hops to B and/or C",
      },
      poolReport: { ...SHARED_POOL_REPORT },
      note: "Internal evidence file. The agent never responds to authorities or files SARs.",
    },
  },
  B: {
    id: "B",
    label: "Clean wallet — same rules as C",
    shortLabel: "Wallet B · Clean",
    wallet: "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD",
    walletLabel: "Wallet B · Clean",
    score: 0,
    riskLabel: "Low Risk",
    decision: "allow",
    decisionLabel: "Allow",
    baseFeeBps: 30,
    appliedFeeBps: 30,
    feeMultiplier: 1,
    exploitConfirmed: false,
    activity: {
      hopDistance: null,
      origin: "—",
      windowLabel: "24h",
      totalUsd: 25_000,
      amountUsd: 1000,
      txCount: 0,
    },
    typology: "None",
    summary: [
      "Keeper score 0 — clean. Same baseline as C.",
      "After A → B: score ≈ 65 · 8%. After tainted C → B: score ≈ 42 · 3%.",
      "ALLOW · standard pool fee 0.30% until contaminated.",
    ],
    signals: [
      { label: "Exploit / sanctions", value: "Clear", tone: "ok" },
      { label: "Keeper score", value: "0 / 100", tone: "ok" },
      { label: "Hop distance", value: "—", tone: "ok" },
      { label: "Applied fee", value: "0.30%", tone: "ok" },
    ],
    tags: [
      { label: "Clean path", tone: "ok" },
      { label: "ALLOW", tone: "ok" },
    ],
    flowPath: "allow",
    swapSell: "1,000",
    swapBuy: "0.9970",
    sellToken: "USDC",
    buyToken: "ETH",
    gasUsed: 185_210,
    totalTimeSec: 1.76,
    stepTimesSec: {
      sign: 0.11,
      unlock: 0.17,
      before: 0.2,
      l1: 0.14,
      l2: 0.4,
      decide: 0.26,
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
      auditHash: "0xb0c1…000b",
      technicalOpinion: {
        issued: false,
        objectAndScope:
          "Clean Wallet B with no inbound contamination from exploit source A. Full dictamen not required.",
        riskAndScoring: "Score 0 / 100 · ALLOW band (0–30).",
        typologies: "None. No exploit link, no hop exposure.",
        sanctionsCheck: "Layer-1 screen clear.",
        sourcesConsulted: [
          "Layer-1 on-chain sanctions screen (OFAC SDN / UN / EU mirrors)",
          "Off-chain keeper score oracle (N-hop decay cache)",
          "P2P transfer graph for Wallet B (inbound from A or C)",
          "Pool SwapObserved / WalletBlocked event log",
          "RWA pool policy bands (ALLOW 0–30 · FEE_OVERRIDE 31–70 · REVERT 71–100)",
        ],
        decisionExecuted: "ALLOW · standard pool fee 0.30%.",
        legalBasis: "FATF risk-based approach · permissive RWA pool policy.",
        recommendations:
          "Monitor inbound from A (1-hop ≈ 65 / 8%) or tainted C (2-hop ≈ 42 / 3%). Closer hop wins if both occur.",
        traceability: "Retention 5 years.",
      },
      sarAnnex: null,
      decisionRecord: {
        score: "0",
        output: "ALLOW",
        mainFacts: "Wallet B clean; no hop from A; standard fee.",
        basis: "SCORE_BELOW_FEE_OVERRIDE_THRESHOLD",
        nextReview: "On inbound from A (1-hop) or tainted C (2-hop)",
      },
      poolReport: { ...SHARED_POOL_REPORT },
      note: CLEAN_AGENT_NOTE,
    },
  },
  C: {
    id: "C",
    label: "Clean wallet — same rules as B",
    shortLabel: "Wallet C · Clean",
    wallet: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    walletLabel: "Wallet C · Clean",
    score: 0,
    riskLabel: "Low Risk",
    decision: "allow",
    decisionLabel: "Allow",
    baseFeeBps: 30,
    appliedFeeBps: 30,
    feeMultiplier: 1,
    exploitConfirmed: false,
    activity: {
      hopDistance: null,
      origin: "—",
      windowLabel: "24h",
      totalUsd: 50_000,
      amountUsd: 1000,
      txCount: 0,
    },
    typology: "None",
    summary: [
      "Keeper score 0 — clean baseline (same rules as B).",
      "After A → C: score ≈ 65 · 8%. After tainted B → C: score ≈ 42 · 3%.",
      "ALLOW · standard pool fee 0.30%.",
    ],
    signals: [
      { label: "Exploit / sanctions", value: "Clear", tone: "ok" },
      { label: "Keeper score", value: "0 / 100", tone: "ok" },
      { label: "Hop distance", value: "—", tone: "ok" },
      { label: "Applied fee", value: "0.30%", tone: "ok" },
    ],
    tags: [
      { label: "Clean path", tone: "ok" },
      { label: "ALLOW", tone: "ok" },
    ],
    flowPath: "allow",
    swapSell: "1,000",
    swapBuy: "0.9970",
    sellToken: "USDC",
    buyToken: "ETH",
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
      auditHash: "0xc0c1…000c",
      technicalOpinion: {
        issued: false,
        objectAndScope:
          "Clean Wallet C with no inbound contamination. Full dictamen not required until A or a tainted peer transfers.",
        riskAndScoring: "Score 0 / 100 · ALLOW band (0–30).",
        typologies: "None. No exploit link, no hop exposure.",
        sanctionsCheck: "Layer-1 screen clear.",
        sourcesConsulted: [
          "Layer-1 on-chain sanctions screen (OFAC SDN / UN / EU mirrors)",
          "Off-chain keeper score oracle (N-hop decay cache)",
          "P2P transfer graph for Wallet C (inbound from A or B)",
          "Pool SwapObserved / WalletBlocked event log",
          "RWA pool policy bands (ALLOW 0–30 · FEE_OVERRIDE 31–70 · REVERT 71–100)",
        ],
        decisionExecuted: "ALLOW · standard pool fee 0.30%.",
        legalBasis: "FATF risk-based approach · permissive RWA pool policy.",
        recommendations:
          "Monitor inbound from A (1-hop ≈ 65 / 8%) or tainted B (2-hop ≈ 42 / 3%). Closer hop wins if both occur.",
        traceability: "Retention 5 years.",
      },
      sarAnnex: null,
      decisionRecord: {
        score: "0",
        output: "ALLOW",
        mainFacts: "Wallet C clean baseline; no hop from A; standard fee.",
        basis: "SCORE_BELOW_FEE_OVERRIDE_THRESHOLD",
        nextReview: "On inbound from A (1-hop) or tainted B (2-hop)",
      },
      poolReport: { ...SHARED_POOL_REPORT },
      note: CLEAN_AGENT_NOTE,
    },
  },
};
