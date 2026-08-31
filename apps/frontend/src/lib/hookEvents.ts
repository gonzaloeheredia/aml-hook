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
  /** Human-readable fee, e.g. "0.30%" or "n/a" */
  fee: string;
  feeBps: number;
  amountUsd: number;
  hopDistance: number | null;
  origin: string;
  timestamp: string;
  txHash: string;
  blockNumber: number;
  source?: "chain" | "demo";
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
    fee: blocked ? "n/a" : `${(demoCase.appliedFeeBps / 100).toFixed(2)}%`,
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
 * Maps a backend HookEvent into the frontend audit-trail shape.
 */
export function hookEventFromApi(
  event: {
    id: string;
    walletId: DemoCaseId;
    address: string;
    score: number;
    decision: "ALLOW" | "FEE_OVERRIDE" | "REVERT";
    feeBps: number;
    amountUsd: number;
    hopDistance: number | null;
    origin: string;
    at: string;
    kind: "SwapObserved" | "WalletBlocked";
    txHash?: string;
    blockNumber?: number;
    source?: "chain" | "demo";
  },
  eventIndex: number,
): HookChainEvent {
  const blocked = event.kind === "WalletBlocked";
  const tx = event.txHash && event.txHash.startsWith("0x")
    ? event.txHash
    : fakeTxHash(event.address, eventIndex);
  return {
    id: event.id,
    hookPhase: blocked ? "beforeSwap" : "afterSwap",
    eventName: event.kind,
    walletId: event.walletId,
    address: event.address,
    score: event.score,
    decision: event.decision,
    fee: blocked ? "n/a" : `${(event.feeBps / 100).toFixed(2)}%`,
    feeBps: event.feeBps,
    amountUsd: event.amountUsd,
    hopDistance: event.hopDistance,
    origin: event.origin,
    timestamp: event.at,
    txHash: tx,
    blockNumber: event.blockNumber ?? 22_814_500 + eventIndex * 17,
    source: event.source,
  };
}

/**
 * Union by id so a later empty GET /events does not wipe a swap just recorded.
 */
export function mergeHookEvents(
  prev: HookChainEvent[],
  incoming: HookChainEvent[],
): HookChainEvent[] {
  const byId = new Map(prev.map((e) => [e.id, e]));
  for (const e of incoming) byId.set(e.id, e);
  return [...byId.values()];
}

/**
 * Pretty-print the afterSwap payload (use-case fields).
 * `amount_usdc` is the swap notional in USDC.
 */
export function formatEventPayload(event: HookChainEvent): string {
  const lines = [
    `  address: ${event.address}`,
    `  score: ${event.score}`,
    `  decision: ${event.decision}`,
    `  fee: ${event.fee}`,
    `  amount_usdc: ${
      event.source === "chain" && event.amountUsd === 0
        ? "n/a"
        : event.amountUsd
    }`,
  ];
  if (event.hopDistance != null) {
    lines.push(`  hop_distance: ${event.hopDistance}`);
  }
  if (event.origin && event.origin !== "n/a") {
    lines.push(`  origin: ${event.origin}`);
  }
  lines.push(`  timestamp: ${event.timestamp}`);
  if (event.txHash.startsWith("0x") && event.txHash.length >= 66) {
    lines.push(`  tx: ${event.txHash}`);
  }
  return `{\n${lines.join(",\n")}\n}`;
}
