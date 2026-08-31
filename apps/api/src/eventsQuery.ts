/**
 * Splits Event reads: A–D stay on the in-memory demo trail, E is chain logs only.
 */

import type { HookEvent, WalletId } from "./types.js";

export type EventSourceFilter = "demo" | "chain" | "all";

const WALLET_IDS: WalletId[] = ["A", "B", "C", "D", "E"];

function isWalletId(id: string): id is WalletId {
  return WALLET_IDS.includes(id as WalletId);
}

/**
 * Default source: E → chain, A–D → demo, otherwise the merged list.
 */
export function resolveEventSource(
  walletId: string,
  sourceRaw: string,
): EventSourceFilter {
  const source = sourceRaw.trim().toLowerCase();
  if (source === "demo" || source === "chain" || source === "all") return source;
  if (walletId === "E") return "chain";
  if (isWalletId(walletId)) return "demo";
  return "all";
}

/**
 * Union of the demo trail and chain logs. Same tx keeps one row; demo amount wins.
 */
export function mergeEventTrails(memory: HookEvent[], chain: HookEvent[]): HookEvent[] {
  const byId = new Map<string, HookEvent>();
  const byTx = new Map<string, HookEvent>();

  for (const e of chain) {
    byId.set(e.id, e);
    const tx = e.txHash ?? (e.id.startsWith("0x") ? e.id.split("-")[0] : "");
    if (tx) byTx.set(tx.toLowerCase(), e);
  }

  for (const e of memory) {
    const tx = (e.txHash ?? e.id).toLowerCase();
    const existing = byId.get(e.id) ?? (tx.startsWith("0x") ? byTx.get(tx) : undefined);
    if (!existing) {
      byId.set(e.id, e);
      continue;
    }
    if (e.amountUsd > 0 && existing.amountUsd === 0) {
      const merged = { ...existing, amountUsd: e.amountUsd };
      byId.set(existing.id, merged);
    }
  }

  return [...byId.values()].sort((a, b) => a.at.localeCompare(b.at));
}

/**
 * Picks demo memory, SwapObserved logs, or both, then filters by wallet.
 */
export function selectEventTrail(
  demo: HookEvent[],
  chain: HookEvent[],
  walletId: string,
  source: EventSourceFilter,
): HookEvent[] {
  let events: HookEvent[];
  if (source === "demo") {
    events = demo.filter((e) => e.source !== "chain");
  } else if (source === "chain") {
    events = chain.filter((e) => e.source === "chain");
  } else {
    events = mergeEventTrails(demo, chain);
  }

  if (isWalletId(walletId)) {
    events = events.filter((e) => e.walletId === walletId);
  }

  return events.sort((a, b) => a.at.localeCompare(b.at));
}
