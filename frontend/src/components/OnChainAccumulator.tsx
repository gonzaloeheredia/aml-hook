"use client";

import type { DemoCase } from "@/data/cases";
import { VOLUME_THRESHOLD_USD } from "@/lib/riskEscalation";

type Props = {
  demoCase: DemoCase;
  /** Baseline score before live volume escalation */
  baseScore: number;
  connectedAddress: string | null;
  /** Completed demo swaps for this wallet */
  swapCount: number;
  /** Cumulative USD traded in the 24h demo window */
  tradedUsd: number;
};

/**
 * Formats a USD amount for the accumulator metrics.
 */
function formatUsd(amount: number) {
  return `$${amount.toLocaleString("en-US")}`;
}

/**
 * Builds a deterministic fake tx hash from wallet + swap index (demo only).
 */
function fakeTxHash(address: string, swapCount: number) {
  const seed = `${address}-${swapCount}`.replace(/[^a-fA-F0-9]/g, "");
  const hex = (seed + "c0ffeeabad1dea").slice(0, 16).padEnd(16, "0");
  return `0x${hex}…${hex.slice(-4)}`;
}

/**
 * Pink on-chain panel: wallet 24h accumulator + last ScoreUpdated event payload.
 * Visual language matches the Detection Data card (magenta / deep rose).
 */
export function OnChainAccumulator({
  demoCase,
  baseScore,
  connectedAddress,
  swapCount,
  tradedUsd,
}: Props) {
  const address = connectedAddress ?? demoCase.wallet;
  const windowUsd = demoCase.structuring.totalUsd;
  const scoreDelta = demoCase.score - baseScore;
  const lastAmount = swapCount > 0 ? demoCase.structuring.amountUsd : 0;
  const eventName =
    demoCase.decision === "block"
      ? "WalletBlocked"
      : scoreDelta !== 0
        ? "ScoreUpdated"
        : "SwapObserved";

  const tags = [
    { label: `${swapCount} live swaps` },
    { label: `24h ≥ ${formatUsd(VOLUME_THRESHOLD_USD)} → escalate` },
    {
      label:
        demoCase.agent.hookOutput === "ALLOW"
          ? "Standard fee"
          : demoCase.agent.hookOutput === "FEE_DIFERENCIAL"
            ? "Differential fee"
            : "Fail-closed",
    },
  ];

  const rows: { label: string; value: string }[] = [
    { label: "Event", value: eventName },
    { label: "Wallet", value: `${address.slice(0, 6)}…${address.slice(-4)}` },
    { label: "Amount (last swap)", value: swapCount ? formatUsd(lastAmount) : "—" },
    { label: "24h accumulated", value: formatUsd(windowUsd) },
    {
      label: "Score (prev → new)",
      value:
        swapCount > 0
          ? `${baseScore} → ${demoCase.score}${scoreDelta ? ` (${scoreDelta > 0 ? "+" : ""}${scoreDelta})` : ""}`
          : `${demoCase.score} (unchanged)`,
    },
    { label: "Hook output", value: demoCase.agent.hookOutput },
    {
      label: "Applied fee",
      value:
        demoCase.decision === "block"
          ? "— (revert)"
          : `${(demoCase.appliedFeeBps / 100).toFixed(2)}%`,
    },
    {
      label: "Tx hash",
      value: swapCount > 0 ? fakeTxHash(address, swapCount) : "— pending",
    },
    {
      label: "Block",
      value: swapCount > 0 ? String(22_814_500 + swapCount * 17) : "—",
    },
  ];

  return (
    <div
      className="mt-4 rounded-[28px] border border-[#7A1B5A]/45 px-12 py-8 shadow-[0_0_40px_rgba(252,114,255,0.1)] md:px-20 md:py-10 lg:px-28 lg:py-12"
      style={{
        background:
          "linear-gradient(145deg, #2a0b21 0%, #1a0714 45%, #12040e 100%)",
      }}
    >
      <div className="mb-4 flex items-center gap-2 text-sm font-medium text-uni-pink">
        <span aria-hidden>◈</span>
        <span>On-chain accumulator · Score event</span>
      </div>

      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">
            {formatUsd(tradedUsd)}
          </div>
          <div className="text-sm text-[#F5A3FF]/80">Live traded (24h)</div>
        </div>
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">{swapCount}</div>
          <div className="text-sm text-[#F5A3FF]/80">Swaps completed</div>
        </div>
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">
            {formatUsd(windowUsd)}
          </div>
          <div className="text-sm text-[#F5A3FF]/80">Window total on-chain</div>
        </div>
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">{demoCase.score}</div>
          <div className="text-sm text-[#F5A3FF]/80">Current score</div>
        </div>
      </div>

      <div className="mt-5">
        <div className="mb-2 text-sm text-[#F5A3FF]/70">Event tags</div>
        <div className="flex flex-wrap gap-2">
          {tags.map((tag) => (
            <span
              key={tag.label}
              className="rounded-full border border-uni-pink/35 bg-uni-pink/10 px-3 py-1 text-xs font-semibold text-uni-pink"
            >
              {tag.label}
            </span>
          ))}
        </div>
      </div>

      <div className="mt-5 space-y-2">
        <div className="mb-1 text-sm text-[#F5A3FF]/70">
          Last blockchain event (updates scoring)
        </div>
        {rows.map((row) => (
          <div
            key={row.label}
            className="flex items-center justify-between gap-3 rounded-xl border border-uni-pink/20 bg-black/25 px-3 py-2 text-sm"
          >
            <span className="shrink-0 text-[#F5A3FF]/75">{row.label}</span>
            <span className="truncate text-right font-medium text-uni-pink">
              {row.value}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
