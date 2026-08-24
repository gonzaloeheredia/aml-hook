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
    <div className="surface radius-g border-l hair px-7 py-8 md:translate-x-8 md:px-10 md:py-10">
      {showTitle ? (
        <div className="label-kicker mb-6">
          afterSwap · SwapObserved
        </div>
      ) : null}

      {last ? (
        <>
          <div className="label-kicker mb-5">On-chain payload</div>
          <div className="grid gap-x-10 gap-y-5 sm:grid-cols-2">
            {afterSwapRows(last).map((row) => (
              <div key={row.label}>
                <span className="font-mono text-[11px] tracking-wide text-uni-muted">
                  {row.label}
                </span>
                <div className="mt-1.5 truncate font-serif text-[18px] text-uni-pink">
                  {row.value}
                </div>
              </div>
            ))}
          </div>

          <div className="mt-8">
            <div className="label-kicker mb-3">Event log</div>
            <pre className="overflow-auto border-l hair bg-transparent py-3 pl-4 font-mono text-[11px] leading-relaxed text-uni-pink">
              {formatEventPayload(last)}
            </pre>
          </div>
        </>
      ) : blockedOnly ? (
        <p className="mt-1 text-xs leading-relaxed text-uni-muted">
          <span className="font-medium text-uni-pink">REVERT</span> in{" "}
          <span className="text-uni-pink">beforeSwap</span> — afterSwap never
          runs, so nothing is written to the pool event log for this swap.
        </p>
      ) : (
        <p className="mt-1 text-xs text-uni-muted">
          No afterSwap emit yet. Complete a swap that reaches afterSwap
          (ALLOW or FEE_OVERRIDE) to write the audit record.
        </p>
      )}
    </div>
  );
}
