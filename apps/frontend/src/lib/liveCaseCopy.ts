/**
 * Rewrites A–E case copy from live officer knobs.
 * Defaults stay 3% / 8% / $1k / $15k until GET /policy hydrates hopScoring.
 */

import type { DemoCase } from "@/data/cases";
import {
  dustExampleUsd,
  formatFeePct,
  formatUsdFloor,
  getPolicyKnobs,
  hopFeePct,
  midBandExampleUsd,
  neverScoredAmountPresets,
} from "@/lib/hopScoring";

/**
 * Applies live 3%/8%/$1k/$15k (or the officer's retune) to summaries,
 * Opinion recommendations, and E size chips.
 */
export function applyLiveCaseCopy(demoCase: DemoCase): DemoCase {
  const knobs = getPolicyKnobs();
  const mid = formatFeePct(knobs.proportionalFeeBps);
  const high = formatFeePct(knobs.punitiveFeeBps);
  const feeFloor = formatUsdFloor(knobs.unscoredFeeThresholdUsd);
  const revertFloor = formatUsdFloor(knobs.unscoredRevertThresholdUsd);
  const dust = formatUsdFloor(dustExampleUsd(knobs.unscoredFeeThresholdUsd));
  const midEx = formatUsdFloor(
    midBandExampleUsd(knobs.unscoredFeeThresholdUsd, knobs.unscoredRevertThresholdUsd),
  );
  const hop1 = hopFeePct(1, knobs);
  const hop2 = hopFeePct(2, knobs);

  const opinion = demoCase.agent.technicalOpinion;
  const keepSummary = demoCase.summary[0]?.startsWith("Score ");
  let summary = demoCase.summary;
  let recommendations = opinion.recommendations;
  let amountPresets = demoCase.amountPresets;
  let nextReview = demoCase.agent.decisionRecord.nextReview;

  if (demoCase.id === "B") {
    if (!keepSummary) {
      summary = [
        "Starts clean, with no contamination. Swaps remain ALLOW 0.30% until a hop arrives.",
        `After A → B: score ≈ 65 · ${hop1}. After tainted C → B: score ≈ 42 · ${hop2}.`,
        "Closer hop wins if both occur. Pool swaps never raise a hop.",
      ];
    }
    recommendations = `Monitor inbound from A (1-hop ≈ 65 / ${hop1}) or tainted C (2-hop ≈ 42 / ${hop2}). Closer hop wins if both occur.`;
  }

  if (demoCase.id === "C") {
    if (!keepSummary) {
      summary = [
        "Starts clean, with 50,000 USDC. Fund E (unknown, no hop) or D (inflow).",
        `After A → C: score ≈ 65 · ${hop1}. After tainted B → C: score ≈ 42 · ${hop2}.`,
        "Closer hop wins if both occur. Pool swaps never raise a hop.",
      ];
    }
    recommendations = `Fund E (unknown, no hop) or D (inflow). Monitor inbound from A (1-hop ≈ 65 / ${hop1}) or tainted B (2-hop ≈ 42 / ${hop2}).`;
    nextReview = `Fund E (unknown) or D (inflow). Watch inbound from A (1-hop) or tainted B (2-hop)`;
  }

  if (demoCase.id === "D") {
    if (!keepSummary) {
      summary = [
        "Published score 0: confirmed clean. Already-held USDC swaps at 0.30%.",
        `Floor B: swap ${feeFloor} then Advance 5 min (no keeper write) → ${mid}. Floor C: two swaps that add to ${revertFloor} → REVERT.`,
        `Clean C→D is an inflow (no hop): +${midEx} → ${mid}; +${revertFloor} → ${high}. A→D is a hop. Do not use it for Floor D.`,
      ];
    }
    recommendations = `Swap D first (ALLOW). Advance 5 min after that swap to see Floor B ${mid}. Restart, then C→D ${midEx} (${mid}) or ${revertFloor} (${high}).`;
    nextReview = `On Floor B (Advance 5 min), clean C→D, or a 24h ${revertFloor} sum`;
  }

  if (demoCase.id === "E") {
    amountPresets = neverScoredAmountPresets(knobs);
    if (!keepSummary) {
      summary = [
        "No oracle row. Starts empty. Fund from clean C in MetaMask (no hop). Do not use A.",
        `After C→E ${dust} → next ${dust} swap is ${mid}. C→E ${midEx} then ${feeFloor} swap → ${high} (A mid). C→E ${revertFloor} + small swap → ${high} (D). This swap ${revertFloor} → REVERT.`,
        `${midEx} then a remainder that crosses ${revertFloor} in 24h is Floor C. Unbind the feed with POST /demo/price-feed after a quote → last FX (silent under 30 min; same bands).`,
      ];
    }
    recommendations = `Fund E from C first. Then use the size chips: bag ${dust} → ${mid}; ${midEx} bag + ${feeFloor} swap → ${high} (A mid); ${revertFloor} bag + small swap → ${high} (D); this swap ${revertFloor} → revert.`;
    nextReview = `On keeper publish, or on a ${revertFloor} attempt`;
  }

  return {
    ...demoCase,
    amountPresets,
    summary,
    agent: {
      ...demoCase.agent,
      technicalOpinion: {
        ...opinion,
        recommendations,
        riskAndScoring:
          keepSummary
            ? opinion.riskAndScoring
            : demoCase.id === "D"
              ? `Score 0/100 in the ALLOW band. Already-held funds swap at 0.30%. After clean C→D, inflow elevates to FEE_OVERRIDE ${mid} or ${high} by inbound USD, with no hop.`
              : demoCase.id === "E"
                ? `Unknown wallet. Starts empty. After clean C funds E, Floor A is this swap and Floor D is the unpublished bag. The stricter fee wins. Floor A reverts this swap at ${revertFloor}.`
                : opinion.riskAndScoring,
        decisionExecuted:
          keepSummary
            ? opinion.decisionExecuted
            : demoCase.id === "D"
              ? `Baseline ALLOW. After clean C→D, beforeSwap floors to FEE_OVERRIDE ${mid} (${midEx} inbound) or ${high} (${revertFloor}). D remains score 0 (no hop).`
              : demoCase.id === "E"
                ? `beforeSwap applies Floor A (this swap) and Floor D (bag). afterSwap emits SwapObserved on the fee path; a ${revertFloor} attempt reverts.`
                : opinion.decisionExecuted,
      },
      decisionRecord: {
        ...demoCase.agent.decisionRecord,
        nextReview,
      },
    },
  };
}
