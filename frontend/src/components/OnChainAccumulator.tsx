"use client";

import type { HookChainEvent } from "@/lib/hookEvents";
import { formatEventPayload } from "@/lib/hookEvents";
import { DECAY_FACTOR } from "@/lib/hopScoring";

type Props = {
  /** Chronological list of hook emits (afterSwap SwapObserved / beforeSwap WalletBlocked) */
  events: HookChainEvent[];
};

function formatUsd(amount: number) {
  return `$${amount.toLocaleString("en-US")}`;
}

function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * On-chain accumulator bound to the hook audit trail.
 * Shows the latest afterSwap (or beforeSwap REVERT) event payload
 * exactly as the use-case documents the emit.
 */
export function OnChainAccumulator({ events }: Props) {
  const last = events.length > 0 ? events[events.length - 1] : null;
  const afterSwapCount = events.filter((e) => e.hookPhase === "afterSwap").length;
  const totalTraded = events
    .filter((e) => e.eventName === "SwapObserved")
    .reduce((sum, e) => sum + e.amountUsd, 0);

  const tags = last
    ? [
        { label: last.hookPhase },
        { label: last.eventName },
        { label: last.decision },
        {
          label:
            last.hopDistance == null
              ? "Clean path"
              : last.hopDistance === 0
                ? "Exploit source"
                : `${last.hopDistance}-hop · decay ${DECAY_FACTOR}`,
        },
      ]
    : [{ label: "No emits yet" }];

  const rows = last
    ? [
        { label: "Hook phase", value: last.hookPhase },
        { label: "Event", value: last.eventName },
        { label: "Wallet", value: `${last.walletId} · ${shorten(last.address)}` },
        { label: "Score", value: String(last.score) },
        { label: "Decision", value: last.decision },
        { label: "Fee", value: last.fee },
        { label: "Amount", value: formatUsd(last.amountUsd) },
        {
          label: "Hop distance",
          value: last.hopDistance == null ? "—" : String(last.hopDistance),
        },
        { label: "Origin", value: last.origin },
        { label: "Timestamp", value: last.timestamp },
        { label: "Tx hash", value: shorten(last.txHash) },
        { label: "Block", value: String(last.blockNumber) },
      ]
    : [];

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
        <span>On-chain accumulator · afterSwap event</span>
      </div>

      <p className="mb-5 max-w-3xl text-sm leading-relaxed text-[#F5A3FF]/75">
        Audit trail from the hook emit. Successful swaps write{" "}
        <span className="text-uni-pink">SwapObserved</span> in{" "}
        <span className="text-uni-pink">afterSwap</span>. REVERT writes{" "}
        <span className="text-uni-pink">WalletBlocked</span> in{" "}
        <span className="text-uni-pink">beforeSwap</span> (afterSwap never runs).
      </p>

      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">
            {events.length}
          </div>
          <div className="text-sm text-[#F5A3FF]/80">Events emitted</div>
        </div>
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">
            {afterSwapCount}
          </div>
          <div className="text-sm text-[#F5A3FF]/80">afterSwap emits</div>
        </div>
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">
            {formatUsd(totalTraded)}
          </div>
          <div className="text-sm text-[#F5A3FF]/80">Observed volume</div>
        </div>
        <div>
          <div className="text-3xl font-bold text-uni-pink tabular-nums">
            {last ? last.score : "—"}
          </div>
          <div className="text-sm text-[#F5A3FF]/80">Last event score</div>
        </div>
      </div>

      <div className="mt-5">
        <div className="mb-2 text-sm text-[#F5A3FF]/70">Last emit tags</div>
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

      {last ? (
        <>
          <div className="mt-5 space-y-2">
            <div className="mb-1 text-sm text-[#F5A3FF]/70">
              Last emit fields
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

          <div className="mt-5">
            <div className="mb-2 text-sm text-[#F5A3FF]/70">
              Payload ({last.hookPhase} · {last.eventName})
            </div>
            <pre className="overflow-x-auto rounded-2xl border border-uni-pink/20 bg-black/40 p-4 font-mono text-xs leading-relaxed text-[#F5A3FF]">
              {formatEventPayload(last)}
            </pre>
          </div>

          {events.length > 1 && (
            <div className="mt-5">
              <div className="mb-2 text-sm text-[#F5A3FF]/70">Emit history</div>
              <div className="space-y-2">
                {[...events].reverse().map((e) => (
                  <div
                    key={e.id}
                    className="flex items-center justify-between gap-3 rounded-xl border border-uni-pink/15 bg-black/20 px-3 py-2 text-xs"
                  >
                    <span className="text-[#F5A3FF]/80">
                      {e.hookPhase} · {e.eventName} · {e.walletId} · score {e.score}
                    </span>
                    <span className="font-medium text-uni-pink">{e.decision}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </>
      ) : (
        <p className="mt-6 text-sm text-[#F5A3FF]/65">
          Run <span className="text-uni-pink">Get started</span> on the simulator to
          emit the first afterSwap / beforeSwap audit event.
        </p>
      )}
    </div>
  );
}
