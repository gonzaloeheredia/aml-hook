/**
 * Maps ScoreResult → Legal / technical Opinion.
 *
 * Narrative model (FinCEN SAR Narrative Guidance, Nov 2003 — structure only):
 * Who / What / When / Where / Why / How — chronological, concise, support-draft only.
 * Skills used by the oracle are NOT listed in the Opinion.
 */

import type { Wallet } from "../types.js";
import type { AgentRun, OracleOpinion, ScoreResult } from "./types.js";

/**
 * Builds the Opinion-module payload from an oracle ScoreResult.
 */
export function buildOpinionFromScore(
  wallet: Wallet,
  score: ScoreResult,
  agentRun?: AgentRun,
): OracleOpinion {
  const decision =
    score.hookOutput === "REVERT"
      ? "block"
      : score.hookOutput === "FEE_OVERRIDE"
        ? "fee_override"
        : "allow";
  const feeBps = score.recommendedFeeBps;
  const feePct = (feeBps / 100).toFixed(2);
  const topFacts = [...score.triggeringFacts]
    .filter((f) => f.dimension !== "MT")
    .sort((a, b) => Math.abs(b.scoreContribution) - Math.abs(a.scoreContribution))
    .slice(0, 5);

  const humanReview =
    decision !== "allow" ||
    score.regulatoryFlags.some(
      (f) =>
        f.type.includes("HUMAN_REVIEW") ||
        f.type.includes("REASONABLE_SUSPICION"),
    );

  const origin = wallet.originId ?? "—";
  const hop =
    wallet.hopDistance == null ? "none" : String(wallet.hopDistance);

  const who = [
    `Subject: ${wallet.accountLabel} (${wallet.address}).`,
    wallet.exploitConfirmed
      ? "Role: confirmed exploit origin (score 100). Not on SanctionRegistry. Contamination source. Do not fund E from A."
      : hop !== "none"
        ? `Role: intermediary wallet with ${hop}-hop exposure from origin ${origin}.`
        : "Role: pool participant with no inbound contamination from exploit origin A.",
    origin !== "—" && hop !== "none"
      ? `Known relationship: contamination path linked to origin wallet ${origin}.`
      : "No additional related suspects identified beyond the ledger graph.",
  ].join(" ");

  const what = [
    "Instrument / mechanism: Uniswap v4 RWA pool swap (USDC→ETH) and/or off-pool ERC-20 P2P USDC transfers.",
    decision === "allow"
      ? "No structuring, mixer, or exploit-propagation pattern attributed to this wallet on the evaluated facts."
      : topFacts.length
        ? `Observed patterns: ${topFacts.map((f) => f.type.replaceAll("_", " ")).join("; ")}.`
        : "Elevated behavioral / hop-derived risk without a single dominant typology label.",
    `Hook instruments involved: score oracle read at beforeSwap; ${
      decision === "block"
        ? wallet.exploitConfirmed
          ? "WalletBlocked (score 100 · SCORE_REVERT_BAND; not a list hit)."
          : "WalletBlocked (no settlement)."
        : decision === "fee_override"
          ? `FEE_OVERRIDE: pool standard fee retained; risk differential (~${feePct}% total intended friction) taken in afterSwap into FeeEscrow (48h COA path).`
          : "standard pool fee 0.30%."
    }`,
  ].join(" ");

  const when = [
    `Oracle evaluation time: ${score.validity.calculatedAt}.`,
    `Trigger: ${score.validity.trigger} (seed | transfer | afterSwap | blocked).`,
    `Recommended next review: ${score.validity.nextReview}.`,
    "Individual dated transfers and SwapObserved / WalletBlocked emits are retained in the operator ledger; this narrative summarizes the period under review without embedding tables.",
  ].join(" ");

  const connectedSources = agentRun?.sourcesConsulted?.length
    ? agentRun.sourcesConsulted
    : [
        "OFAC SDN API",
        "UN Consolidated Sanctions List",
        "Etherscan account API",
        "Uniswap v4 PoolManager logs",
        "Internal ledger graph",
        "FATF VA red-flag catalog",
      ];

  const where = [
    "Venue: Uniswap v4 RWA pool (Ethereum) under AML Hook control.",
    `Account / address under review: ${wallet.address}.`,
    hop !== "none"
      ? `Fund movement path includes off-pool P2P hops (origin ${origin} → subject at hop ${hop}).`
      : "No foreign VASP corridor or multi-office branching identified on the evidence trail.",
    "Jurisdiction framing for the operator pack: U.S. BSA / FinCEN SAR narrative practice (support draft only) and FATF VA red-flag vocabulary — not a filing.",
  ].join(" ");

  const why =
    decision === "allow"
      ? [
          `Why not treated as suspicious for enhanced action: oracle score ${score.finalScore}/100 (${score.riskLevel}) sits in the ALLOW band (0–30).`,
          "Activity is consistent with a clean participant profile for this demo pool; Layer-1 sanctions screen clear (simulated).",
          "This documentation records the verification that no SAR-support annex was opened.",
        ].join(" ")
      : [
          `Why the activity is unusual / elevated: oracle score ${score.finalScore}/100 (${score.riskLevel}) → hook ${score.hookOutput}.`,
          topFacts.length
            ? `Primary facts: ${topFacts
                .map(
                  (f) =>
                    `${f.type.replaceAll("_", " ")} (${f.confidence}): ${f.justification}`,
                )
                .join(" ")}`
            : "Elevated score without additional typology detail.",
          score.regulatoryFlags.length
            ? `Flags: ${score.regulatoryFlags.map((f) => f.type).join(", ")}.`
            : "",
          "Compared with expected clean-pool behavior, hop-linked or exploit-linked activity is not commensurate with a low-risk retail profile.",
        ]
          .filter(Boolean)
          .join(" ");

  const how = [
    decision === "block"
      ? wallet.exploitConfirmed
        ? "Method of operation / control response: beforeSwap WalletBlocked (SCORE_REVERT_BAND); L1 sanctions screen clear; afterSwap not reached. Subject may still move USDC off-pool via P2P, which updates downstream oracle scores."
        : "Method of operation / control response: beforeSwap fail-closed REVERT; afterSwap not reached; WalletBlocked recorded. Subject may still move USDC off-pool via P2P, which updates downstream oracle scores."
      : decision === "fee_override"
        ? `Method of operation / control response: swap allowed with economic friction (recommendedFeeBps ${feeBps}; pool standard fee + FeeEscrow differential). afterSwap SwapObserved emitted; oracle reevaluated for the next beforeSwap.`
        : "Method of operation / control response: swap allowed at standard fee; afterSwap SwapObserved emitted; oracle score remains in ALLOW band for subsequent swaps.",
    `Modus summary: ${
      wallet.exploitConfirmed
        ? "Confirmed exploit cash-out; keeper wrote score 100; pool path is WalletBlocked."
        : hop !== "none"
          ? `${hop}-hop propagation of contaminated funds into a pool swap attempt.`
          : "ordinary USDC→ETH swap without contamination indicators."
    }`,
  ].join(" ");

  const technicalOpinion = {
    issued: true,
    objectAndScope: who,
    riskAndScoring: why,
    typologies: what,
    sanctionsCheck: when,
    // Field reused as Where (venue / addresses / path). Evidence only — no skill filenames.
    sourcesConsulted: [
      where,
      ...connectedSources,
      ...(agentRun
        ? [
            `COA run ${agentRun.runId} · ${agentRun.skills.length} skills · ${agentRun.durationMs}ms`,
          ]
        : []),
    ],
    decisionExecuted: how,
    legalBasis:
      decision === "block"
        ? wallet.exploitConfirmed
          ? "Fail-closed RWA pool policy on confirmed exploit / REVERT-band score (71–100). Narrative organization follows FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How) as an internal model only."
          : "FATF Rec. 6 / fail-closed RWA pool policy on confirmed exploit exposure. Narrative organization follows FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How) as an internal model only."
        : decision === "fee_override"
          ? "FATF Rec. 1 & 10 (EBR / EDD). Narrative organization follows FinCEN SAR Narrative Guidance as an internal support-draft model — not a FinCEN filing."
          : "FATF Rec. 1 & 10. Verification narrative follows FinCEN SAR Narrative Guidance structure for consistency of operator records.",
    recommendations: humanReview
      ? `For the pool Compliance Officer only: ${score.regulatoryFlags.map((f) => f.recommendation).join(" ") || "Human review of elevated path."} Next review ${score.validity.nextReview}. Do not tip off the subject. Agent never files with FinCEN or any authority.`
      : `Continue ordinary monitoring. Next review ${score.validity.nextReview}. Re-open enhanced narrative if inbound tainted P2P or anomalous afterSwap series appears.`,
    traceability: `auditHash ${score.auditHash} · calculated ${score.validity.calculatedAt} · retention 5 years (FATF Rec. 11 · BSA). Support draft — not submitted.`,
  };

  const sarAnnex =
    decision === "allow"
      ? null
      : {
          produced: true,
          status: "support-draft (not filed)",
          activityPeriod: score.validity.calculatedAt,
          amountInvolved: `USD ${wallet.usdc.toLocaleString("en-US")} USDC on ledger`,
          operationState: score.hookOutput,
          narrativeDescription: `WHO: ${who} WHAT: ${what}`,
          narrativeAnalysis: `WHEN: ${when} WHERE: ${where}`,
          narrativeEvidence: `WHY: ${why}`,
          narrativeConclusion: `HOW: ${how} This annex is an internal SAR-support pack for the pool Compliance Officer. It is not a FinCEN SAR and must not be filed by the agent.`,
          warnings: [
            "Confidentiality — no tip-off to the subject",
            "Document status: support draft — not submitted to FinCEN or any authority",
            "Organize facts chronologically; include individual dates/amounts from the ledger when preparing any human-owned filing",
            "Human judgment required before any BSA filing decision",
          ],
        };

  return {
    status:
      decision === "block"
        ? "Technical opinion · REVERT"
        : decision === "fee_override"
          ? "Technical opinion · oracle FEE_OVERRIDE"
          : "Legal opinion · ALLOW",
    documentType: decision === "allow" ? "legal-opinion" : "opinion + sar-annex",
    confidence: wallet.exploitConfirmed
      ? "HIGH"
      : decision === "fee_override"
        ? "MEDIUM"
        : "HIGH",
    humanReview,
    retentionYears: 5,
    auditHash: score.auditHash,
    technicalOpinion,
    sarAnnex,
    decisionRecord: {
      score: String(score.finalScore),
      output: score.hookOutput,
      mainFacts: `WHO ${wallet.accountLabel}; hop=${hop}; origin=${origin}; trigger=${score.validity.trigger}`,
      basis:
        decision === "block"
          ? wallet.exploitConfirmed
            ? "ORACLE_COA_EXPLOIT_SCORE_REVERT_BAND"
            : "ORACLE_COA_EXPLOIT_OR_BLOCK_BAND"
          : decision === "fee_override"
            ? "ORACLE_COA_N_HOP_OR_BEHAVIORAL_FEE_OVERRIDE"
            : "ORACLE_COA_SCORE_BELOW_FEE_OVERRIDE",
      nextReview: score.validity.nextReview,
    },
    note: agentRun
      ? `Internal operator documentation modeled on FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How). Produced by the Compliance Officer Agent (AI AML analyst / Oracle Keeper) after consulting connected information sources (run ${agentRun.runId}). Never filed with any authority.`
      : "Internal operator documentation modeled on FinCEN SAR Narrative Guidance (Who/What/When/Where/Why/How). Produced by the Compliance Officer Agent (AI AML analyst / Oracle Keeper). Never filed with any authority.",
  };
}
