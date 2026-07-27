import type { DemoCase, DemoCaseId } from "@/data/cases";

/**
 * On-chain audit event shaped like the use-case afterSwap emit:
 * { address, score, decision, fee, amount, hop_distance?, origin?, timestamp }
 *
 * REVERT is recorded as a beforeSwap WalletBlocked (afterSwap never runs).
 */
export type HookChainEvent = {
  id: string;
  /** Lifecycle phase that emitted the event */
  hookPhase: "afterSwap" | "beforeSwap";
  /** Solidity-style event name */
  eventName: "SwapObserved" | "WalletBlocked";
  walletId: DemoCaseId;
  address: string;
  score: number;
  decision: "ALLOW" | "FEE_OVERRIDE" | "REVERT";
  /** Human-readable fee, e.g. "0.30%" or "—" */
  fee: string;
  feeBps: number;
  amountUsd: number;
  hopDistance: number | null;
  origin: string;
  timestamp: string;
  txHash: string;
  blockNumber: number;
};

/**
 * Builds a deterministic demo tx hash for the simulated emit.
 */
function fakeTxHash(address: string, index: number) {
  const seed = `${address}-${index}`.replace(/[^a-fA-F0-9]/g, "");
  const hex = (seed + "c0ffeeabad1dea").slice(0, 40).padEnd(40, "0");
  return `0x${hex}`;
}

/**
 * Creates the audit-trail event that the hook would emit for this swap attempt.
 * - ALLOW / FEE_OVERRIDE → afterSwap · SwapObserved
 * - REVERT → beforeSwap · WalletBlocked (no afterSwap)
 */
export function buildHookChainEvent(args: {
  demoCase: DemoCase;
  walletId: DemoCaseId;
  address: string;
  eventIndex: number;
}): HookChainEvent {
  const { demoCase, walletId, address, eventIndex } = args;
  const blocked = demoCase.decision === "block";
  const decision =
    demoCase.decision === "block"
      ? "REVERT"
      : demoCase.decision === "fee_override"
        ? "FEE_OVERRIDE"
        : "ALLOW";

  return {
    id: `evt-${Date.now()}-${eventIndex}`,
    hookPhase: blocked ? "beforeSwap" : "afterSwap",
    eventName: blocked ? "WalletBlocked" : "SwapObserved",
    walletId,
    address,
    score: demoCase.score,
    decision,
    fee: blocked ? "—" : `${(demoCase.appliedFeeBps / 100).toFixed(2)}%`,
    feeBps: blocked ? 0 : demoCase.appliedFeeBps,
    amountUsd: demoCase.activity.amountUsd,
    hopDistance: demoCase.activity.hopDistance,
    origin: demoCase.activity.origin,
    timestamp: new Date().toISOString(),
    txHash: fakeTxHash(address, eventIndex),
    blockNumber: 22_814_500 + eventIndex * 17,
  };
}

/**
 * Pretty-print the event as the JSON-ish payload from the use-case PDF.
 */
export function formatEventPayload(event: HookChainEvent): string {
  const hop =
    event.hopDistance == null ? "" : `,\n  hop_distance: ${event.hopDistance}`;
  const origin =
    !event.origin || event.origin === "—"
      ? ""
      : `,\n  origin: ${event.origin}`;
  return `{
  address: ${event.address.slice(0, 6)}…${event.address.slice(-4)},
  score: ${event.score},
  decision: ${event.decision},
  fee: ${event.fee},
  amount: ${event.amountUsd}${hop}${origin},
  timestamp: ${event.timestamp}
}`;
}
