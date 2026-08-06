/**
 * Hardcoded demo scenarios for the AML Hook frontend.
 *
 * Use case (`docs/Use_Case.md`):
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
    run?: {
      runId: string;
      role: string;
      flow: string;
      durationMs: number;
      skillsExecuted: string[];
      sourcesConsulted: string[];
      publishTxHash?: string;
      publishStatus?: string;
    };
  };
}

/** Display order: alphabetical A → B → C */
export const CASE_ORDER: DemoCaseId[] = ["A", "B", "C"];

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
          "Subject: Wallet A (exploit origin). Role: confirmed exploit / contamination source in the demo ledger. Known relationship: outbound P2P can contaminate B/C.",
        typologies:
          "Instrument: Uniswap v4 RWA pool swap (USDC→ETH) and/or off-pool P2P USDC. Pattern: exploit cash-out. Hook: WalletBlocked (no settlement).",
        sanctionsCheck:
          "Oracle evaluation at exploit window. Individual dated transfers retained in the operator ledger; this narrative summarizes the period under review.",
        sourcesConsulted: [
          "Venue: AML Hook demo RWA pool (Uniswap v4). Account under review: Wallet A. Fund path: origin hop 0; outbound P2P edges A→B / A→C.",
        ],
        riskAndScoring:
          "Why elevated: score 100/100 · REVERT band (71–100). Direct exploit cash-out is not commensurate with a clean retail profile.",
        decisionExecuted:
          "How / control: beforeSwap fail-closed REVERT; afterSwap not reached; WalletBlocked recorded. Subject may still move USDC off-pool via P2P.",
        legalBasis:
          "Fail-closed RWA pool policy on confirmed exploit exposure. Narrative organization follows FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How) as an internal model only.",
        recommendations:
          "Human review. Watch A→B P2P for 1-hop fee override; then B→C for 2-hop. Do not tip off the subject.",
        traceability: "auditHash 0xae01…xplt · retention 5 years. Support draft — not submitted.",
      },
      sarAnnex: {
        produced: true,
        status: "support-draft (not filed)",
        activityPeriod: "exploit window",
        amountInvolved: "USD 10,000,000 (tainted ledger)",
        operationState: "REVERTED",
        narrativeDescription:
          "WHO: Wallet A — exploit origin. WHAT: pool cash-out attempt blocked; P2P may still move tainted USDC.",
        narrativeAnalysis:
          "WHEN: exploit window. WHERE: demo RWA pool + off-pool P2P graph from A.",
        narrativeEvidence:
          "WHY: score 100 · REVERT band; keeper exploit detection is dispositive.",
        narrativeConclusion:
          "HOW: beforeSwap REVERT · WalletBlocked. Internal SAR-support pack only — not a FinCEN filing.",
        warnings: [
          "Confidentiality — no tip-off",
          "Document status: support draft — not submitted",
          "Organize facts chronologically when preparing any human-owned filing",
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
      status: "Legal opinion · ALLOW",
      hookOutput: "ALLOW",
      documentType: "legal-opinion",
      recipient: "Pool operator Compliance Officer",
      confidence: "HIGH",
      humanReview: false,
      retentionYears: 5,
      auditHash: "0xb0c1…000b",
      technicalOpinion: {
        issued: true,
        objectAndScope:
          "Subject: Wallet B. Role: pool participant with no inbound contamination from exploit origin A.",
        typologies:
          "Instrument: Uniswap v4 RWA pool swap (USDC→ETH). No structuring, mixer, or exploit-propagation pattern attributed. Hook: standard pool fee 0.30%.",
        sanctionsCheck:
          "Oracle evaluation at live session. Ledger retains dated transfers; this narrative summarizes the period under review.",
        sourcesConsulted: [
          "Venue: AML Hook demo RWA pool (Uniswap v4). Account under review: Wallet B. No inbound contamination path identified.",
        ],
        riskAndScoring:
          "Why not treated as suspicious for enhanced action: score 0/100 · ALLOW band (0–30). Layer-1 sanctions screen clear (simulated).",
        decisionExecuted:
          "How / control: swap allowed at standard fee; afterSwap SwapObserved emitted; score remains in ALLOW band.",
        legalBasis:
          "FATF Rec. 1 & 10. Verification narrative follows FinCEN SAR Narrative Guidance structure for consistency of operator records.",
        recommendations:
          "Monitor inbound from A (1-hop ≈ 65 / 8%) or tainted C (2-hop ≈ 42 / 3%). Closer hop wins if both occur.",
        traceability: "Retention 5 years. Support draft — not submitted.",
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
      status: "Legal opinion · ALLOW",
      hookOutput: "ALLOW",
      documentType: "legal-opinion",
      recipient: "Pool operator Compliance Officer",
      confidence: "HIGH",
      humanReview: false,
      retentionYears: 5,
      auditHash: "0xc0c1…000c",
      technicalOpinion: {
        issued: true,
        objectAndScope:
          "Subject: Wallet C. Role: pool participant with no inbound contamination from exploit origin A.",
        typologies:
          "Instrument: Uniswap v4 RWA pool swap (USDC→ETH). No structuring, mixer, or exploit-propagation pattern attributed. Hook: standard pool fee 0.30%.",
        sanctionsCheck:
          "Oracle evaluation at live session. Ledger retains dated transfers; this narrative summarizes the period under review.",
        sourcesConsulted: [
          "Venue: AML Hook demo RWA pool (Uniswap v4). Account under review: Wallet C. No inbound contamination path identified.",
        ],
        riskAndScoring:
          "Why not treated as suspicious for enhanced action: score 0/100 · ALLOW band (0–30). Layer-1 sanctions screen clear (simulated).",
        decisionExecuted:
          "How / control: swap allowed at standard fee; afterSwap SwapObserved emitted; score remains in ALLOW band.",
        legalBasis:
          "FATF Rec. 1 & 10. Verification narrative follows FinCEN SAR Narrative Guidance structure for consistency of operator records.",
        recommendations:
          "Monitor inbound from A (1-hop ≈ 65 / 8%) or tainted B (2-hop ≈ 42 / 3%). Closer hop wins if both occur.",
        traceability: "Retention 5 years. Support draft — not submitted.",
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
