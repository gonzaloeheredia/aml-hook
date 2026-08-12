import type { DemoCase } from "@/data/cases";
import {
  ethOutFromSwap,
  feeBpsFromHop,
  resolveDemoRisk,
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
 * Rebuilds the Opinion using the FinCEN SAR narrative model
 * (Who / What / When / Where / Why / How) from live MetaMask / N-hop state.
 * Skills are never listed in the opinion.
 */
function buildLiveTechnicalOpinion(
  wallet: SimWallet,
  score: number,
  decision: Decision,
  appliedFeeBps: number,
  auditHash: string,
): DemoCase["agent"]["technicalOpinion"] {
  const hop = wallet.hopDistance;
  const origin = wallet.originId ?? "A";
  const feePct = (appliedFeeBps / 100).toFixed(2);
  const hopLabel = hop == null ? "none" : String(hop);

  const who = [
    `Subject: ${wallet.accountLabel} (${wallet.address}).`,
    wallet.exploitConfirmed || decision === "block"
      ? "Role: confirmed exploit / contamination origin or REVERT-band wallet."
      : hop != null
        ? `Role: intermediary wallet with ${hop}-hop exposure from origin ${origin}.`
        : "Role: pool participant with no inbound contamination from exploit origin A.",
  ].join(" ");

  const what = [
    "Instrument / mechanism: Uniswap v4 RWA pool swap (USDC→ETH) and/or off-pool ERC-20 P2P USDC transfers.",
    wallet.exploitConfirmed || decision === "block"
      ? "Observed pattern: exploit cash-out / REVERT-band exposure — fail-closed on-pool."
      : decision === "fee_override" && wallet.keeperPending
        ? "Observed pattern: oracle-latency inflow heuristic (stale score 0 + significant recent funds)."
        : decision === "fee_override"
          ? `Observed pattern: N-hop propagation (${hop}-hop; decay 0.65^${hop}).`
          : hop == null
            ? "No structuring, mixer, or exploit-propagation pattern attributed on the evaluated facts."
            : "Prior N-hop link noted; current score below FEE_OVERRIDE threshold.",
    `Hook instruments: ${
      decision === "block"
        ? "WalletBlocked (no settlement)."
        : decision === "fee_override"
          ? `FEE_OVERRIDE: pool standard fee + FeeEscrow differential (~${feePct}% total friction).`
          : "standard pool fee 0.30%."
    }`,
  ].join(" ");

  const when =
    "Oracle / keeper evaluation at live MetaMask session. Individual dated transfers and SwapObserved / WalletBlocked emits are retained in the operator ledger; this narrative summarizes the period under review.";

  const where = [
    "Venue: AML Hook demo RWA pool (Uniswap v4) — simulated pool on Ethereum.",
    `Account / address under review: ${wallet.address}.`,
    hop != null
      ? `Fund movement path includes off-pool P2P hops (origin ${origin} → subject at hop ${hop}).`
      : "No inbound contamination path identified in the demo ledger.",
  ].join(" ");

  const why =
    decision === "block" || wallet.exploitConfirmed
      ? `Why elevated: score ${score}/100 · REVERT band (71–100). Hop ${hopLabel} · origin ${origin}. Direct exploit cash-out or block-band score is not commensurate with a clean retail profile.`
      : decision === "fee_override" && wallet.keeperPending
        ? `Why elevated: stale oracle score ${score}/100 with significant inflow while keeper updateScore is pending (§3.8 Mitigation D). Temporary FEE_OVERRIDE 8% — not guilt attribution.`
        : decision === "fee_override"
          ? `Why elevated: score ${score}/100 · FEE_OVERRIDE band (31–70). ${hop}-hop decay from origin ${origin} warrants proportional EDD friction.`
          : `Why not treated as suspicious for enhanced action: score ${score}/100 sits in the ALLOW band (0–30). Layer-1 sanctions screen clear (simulated).`;

  const how =
    decision === "block" || wallet.exploitConfirmed
      ? "How / control: beforeSwap fail-closed REVERT; afterSwap not reached; WalletBlocked recorded. Subject may still move USDC off-pool via P2P."
      : decision === "fee_override"
        ? `How / control: swap allowed with economic friction (pool standard fee + FeeEscrow differential ~${feePct}% total). afterSwap SwapObserved emitted.`
        : "How / control: swap allowed at standard fee; afterSwap SwapObserved emitted; score remains in ALLOW band.";

  return {
    issued: true,
    objectAndScope: who,
    typologies: what,
    sanctionsCheck: when,
    sourcesConsulted: [where],
    riskAndScoring: why,
    decisionExecuted: how,
    legalBasis:
      decision === "block" || wallet.exploitConfirmed
        ? "Fail-closed RWA pool policy on confirmed exploit exposure. Narrative organization follows FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How) as an internal model only."
        : decision === "fee_override"
          ? "FATF Rec. 1 & 10 (EBR / EDD). Narrative organization follows FinCEN SAR Narrative Guidance as an internal support-draft model — not a FinCEN filing."
          : "FATF Rec. 1 & 10. Verification narrative follows FinCEN SAR Narrative Guidance structure for consistency of operator records.",
    recommendations:
      decision === "block" || wallet.exploitConfirmed
        ? "Human review required. Watch outbound P2P for 1-hop fee overrides on recipients; then second-hop decay. Do not tip off the subject."
        : decision === "fee_override" && wallet.keeperPending
          ? "Await keeper catch-up — expect decay score ≈ 65 (1-hop from A). Friction is temporary."
          : decision === "fee_override"
            ? hop === 1
              ? "Treat as elevated EDD. If this wallet sends to the other clean peer (B↔C), expect 2-hop score ≈ 42 and 3% fee."
              : "Proportional friction applied. Continue monitoring further downstream hops; score decays toward ALLOW."
            : hop == null
              ? "Monitor for inbound P2P from Wallet A (or contaminated B/D). If received, expect N-hop decay fees."
              : "Keep ordinary monitoring. Re-open enhanced narrative if an inbound tainted transfer raises score into FEE_OVERRIDE or REVERT.",
    traceability: `auditHash ${auditHash} · retention 5 years (FATF Rec. 11 · BSA). Support draft — not submitted.`,
  };
}

/**
 * Live SAR annex only when FEE_OVERRIDE or REVERT warrants support drafting.
 * Blocks follow Who/What · When/Where · Why · How.
 */
function buildLiveSarAnnex(
  wallet: SimWallet,
  score: number,
  decision: Decision,
  base: DemoCase,
): DemoCase["agent"]["sarAnnex"] {
  if (decision === "allow") return null;

  const opinion = buildLiveTechnicalOpinion(
    wallet,
    score,
    decision,
    feeBpsFromHop(score, wallet.hopDistance),
    base.agent.auditHash,
  );
  const who = opinion.objectAndScope;
  const what = opinion.typologies;
  const when = opinion.sanctionsCheck;
  const where = opinion.sourcesConsulted.join(" ");
  const why = opinion.riskAndScoring;
  const how = opinion.decisionExecuted;

  if (decision === "block" || wallet.exploitConfirmed) {
    return {
      produced: true,
      status: "support-draft (not filed)",
      activityPeriod: "exploit window",
      amountInvolved: `USD ${wallet.usdc.toLocaleString("en-US")} (ledger)`,
      operationState: "REVERTED",
      narrativeDescription: `WHO: ${who} WHAT: ${what}`,
      narrativeAnalysis: `WHEN: ${when} WHERE: ${where}`,
      narrativeEvidence: `WHY: ${why}`,
      narrativeConclusion: `HOW: ${how} This annex is an internal SAR-support pack. It is not a FinCEN SAR and must not be filed by the agent.`,
      warnings: [
        "Confidentiality — no tip-off",
        "Document status: support draft — not submitted",
        "Organize facts chronologically when preparing any human-owned filing",
      ],
    };
  }

  return {
    produced: true,
    status: "support-draft (not filed)",
    activityPeriod: "post-contamination window",
    amountInvolved: `USD ${wallet.usdc.toLocaleString("en-US")} USDC on ledger`,
    operationState: "FEE_OVERRIDE",
    narrativeDescription: `WHO: ${who} WHAT: ${what}`,
    narrativeAnalysis: `WHEN: ${when} WHERE: ${where}`,
    narrativeEvidence: `WHY: ${why}`,
    narrativeConclusion: `HOW: ${how} Human decides whether BSA filing is required.`,
    warnings: [
      "Confidentiality — no tip-off",
      "Document status: support draft — not submitted",
      "Human judgment required before any BSA filing decision",
    ],
  };
}

/**
 * Overlays live MetaMask / N-hop simulation state onto a demo case
 * so Swap / Flow / Audit (including Opinion) track contamination changes.
 */
export function withHopOverlay(base: DemoCase, wallet: SimWallet): DemoCase {
  const resolved = resolveDemoRisk(wallet);
  const { score, decision, feeBps: appliedFeeBps, latencyMitigation, keeperPending } =
    resolved;
  const feeMultiplier =
    decision === "block" ? 0 : decision === "allow" ? 1 : appliedFeeBps / base.baseFeeBps;

  const usdcIn = swapUsdcAmount(wallet, base.activity.amountUsd);
  const ethOut =
    decision === "block" ? 0 : ethOutFromSwap(usdcIn, appliedFeeBps);

  const riskLabel =
    decision === "block"
      ? "Blocked"
      : latencyMitigation === "INFLOW_HEURISTIC"
        ? "Inflow · Latency floor"
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
    latencyMitigation === "INFLOW_HEURISTIC"
      ? "Inflow heuristic"
      : wallet.hopDistance == null
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
      : latencyMitigation === "INFLOW_HEURISTIC"
        ? "Technical opinion · FEE_OVERRIDE (inflow)"
        : decision === "fee_override"
          ? `Technical opinion · ${wallet.hopDistance}-hop FEE_OVERRIDE`
          : "Legal opinion · ALLOW";

  const documentType =
    decision === "allow" ? "legal-opinion" : "opinion + sar-annex";

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
      : latencyMitigation === "INFLOW_HEURISTIC"
        ? "Oracle latency · inflow"
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
        ? "Keeper confirmed exploit source — REVERT on pool swaps. P2P outflows contaminate B/C/D."
        : keeperPending
          ? "Wallet D latency window: inbound P2P recorded; keeper has not published decay score yet."
          : wallet.hopDistance
            ? `Contamination at ${wallet.hopDistance} hop(s) from origin ${wallet.originId ?? "A"} · score ${score}.`
            : "Clean wallet. No contamination from A yet — ALLOW at standard fee.",
      latencyMitigation === "INFLOW_HEURISTIC"
        ? `§3.8 inflow heuristic → FEE_OVERRIDE ${(appliedFeeBps / 100).toFixed(2)}% total friction (FeeEscrow differential) under stale score ${score}.`
        : decision === "fee_override"
          ? `FEE_OVERRIDE ${(appliedFeeBps / 100).toFixed(2)}% total friction — pool standard fee + FeeEscrow differential.`
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
        value: `${score} / 100${keeperPending ? " (stale)" : ""}`,
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
        mainFacts: `WHO ${wallet.accountLabel}; hop=${wallet.hopDistance ?? "none"}; origin=${wallet.originId ?? "—"}; USDC=${wallet.usdc.toLocaleString("en-US")}; ETH=${wallet.eth}; keeperPending=${keeperPending}.`,
        basis:
          decision === "block"
            ? "EXPLOIT_CASH_OUT_FAIL_CLOSED"
            : latencyMitigation === "INFLOW_HEURISTIC"
              ? "ORACLE_LATENCY_INFLOW_HEURISTIC"
              : decision === "fee_override"
                ? "N_HOP_DECAY_FEE_OVERRIDE"
                : "SCORE_BELOW_FEE_OVERRIDE_THRESHOLD",
        nextReview:
          decision === "block"
            ? "Immediate human review · watch outbound P2P"
            : keeperPending
              ? "Keeper catch-up → expect decay score ~65"
              : decision === "fee_override"
                ? "On further hop transfer or score band change"
                : "On inbound transfer from A or other tainted wallet",
      },
      note: "Internal operator documentation modeled on FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How). Never filed with any authority.",
    },
  };
}
