/**
 * Overlays a live backend compliance pack onto a static DemoCase
 * so Swap / Flow / Audit track the API ledger (not only local hop math).
 */

import type { DemoCase } from "@/data/cases";
import type { ApiCompliancePack } from "@/lib/api";
import { ETH_USD, ethOutFromSwap } from "@/lib/hopScoring";

/**
 * Formats a whole USDC sell amount for the swap widget.
 */
function formatUsdcSell(n: number) {
  return Math.round(n).toLocaleString("en-US");
}

/**
 * Formats ETH buy amount for the swap widget.
 */
function formatEthBuy(n: number) {
  if (n <= 0) return "0";
  return n.toLocaleString("en-US", {
    minimumFractionDigits: 4,
    maximumFractionDigits: 4,
  });
}

/**
 * Merges GET /wallets/:id/compliance into the hardcoded case template.
 */
export function withComplianceOverlay(
  base: DemoCase,
  pack: ApiCompliancePack,
): DemoCase {
  const { decision, score, appliedFeeBps, hopDistance, originId } = pack;
  const feeMultiplier =
    decision === "block"
      ? 0
      : decision === "allow"
        ? 1
        : appliedFeeBps / base.baseFeeBps;

  const usdcIn = Math.min(base.activity.amountUsd, pack.usdc);
  const ethOut =
    decision === "block" ? 0 : ethOutFromSwap(usdcIn, appliedFeeBps);

  const decisionLabel =
    decision === "block"
      ? "Block"
      : decision === "fee_override"
        ? "Fee override"
        : "Allow";

  const hopTag =
    hopDistance == null
      ? "Clean path"
      : hopDistance === 0
        ? "Exploit source"
        : `${hopDistance}-hop decay`;

  return {
    ...base,
    wallet: pack.address,
    walletLabel: pack.accountLabel,
    score,
    riskLabel: pack.riskLabel,
    decision,
    decisionLabel,
    appliedFeeBps,
    feeMultiplier: Number.isFinite(feeMultiplier)
      ? Number(feeMultiplier.toFixed(2))
      : 1,
    exploitConfirmed: pack.exploitConfirmed,
    activity: {
      ...base.activity,
      hopDistance,
      origin: originId ?? "—",
      totalUsd: pack.usdc + pack.eth * ETH_USD,
      amountUsd: usdcIn,
    },
    typology: pack.exploitConfirmed
      ? "Exploit cash-out"
      : hopDistance
        ? "N-hop propagation"
        : "None",
    flowPath: decision,
    sellToken: "USDC",
    buyToken: "ETH",
    swapSell: formatUsdcSell(usdcIn),
    swapBuy: formatEthBuy(ethOut),
    summary: pack.summary.length ? pack.summary : base.summary,
    signals: [
      {
        label: "Exploit / sanctions",
        value: pack.exploitConfirmed ? "Exploit cluster" : "Clear",
        tone: pack.exploitConfirmed ? "bad" : "ok",
      },
      {
        label: "Keeper score",
        value: `${score} / 100`,
        tone:
          decision === "block"
            ? "bad"
            : decision === "fee_override"
              ? "warn"
              : "ok",
      },
      {
        label: "Hop distance",
        value: hopDistance == null ? "—" : String(hopDistance),
        tone: decision === "allow" ? "ok" : "warn",
      },
      {
        label: "Applied fee",
        value:
          decision === "block"
            ? "—"
            : `${(appliedFeeBps / 100).toFixed(2)}%`,
        tone:
          decision === "fee_override"
            ? "warn"
            : decision === "block"
              ? "bad"
              : "ok",
      },
    ],
    tags: [
      { label: hopTag, tone: decision === "allow" ? "ok" : "warn" },
      {
        label: pack.hookOutput,
        tone:
          decision === "block"
            ? "bad"
            : decision === "fee_override"
              ? "warn"
              : "ok",
      },
    ],
    agent: {
      ...base.agent,
      status: pack.agent.status,
      hookOutput: pack.hookOutput,
      documentType: pack.agent.documentType,
      confidence: pack.agent.confidence,
      humanReview: pack.agent.humanReview,
      retentionYears: pack.agent.retentionYears,
      auditHash: pack.agent.auditHash,
      technicalOpinion: pack.agent.technicalOpinion,
      sarAnnex: pack.agent.sarAnnex,
      decisionRecord: pack.agent.decisionRecord,
      note: pack.agent.note,
      run: pack.agent.run,
    },
  };
}
