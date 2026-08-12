/**
 * Deterministic fact-scoring engine (MOCK_MODE) implementing
 * agents/oracle-coa/skills/fact-scoring.md for the UHI10 demo ledger.
 *
 * Live vendor APIs are not called — facts are derived from the in-memory
 * N-hop ledger, P2P transfers, and afterSwap / WalletBlocked events.
 */

import { createHash } from "node:crypto";
import {
  DECAY_FACTOR,
  ORIGIN_EXPLOIT_SCORE,
  decisionFromScore,
  feeBpsFromHop,
  toHookOutput,
} from "../scoring.js";
import type { HookEvent, TransferRecord, Wallet, WalletId } from "../types.js";
import type {
  FactEvent,
  OracleTrigger,
  ScoreBreakdown,
  ScoreResult,
} from "./types.js";

/** Historical blend weight (fact-scoring §3.3 default). */
const HISTORICAL_DECAY = 0.4;

/**
 * Builds admissible FactEvents for a wallet from live ledger state.
 */
export function buildFacts(
  wallet: Wallet,
  transfers: TransferRecord[],
  events: HookEvent[],
): FactEvent[] {
  const facts: FactEvent[] = [];
  const walletEvents = events.filter((e) => e.walletId === wallet.id);
  const inbound = transfers.filter((t) => t.to === wallet.id);
  const outbound = transfers.filter((t) => t.from === wallet.id);

  if (wallet.exploitConfirmed) {
    facts.push(
      fact(
        "EXPLOIT_PROTOCOL_FUNDS",
        "NW",
        100,
        "HIGH",
        "FATF VA Red Flags Cat. 5 · OFAC VC Guidance 2021",
        `${wallet.accountLabel} is the confirmed exploit cash-out source (Compliance Officer Agent · threat feed). Override to score 100.`,
      ),
    );
  }

  if (
    typeof wallet.hopDistance === "number" &&
    wallet.hopDistance >= 1 &&
    !wallet.exploitConfirmed
  ) {
    const hop = wallet.hopDistance;
    const origin = wallet.originId ?? "A";
    const weight = Math.round(ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** hop);
    facts.push(
      fact(
        hop === 1 ? "HIGH_RISK_COUNTERPARTY" : "MEDIUM_RISK_COUNTERPARTY",
        "NW",
        weight,
        "HIGH",
        "FATF Rec. 10 · VA Red Flags Cat. 5 (indirect exposure)",
        `${hop}-hop contamination from origin ${origin}. N-hop decay applied by COA: 100 × ${DECAY_FACTOR}^${hop} ≈ ${weight}.`,
      ),
    );
    if (inbound.length > 0) {
      const last = inbound[inbound.length - 1];
      facts.push(
        fact(
          "RAPID_FULL_BALANCE_TRANSFER",
          "NW",
          hop === 1 ? 8 : 5,
          "MEDIUM",
          "FATF VA Red Flags Cat. 2",
          `Inbound P2P ${last.from}→${last.to} for ${last.amountUsd} USDC recorded; hop graph updated.`,
        ),
      );
    }
  }

  const swapObserved = walletEvents.filter((e) => e.kind === "SwapObserved");
  if (swapObserved.length >= 3 && wallet.hopDistance == null && !wallet.exploitConfirmed) {
    facts.push(
      fact(
        "STRUCTURING_VELOCITY_SPIKE",
        "ST",
        5,
        "LOW",
        "FATF VA Red Flags Cat. 1",
        `${swapObserved.length} SwapObserved emits on a clean path — activity noted; not alone grounds for FEE_OVERRIDE.`,
      ),
    );
  }

  if (
    wallet.hopDistance == null &&
    !wallet.exploitConfirmed &&
    outbound.length === 0 &&
    inbound.length === 0
  ) {
    facts.push(
      fact(
        "LONG_CLEAN_HISTORY",
        "MT",
        -10,
        "MEDIUM",
        "FATF Rec. 1 · Rec. 10 (EBR)",
        "No inbound contamination from exploit origin; clean ledger path.",
      ),
    );
    facts.push(
      fact(
        "COHERENT_TRANSACTION_PROFILE",
        "MT",
        -8,
        "MEDIUM",
        "FATF Rec. 10",
        "Pool activity consistent with a clean RWA participant profile.",
      ),
    );
  }

  return facts;
}

/**
 * Runs fact-scoring and returns a ScoreResult.
 */
export function scoreFromFacts(
  wallet: Wallet,
  facts: FactEvent[],
  trigger: OracleTrigger,
  priorScore: number | null,
  skillsApplied: string[],
  flow: "FULL" | "INCREMENTAL",
): ScoreResult {
  const override = facts.some(
    (f) =>
      f.type === "EXPLOIT_PROTOCOL_FUNDS" ||
      f.type === "OFAC_DIRECT_MATCH" ||
      (f.baseWeight >= 100 && f.dimension === "S"),
  );

  let scorePresent = 0;
  const breakdown: ScoreBreakdown = {
    sanctions: 0,
    structuring: 0,
    mixerExposure: 0,
    networkBehavior: 0,
    geographicRisk: 0,
    defiTypologies: 0,
    mitigants: 0,
    historicalComponent: 0,
  };

  const scoredFacts: FactEvent[] = [];

  if (override && wallet.exploitConfirmed) {
    scorePresent = 100;
    breakdown.sanctions = 100;
    for (const f of facts) {
      scoredFacts.push({ ...f, scoreContribution: f.baseWeight });
    }
  } else {
    let rawMt = 0;
    for (const f of facts) {
      const confMod =
        f.confidence === "HIGH" ? 1 : f.confidence === "MEDIUM" ? 0.85 : 0.6;
      const contrib = Math.round(f.baseWeight * confMod);
      scoredFacts.push({ ...f, scoreContribution: contrib });

      if (f.dimension === "MT") {
        rawMt += Math.abs(contrib);
        breakdown.mitigants += Math.abs(contrib);
      } else if (f.dimension === "ST") {
        breakdown.structuring += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "MX") {
        breakdown.mixerExposure += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "GEO") {
        breakdown.geographicRisk += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "DF") {
        breakdown.defiTypologies += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "S") {
        breakdown.sanctions += contrib;
        scorePresent += contrib;
      } else {
        breakdown.networkBehavior += contrib;
        scorePresent += contrib;
      }
    }
    const mtCapped = Math.min(rawMt, 40);
    breakdown.mitigants = mtCapped;
    scorePresent = Math.max(0, scorePresent - mtCapped);
  }

  // Prefer hop-aligned present score when hop facts dominate (demo fidelity)
  if (
    !wallet.exploitConfirmed &&
    typeof wallet.hopDistance === "number" &&
    wallet.hopDistance >= 1
  ) {
    scorePresent = Math.round(
      ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** wallet.hopDistance,
    );
    breakdown.networkBehavior = scorePresent;
    breakdown.mitigants = 0;
  }

  let finalScore = clamp(scorePresent, 0, 100);
  if (priorScore != null && !wallet.exploitConfirmed) {
    const blended = Math.round(
      priorScore * HISTORICAL_DECAY + scorePresent * (1 - HISTORICAL_DECAY),
    );
    breakdown.historicalComponent = Math.round(priorScore * HISTORICAL_DECAY);
    if (wallet.hopDistance == null) {
      finalScore = clamp(blended, 0, 100);
    }
  }

  const decision = decisionFromScore(finalScore);
  const hasHigh = scoredFacts.some(
    (f) => f.confidence === "HIGH" && f.scoreContribution > 0,
  );
  let hookOutput = toHookOutput(decision);
  const regulatoryFlags: ScoreResult["regulatoryFlags"] = [];

  if (finalScore >= 71 && !hasHigh && !wallet.exploitConfirmed) {
    finalScore = 70;
    hookOutput = "FEE_OVERRIDE";
    regulatoryFlags.push({
      type: "INSUFFICIENT_CONFIDENCE",
      description: "Block band without HIGH fact — degraded to FEE_OVERRIDE.",
      recommendation: "Human review before fail-closed treatment.",
    });
  }

  if (
    finalScore >= 65 &&
    scoredFacts.filter((f) => f.dimension !== "MT").length >= 2
  ) {
    regulatoryFlags.push({
      type: "REASONABLE_SUSPICION_REACHED",
      description: "Score ≥ 65 with multiple non-mitigant facts.",
      recommendation: "Prepare SAR-support annex for Compliance Officer review.",
    });
  }

  if (decision === "block" || wallet.exploitConfirmed) {
    regulatoryFlags.push({
      type: "HUMAN_REVIEW_REQUIRED",
      description: "REVERT / exploit path requires human oversight.",
      recommendation: "Watch outbound P2P contamination of B/C.",
    });
  }

  const riskLevel =
    finalScore >= 71 ? "BLOCK" : finalScore >= 31 ? "ELEVATED" : "STANDARD";

  // COA owns the recommended fee (total friction; hook splits pool standard vs FeeEscrow differential).
  const recommendedFeeBps = feeBpsFromHop(finalScore, wallet.hopDistance);

  const payload = JSON.stringify({
    wallet: wallet.id,
    finalScore,
    recommendedFeeBps,
    scoredFacts,
    trigger,
  });
  const auditHash = `0x${createHash("sha256").update(payload).digest("hex").slice(0, 16)}`;

  return {
    walletId: wallet.id,
    address: wallet.address,
    finalScore,
    riskLevel,
    hookOutput,
    recommendedFeeBps,
    scoreBreakdown: breakdown,
    triggeringFacts: scoredFacts,
    regulatoryFlags,
    validity: {
      calculatedAt: new Date().toISOString(),
      trigger,
      nextReview: nextReviewIso(finalScore),
    },
    auditHash,
    skillsApplied,
    flow,
  };
}

function fact(
  type: string,
  dimension: FactEvent["dimension"],
  baseWeight: number,
  confidence: FactEvent["confidence"],
  regulatoryBasis: string,
  justification: string,
): FactEvent {
  return {
    factId: `${type}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
    type,
    confidence,
    baseWeight,
    scoreContribution: 0,
    regulatoryBasis,
    justification,
    dimension,
  };
}

function clamp(n: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, n));
}

function nextReviewIso(score: number): string {
  const days = score >= 71 ? 0 : score >= 51 ? 7 : score >= 21 ? 30 : 90;
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString();
}

export type { WalletId };
