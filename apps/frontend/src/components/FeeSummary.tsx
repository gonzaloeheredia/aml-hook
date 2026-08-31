"use client";

import type { DemoCase } from "@/data/cases";

type Props = {
  demoCase: DemoCase;
  /** Live swap counter: increments +1 after each completed node circuit */
  swapCount: number;
  /** Cumulative USDC sold across completed circuits for this wallet */
  tradedUsd: number;
  /** Cumulative ETH bought across completed circuits for this wallet */
  tradedEth: number;
};

/**
 * Formats pool fee basis points as a percentage string (e.g. 30 → "0.30%").
 */
function feeLabel(bps: number) {
  return `${(bps / 100).toFixed(2)}%`;
}

/**
 * Formats gas units with thousands separators for display.
 */
function formatGas(gas: number) {
  return gas.toLocaleString("en-US");
}

/**
 * Formats ETH amounts for the traded-volume line.
 */
function formatEth(amount: number) {
  if (amount <= 0) return "0 ETH";
  const rounded = Math.round(amount * 10_000) / 10_000;
  return `${rounded.toLocaleString("en-US", { maximumFractionDigits: 4 })} ETH`;
}

/**
 * Two columns under the simulator:
 * - Left: fee / gas / time metrics from the active demo case
 * - Right: live swap counter + USDC sold / ETH bought
 */
export function FeeSummary({
  demoCase,
  swapCount,
  tradedUsd,
  tradedEth,
}: Props) {
  const blocked = demoCase.decision === "block";
  const feeOverride = demoCase.decision === "fee_override";

  return (
    <div className="mx-auto grid w-full grid-cols-1 gap-6 sm:grid-cols-2">
      <div className="surface radius-b border-l hair px-5 py-6">
        <MetricRow label="Pool base fee" value={feeLabel(demoCase.baseFeeBps)} />
        <MetricRow
          label="AML fee (hook)"
          value={
            blocked
              ? "n/a"
              : feeOverride
                ? `${feeLabel(demoCase.appliedFeeBps)} · override`
                : feeLabel(demoCase.appliedFeeBps)
          }
          tone={
            feeOverride ? "text-uni-warn" : blocked ? "text-uni-bad" : undefined
          }
        />
        <MetricRow label="Gas used" value={formatGas(demoCase.gasUsed)} mono />
        <MetricRow
          label="Total time"
          value={`${demoCase.totalTimeSec.toFixed(2)}s`}
          mono
        />
      </div>

      <div className="surface radius-b border-l hair px-5 py-6">
        <div className="label-kicker">Swaps settled</div>
        <div className="value-hero mt-2 text-uni-pink tabular-nums">{swapCount}</div>
        <div className="mt-6">
          <MetricRow
            label="Sold (USDC)"
            value={`${tradedUsd.toLocaleString("en-US")} USDC`}
          />
          <MetricRow label="Bought (ETH)" value={formatEth(tradedEth)} />
        </div>
      </div>
    </div>
  );
}

function MetricRow({
  label,
  value,
  tone,
  mono,
}: {
  label: string;
  value: string;
  tone?: string;
  mono?: boolean;
}) {
  return (
    <div className="py-2.5">
      <div className="label-kicker">{label}</div>
      <div
        className={`mt-1 font-serif text-[22px] leading-none tracking-tight ${
          tone ?? "text-uni-pink"
        } ${mono ? "font-mono text-[18px]" : ""}`}
      >
        {value}
      </div>
    </div>
  );
}
