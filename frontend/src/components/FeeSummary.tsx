"use client";

import type { DemoCase } from "@/data/cases";

type Props = {
  demoCase: DemoCase;
  /** Live swap counter — increments +1 after each completed node circuit */
  swapCount: number;
  /** Cumulative USD traded across completed circuits for this wallet */
  tradedUsd: number;
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
 * Formats a USD amount for the traded-volume line.
 */
function formatUsd(amount: number) {
  return `$${amount.toLocaleString("en-US")}`;
}

/**
 * Two equal cards under the simulator:
 * - Left: fee / gas / time metrics from the active demo case
 * - Right: live swap counter (+1 per completed flow) and cumulative USD traded
 */
export function FeeSummary({ demoCase, swapCount, tradedUsd }: Props) {
  const blocked = demoCase.decision === "block";
  const surcharge = demoCase.decision === "surcharge";

  return (
    <div className="mx-auto mt-6 grid w-full max-w-3xl grid-cols-1 gap-4 animate-fadeUp sm:grid-cols-2">
      {/* Left — fee / gas / time */}
      <div className="flex min-h-[168px] flex-col justify-center rounded-[20px] border border-uni-border/80 bg-uni-card/90 px-5 py-4 text-sm shadow-glow">
        <div className="flex justify-between text-uni-muted">
          <span>Pool base fee</span>
          <span className="text-white">{feeLabel(demoCase.baseFeeBps)}</span>
        </div>
        <div className="mt-2 flex justify-between text-uni-muted">
          <span>AML fee (hook)</span>
          <span
            className={
              surcharge
                ? "font-semibold text-uni-warn"
                : blocked
                  ? "text-uni-bad"
                  : "text-white"
            }
          >
            {blocked
              ? "—"
              : surcharge
                ? `${feeLabel(demoCase.appliedFeeBps)} · ${demoCase.feeMultiplier}x`
                : feeLabel(demoCase.appliedFeeBps)}
          </span>
        </div>
        <div className="mt-2 flex justify-between text-uni-muted">
          <span>Gas used</span>
          <span className="font-mono text-white">{formatGas(demoCase.gasUsed)}</span>
        </div>
        <div className="mt-2 flex justify-between text-uni-muted">
          <span>Total time</span>
          <span className="font-mono text-white">
            {demoCase.totalTimeSec.toFixed(2)}s
          </span>
        </div>
      </div>

      {/* Right — live swap counter + traded volume */}
      <div className="flex min-h-[168px] flex-col items-center justify-center rounded-[20px] border border-uni-border/80 bg-uni-card/90 px-5 py-4 text-sm shadow-glow">
        <div className="text-uni-muted">Swap counter</div>
        <div className="mt-1 text-5xl font-bold tracking-tight text-white tabular-nums">
          {swapCount}
        </div>
        <div className="mt-4 flex w-full justify-between text-uni-muted">
          <span>Amount traded</span>
          <span className="text-white">{formatUsd(tradedUsd)}</span>
        </div>
      </div>
    </div>
  );
}
