"use client";

import type { HookChainEvent } from "@/lib/hookEvents";
import { formatEventPayload } from "@/lib/hookEvents";

type Props = {
  /** Chronological list of hook emits */
  events: HookChainEvent[];
  /** When false, the page owns the stage title (Event). */
  showTitle?: boolean;
};

/**
 * Fields written on-chain by afterSwap (use-case §3 / §5):
 * { address, score, decision, fee, amount_usdc, hop_distance?, origin?, timestamp }
 */
function afterSwapRows(event: HookChainEvent) {
  const rows: { label: string; value: string }[] = [
    { label: "address", value: event.address },
    { label: "score", value: String(event.score) },
    { label: "decision", value: event.decision },
    { label: "fee", value: event.fee },
    {
      label: "amount_usdc",
      value: `${event.amountUsd.toLocaleString("en-US")} USDC`,
    },
  ];
  if (event.hopDistance != null) {
    rows.push({ label: "hop_distance", value: String(event.hopDistance) });
  }
  if (event.origin && event.origin !== "—") {
    rows.push({ label: "origin", value: event.origin });
  }
  rows.push({ label: "timestamp", value: event.timestamp });
  return rows;
}

/**
 * Pool blockchain record — only the afterSwap SwapObserved payload
 * from the project use-case document.
 */
export function OnChainAccumulator({ events, showTitle = true }: Props) {
  const afterSwapEvents = events.filter((e) => e.hookPhase === "afterSwap");
  const last = afterSwapEvents.length
    ? afterSwapEvents[afterSwapEvents.length - 1]
    : null;
  const blockedOnly =
    !last && events.some((e) => e.eventName === "WalletBlocked");

  return (
    <div
      className="rounded-2xl border border-[#7A1B5A]/45 px-7 py-7 shadow-[0_0_40px_rgba(252,114,255,0.1)] md:px-10 md:py-9"
      style={{
        background:
          "linear-gradient(145deg, #2a0b21 0%, #1a0714 45%, #12040e 100%)",
      }}
    >
      {showTitle ? (
        <div className="mb-3 flex items-center gap-1.5 text-xs font-medium text-uni-pink">
          <span aria-hidden>◈</span>
          <span>afterSwap · SwapObserved</span>
        </div>
      ) : null}

      {last ? (
        <>
          <div className="mb-2.5 text-[11px] text-[#F5A3FF]/70">
            On-chain payload
          </div>
          <div className="grid gap-3 sm:grid-cols-2">
            {afterSwapRows(last).map((row) => (
              <div
                key={row.label}
                className="flex items-center justify-between gap-3 rounded-xl border border-uni-pink/20 bg-black/25 px-4 py-3 text-xs"
              >
                <span className="shrink-0 font-mono text-[#F5A3FF]/75">
                  {row.label}
                </span>
                <span className="truncate text-right font-medium text-uni-pink">
                  {row.value}
                </span>
              </div>
            ))}
          </div>

          <div className="mt-6">
            <div className="mb-2.5 text-[11px] text-[#F5A3FF]/70">
              Event log
            </div>
            <pre className="overflow-auto rounded-xl border border-uni-pink/20 bg-black/40 px-5 py-4 font-mono text-[11px] leading-relaxed text-[#F5A3FF]">
              {formatEventPayload(last)}
            </pre>
          </div>
        </>
      ) : blockedOnly ? (
        <p className="mt-1 text-xs leading-relaxed text-[#F5A3FF]/75">
          <span className="font-semibold text-uni-pink">REVERT</span> in{" "}
          <span className="text-uni-pink">beforeSwap</span> — afterSwap never
          runs, so nothing is written to the pool event log for this swap.
        </p>
      ) : (
        <p className="mt-1 text-xs text-[#F5A3FF]/65">
          No afterSwap emit yet. Complete a swap that reaches afterSwap
          (ALLOW or FEE_OVERRIDE) to write the audit record.
        </p>
      )}
    </div>
  );
}
