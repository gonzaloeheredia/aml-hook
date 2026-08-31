"use client";

import type { HookChainEvent } from "@/lib/hookEvents";
import { formatEventPayload } from "@/lib/hookEvents";

type Props = {
  /** Chronological list of hook emits */
  events: HookChainEvent[];
  /** When false, the page owns the stage title (Event). */
  showTitle?: boolean;
  /** A–D use the API demo trail; E reads Sepolia SwapObserved. */
  trail?: "demo" | "chain";
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
      value:
        event.source === "chain" && event.amountUsd === 0
          ? "n/a"
          : `${event.amountUsd.toLocaleString("en-US")} USDC`,
    },
  ];
  if (event.hopDistance != null) {
    rows.push({ label: "hop_distance", value: String(event.hopDistance) });
  }
  if (event.origin && event.origin !== "n/a") {
    rows.push({ label: "origin", value: event.origin });
  }
  rows.push({ label: "timestamp", value: event.timestamp });
  if (event.txHash.startsWith("0x") && event.txHash.length >= 66) {
    rows.push({ label: "tx", value: event.txHash });
  }
  return rows;
}

/**
 * Latest hook emit: SwapObserved (afterSwap) or WalletBlocked (beforeSwap).
 */
export function OnChainAccumulator({
  events,
  showTitle = true,
  trail = "demo",
}: Props) {
  const last = events.length ? events[events.length - 1] : null;
  const blocked = last?.eventName === "WalletBlocked";
  const demo = trail === "demo";

  return (
    <div className="surface radius-g border-l hair px-7 py-8 md:translate-x-8 md:px-10 md:py-10">
      {showTitle ? (
        <div className="label-kicker mb-6">
          {blocked ? "beforeSwap · WalletBlocked" : "afterSwap · SwapObserved"}
        </div>
      ) : null}

      {last ? (
        <>
          <div className="label-kicker mb-5">
            {blocked
              ? "REVERT · beforeSwap"
              : demo
                ? "Demo trail payload"
                : "On-chain payload"}
          </div>
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
      ) : (
        <p className="mt-1 text-xs text-uni-muted">
          {demo
            ? "No demo event yet. Get started writes SwapObserved (ALLOW / FEE_OVERRIDE) or WalletBlocked (REVERT) here."
            : "No afterSwap emit yet. A Sepolia fill that reaches afterSwap writes SwapObserved. REVERT never emits."}
        </p>
      )}
    </div>
  );
}
