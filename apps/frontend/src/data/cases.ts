/**
 * Hardcoded demo scenarios for the AML Hook frontend.
 *
 * Use case (`docs/Use_Case.md`):
 * - A = confirmed exploit, score 100 → WalletBlocked (still contaminates B/C/D via P2P)
 * - B and C both start clean (ALLOW)
 * - A→B or A→C → 1-hop · ~65 · 8%; tainted peer → 2-hop · ~42 · 3%
 * - D = published score 0. Held funds ALLOW. Floor B (Advance 5 min).
 *   Clean C→D inflow 3% ($10k) / 8% ($15k). Floor C on a 24h $15k sum.
 * - E = unknown, starts empty. Clean C funds E (no hop). Then Floor A/D by bag.
 * Live decisions come from AmlHook.previewSwap via the API.
 * Fee / USD figures below are deploy defaults (3% / 8% / $1k / $15k).
 * The UI rewrites them from officer knobs (`GET /policy`).
 */

export type Decision = "allow" | "fee_override" | "block";

export type DemoCaseId = "A" | "B" | "C" | "D" | "E";

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
  /** Optional size chips (Wallet E USD bands). */
  amountPresets?: number[];
  latencyMitigation?:
    | "INFLOW_HEURISTIC"
    | "INFLOW_MAGNITUDE"
    | "SCORE_NEVER_WRITTEN"
    | "STALE_WITH_POOL_ACTIVITY"
    | "ACTIVITY_WINDOW_CAP"
    | "DAILY_AGGREGATION"
    | "MAGNITUDE_QUOTE_FAILED"
    | null;
  revertReason?:
    | "WalletBlocked"
    | "UnscoredMagnitudeBlocked"
    | "InflowMagnitudeBlocked"
    | "MagnitudeQuoteFailed"
    | "DailyAggregationBlocked"
    | "StalePoolImpactBlocked"
    | "UnscoredPoolImpactBlocked"
    | "SanctionHit"
    | null;
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
      normativeCitations?: {
        id: string;
        title: string;
        framework: "FATF" | "OFAC" | "MICA" | "TFR" | "FINCEN" | "TREASURY" | "WOLFSBERG";
        series: string;
        publicationDate: string;
        retrievedAt: string;
        sha256: string;
      }[];
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

/** Display order: A → E */
export const CASE_ORDER: DemoCaseId[] = ["A", "B", "C", "D", "E"];
/** Connect picker: A–E walkthrough. */
export const CONNECT_ORDER: DemoCaseId[] = ["A", "B", "C", "D", "E"];

const CLEAN_AGENT_NOTE =
  "Internal operator documentation. The agent never files with any authority.";

const SHARED_POOL_REPORT = {
  period: "2026-07-01 → 2026-07-27",
  swapsEvaluated: "1,284 / 1,310 pool swaps (98%)",
  outputDistribution: "ALLOW 91% · FEE_OVERRIDE 7% · REVERT 2%",
  reasonableSuspicionCases: "Exploit source A monitored · N-hop decay active",
} as const;

/**
 * Baseline payloads. Live score / fee / opinion come from GET /compliance
 * (hook previewSwap). hopScoring is MetaMask P2P preview only.
 */
export const DEMO_CASES: Record<DemoCaseId, DemoCase> = {
  A: {
    id: "A",
    label: "Exploit — WalletBlocked",
    shortLabel: "Wallet A · Exploit",
    wallet: "0x8576aCC5C05D6Ce88f4e49bf65BdF0C62F91353C",
    walletLabel: "Wallet A · Exploit",
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
      "Not on OFAC. The officer wrote score 100 from a confirmed exploit (external analysis).",
      "Pool swaps revert WalletBlocked (SCORE_REVERT_BAND). P2P outflows to B/C/D still start N-hop contamination.",
      "Do not fund E from A. Origin score for decay: 100 × 0.65^hops.",
    ],
    signals: [
      { label: "Exploit / sanctions", value: "Exploit cluster", tone: "bad" },
      { label: "Keeper score", value: "100 / 100", tone: "bad" },
      { label: "Hop distance", value: "0 (source)", tone: "bad" },
      { label: "Applied fee", value: "— (revert)", tone: "bad" },
    ],
    tags: [
      { label: "Exploit origin", tone: "bad" },
      { label: "REVERT", tone: "bad" },
      { label: "Fail-closed", tone: "bad" },
    ],
    flowPath: "block",
    revertReason: "WalletBlocked",
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
          "Subject: Wallet A (confirmed exploit origin). Role: score-100 REVERT-band wallet and contamination source. Known relationship: outbound P2P can contaminate B/C. Do not fund E from A.",
        typologies:
          "Instrument: Uniswap v4 RWA pool swap (USDC→ETH) and/or off-pool P2P USDC. Pattern: confirmed exploit cash-out. Hook: WalletBlocked (SCORE_REVERT_BAND).",
        sanctionsCheck:
          "Clear on the demo SanctionRegistry. The officer wrote score 100 from external exploit analysis; L2 is what blocks.",
        sourcesConsulted: [
          "Venue: AML Hook demo RWA pool (Uniswap v4). Account under review: Wallet A. Fund path: origin hop 0; outbound P2P edges A→B / A→C.",
        ],
        riskAndScoring:
          "Why elevated: keeper score 100/100 (REVERT band 71–100). Confirmed exploit cash-out is not commensurate with a clean retail profile. L1 list is clear.",
        decisionExecuted:
          "How / control: beforeSwap WalletBlocked (SCORE_REVERT_BAND); L1 clear; afterSwap not reached. Subject may still move USDC off-pool via P2P.",
        legalBasis:
          "Fail-closed RWA pool policy on confirmed exploit / REVERT-band score. Narrative organization follows FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How) as an internal model only.",
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
          "WHO: Wallet A — confirmed exploit origin, not OFAC-listed. WHAT: pool cash-out attempt blocked at score band; P2P may still move tainted USDC.",
        narrativeAnalysis:
          "WHEN: exploit window. WHERE: demo RWA pool + off-pool P2P graph from A.",
        narrativeEvidence:
          "WHY: keeper score 100 from officer / external analysis (SCORE_REVERT_BAND); SanctionRegistry is clear.",
        narrativeConclusion:
          "HOW: beforeSwap WalletBlocked. Internal SAR-support pack only — not a FinCEN filing.",
        warnings: [
          "Confidentiality — no tip-off",
          "Document status: support draft — not submitted",
          "Organize facts chronologically when preparing any human-owned filing",
        ],
      },
      decisionRecord: {
        score: "100",
        output: "REVERT",
        mainFacts: "Wallet A confirmed exploit; score 100; pool WalletBlocked; origin for B/C contamination via P2P. Do not fund E from A.",
        basis: "EXPLOIT_PROTOCOL_FUNDS",
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
          "Fund E (unknown, no hop) or D (inflow). Monitor inbound from A (1-hop ≈ 65 / 8%) or tainted B (2-hop ≈ 42 / 3%).",
        traceability: "Retention 5 years. Support draft — not submitted.",
      },
      sarAnnex: null,
      decisionRecord: {
        score: "0",
        output: "ALLOW",
        mainFacts: "Wallet C clean baseline; no hop from A; standard fee.",
        basis: "SCORE_BELOW_FEE_OVERRIDE_THRESHOLD",
        nextReview: "Fund E (unknown) or D (inflow). Watch inbound from A (1-hop) or tainted B (2-hop)",
      },
      poolReport: { ...SHARED_POOL_REPORT },
      note: CLEAN_AGENT_NOTE,
    },
  },
  D: {
    id: "D",
    label: "Published score 0 — ALLOW",
    shortLabel: "Wallet D · Score 0",
    wallet: "0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97",
    walletLabel: "Wallet D · Score 0",
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
      totalUsd: 5_000,
      amountUsd: 1000,
      txCount: 0,
    },
    typology: "None",
    summary: [
      "Published score 0 — confirmed clean. Already-held USDC swaps at 0.30%.",
      "Floor B: swap $1,000 then Advance 5 min (no keeper write) → 3%. Floor C: two swaps that add to $15,000 → REVERT.",
      "Clean C→D is inflow, not a hop: +$10,000 → 3%; +$15,000 → 8%. A→D is a hop — do not use it for Floor D.",
    ],
    signals: [
      { label: "Exploit / sanctions", value: "Clear", tone: "ok" },
      { label: "Keeper score", value: "0 / 100", tone: "ok" },
      { label: "Hop distance", value: "—", tone: "ok" },
      { label: "Applied fee", value: "0.30%", tone: "ok" },
    ],
    tags: [
      { label: "Score 0", tone: "ok" },
      { label: "ALLOW", tone: "ok" },
    ],
    flowPath: "allow",
    swapSell: "1,000",
    swapBuy: "0.9970",
    sellToken: "USDC",
    buyToken: "ETH",
    gasUsed: 191_200,
    totalTimeSec: 1.9,
    stepTimesSec: {
      sign: 0.12,
      unlock: 0.18,
      before: 0.22,
      l1: 0.15,
      l2: 0.44,
      decide: 0.3,
      out: 0.49,
    },
    agent: {
      status: "Legal opinion · ALLOW",
      hookOutput: "ALLOW",
      documentType: "legal-opinion",
      recipient: "Pool operator Compliance Officer",
      confidence: "HIGH",
      humanReview: false,
      retentionYears: 5,
      auditHash: "0xd0c1…000d",
      technicalOpinion: {
        issued: true,
        objectAndScope:
          "Subject: Wallet D. Role: published score 0 (confirmed clean). Optional second act: clean C→D (inflow, no hop).",
        typologies:
          "Instrument: Uniswap v4 RWA pool swap (USDC→ETH). Baseline is a published clean row. A later inbound from clean C exercises the inflow floor without a hop.",
        sanctionsCheck:
          "Oracle evaluation at live session. Ledger retains dated transfers; this narrative summarizes the period under review.",
        sourcesConsulted: [
          "Venue: AML Hook demo RWA pool (Uniswap v4). Account under review: Wallet D. Published score 0.",
        ],
        riskAndScoring:
          "Score 0/100 in the ALLOW band. Already-held funds swap at 0.30%. After clean C→D, inflow elevates to FEE_OVERRIDE 3% or 8% by inbound USD, with no hop.",
        decisionExecuted:
          "Baseline ALLOW. After clean C→D, beforeSwap floors to FEE_OVERRIDE 3% ($10k inbound) or 8% ($15k). D stays score 0 — no hop.",
        legalBasis:
          "FATF Rec. 1 & 10. Temporary friction pending keeper confirmation. Floor B/D never revert.",
        recommendations:
          "Swap D first (ALLOW). Advance 5 min after that swap to see Floor B 3%. Restart, then C→D $10k (3%) or $15k (8%).",
        traceability: "Retention 5 years. Support draft — not submitted.",
      },
      sarAnnex: null,
      decisionRecord: {
        score: "0",
        output: "ALLOW",
        mainFacts: "Wallet D published score 0; already-held funds; standard fee.",
        basis: "SCORE_BELOW_FEE_OVERRIDE_THRESHOLD",
        nextReview: "On Floor B (Advance 5 min), clean C→D, or a 24h $15k sum",
      },
      poolReport: { ...SHARED_POOL_REPORT },
      note: CLEAN_AGENT_NOTE,
    },
  },
  E: {
    id: "E",
    label: "Unknown wallet — fee or revert by size",
    shortLabel: "Wallet E · Unknown",
    wallet: "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
    walletLabel: "Wallet E · Unknown",
    score: 0,
    riskLabel: "Unknown",
    decision: "fee_override",
    decisionLabel: "Fee override",
    baseFeeBps: 30,
    appliedFeeBps: 300,
    feeMultiplier: 300 / 30,
    exploitConfirmed: false,
    activity: {
      hopDistance: null,
      origin: "—",
      windowLabel: "first swap",
      totalUsd: 0,
      amountUsd: 0,
      txCount: 0,
    },
    typology: "Unknown wallet",
    summary: [
      "No oracle row. Starts empty — fund from clean C in MetaMask (no hop). Do not use A.",
      "After C→E $500 → next $500 swap is 3%. C→E $10k then $1k swap → 8% (A mid). C→E $15k + small swap → 8% (D). This swap $15k → REVERT.",
      "$10k then $5k in 24h is Floor C. Unbind the feed with POST /demo/price-feed after a quote → last FX (silent under 30 min; same bands).",
    ],
    signals: [
      { label: "Exploit / sanctions", value: "Clear", tone: "ok" },
      { label: "Keeper score", value: "— never written", tone: "warn" },
      { label: "Hop distance", value: "—", tone: "ok" },
      { label: "Applied fee", value: "— (empty)", tone: "warn" },
    ],
    tags: [
      { label: "Unknown", tone: "warn" },
      { label: "FEE_OVERRIDE", tone: "warn" },
    ],
    flowPath: "fee_override",
    amountPresets: [500, 1000, 10_000, 15_000],
    swapSell: "0",
    swapBuy: "0",
    sellToken: "USDC",
    buyToken: "ETH",
    gasUsed: 188_000,
    totalTimeSec: 1.82,
    stepTimesSec: {
      sign: 0.12,
      unlock: 0.18,
      before: 0.21,
      l1: 0.15,
      l2: 0.42,
      decide: 0.28,
      out: 0.46,
    },
    agent: {
      status: "Technical opinion · FEE_OVERRIDE (unknown)",
      hookOutput: "FEE_OVERRIDE",
      documentType: "opinion + sar-annex",
      recipient: "Pool operator Compliance Officer",
      confidence: "MEDIUM",
      humanReview: true,
      retentionYears: 5,
      auditHash: "0xe0c1…000e",
      technicalOpinion: {
        issued: true,
        objectAndScope:
          "Subject: Wallet E. Role: unknown pool participant. The oracle has never written a row for this address.",
        typologies:
          "Instrument: Uniswap v4 RWA pool swap (USDC→ETH). First flow from an unpublished address. Floor A is this swap; Floor D is the current bag. The stricter fee wins.",
        sanctionsCheck:
          "Layer-1 screen clear (simulated). No keeper score exists to read.",
        sourcesConsulted: [
          "Venue: AML Hook demo RWA pool (Uniswap v4). Account under review: Wallet E. Never-written oracle row. Funded only from clean C.",
        ],
        riskAndScoring:
          "Unknown wallet. Starts empty. After clean C funds E, Floor A is this swap and Floor D is the unpublished bag. The stricter fee wins. Floor A reverts this swap at $15,000.",
        decisionExecuted:
          "beforeSwap applies Floor A (this swap) and Floor D (bag). afterSwap emits SwapObserved on the fee path; a $15,000 attempt reverts.",
        legalBasis:
          "FATF 2021 VASP guidance note 37 (USD/EUR 1,000 VA) and Rec. 10 occasional CDD (USD/EUR 15,000). Floor C 24h aggregation is a BSA CTR design choice. See whitepaper §8.4.",
        recommendations:
          "Fund E from C first. Then use the size chips: bag $500 → 3%; $10k bag + $1k swap → 8% (A mid); $15k bag + small swap → 8% (D); this swap $15k → revert.",
        traceability: "Retention 5 years. Support draft — not submitted.",
      },
      sarAnnex: {
        produced: true,
        status: "support-draft (not filed)",
        activityPeriod: "first-swap window",
        amountInvolved: "USD size chosen on the swap card",
        operationState: "FEE_OVERRIDE or REVERT",
        narrativeDescription:
          "WHO: Wallet E — unknown address. WHAT: first pool swap with no keeper score.",
        narrativeAnalysis:
          "WHEN: live demo session. WHERE: demo RWA pool.",
        narrativeEvidence:
          "WHY: never-written oracle row. Floor A is this swap; Floor D is the bag.",
        narrativeConclusion:
          "HOW: unknown-wallet USD bands. Internal pack only — not a filing.",
        warnings: [
          "Confidentiality — no tip-off",
          "Document status: support draft — not submitted",
        ],
      },
      decisionRecord: {
        score: "—",
        output: "FEE_OVERRIDE",
        mainFacts: "Wallet E unknown; starts empty; fund from C. Next swap follows Floor A/D on the new bag.",
        basis: "UNKNOWN_WALLET_USD_BANDS",
        nextReview: "On keeper publish, or on a $15,000 attempt",
      },
      poolReport: { ...SHARED_POOL_REPORT },
      note: CLEAN_AGENT_NOTE,
    },
  },
};
