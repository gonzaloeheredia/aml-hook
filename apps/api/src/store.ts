/**
 * MOCK in-memory demo store (not on-chain state).
 * Holds wallets, P2P transfers, and hook events for the guided UI.
 * State is lost when the process restarts (no database).
 * On-chain scores live in ComplianceOracle when the keeper publishes via RPC.
 */

import { EXPLOIT_SOURCE } from "./scoring.js";
import type { HookEvent, TransferRecord, Wallet, WalletId } from "./types.js";

/**
 * Builds the initial A/B/C/D wallet ledger from the use case:
 * A = exploit source; B and C start clean (symmetric N-hop);
 * D starts clean with 0 USDC — latency / inflow path (Wallet D §7).
 */
function seedWallets(): Record<WalletId, Wallet> {
  return {
    A: {
      id: "A",
      accountLabel: "Account A · Exploit",
      role: "Exploit attacker — REVERT on pool; contaminates B, C, or D via P2P",
      address: "0x8576aCC5C05D6Ce88f4e49bf65BdF0C62F91353C",
      usdc: 10_000_000,
      eth: 5,
      hopDistance: 0,
      originId: "A",
      exploitConfirmed: true,
    },
    B: {
      id: "B",
      accountLabel: "Account B · Clean",
      role: "Clean wallet — A→B = 1-hop (~65); tainted C→B = 2-hop (~42)",
      address: "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD",
      usdc: 25_000,
      eth: 4,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
    },
    C: {
      id: "C",
      accountLabel: "Account C · Clean",
      role: "Clean wallet — A→C = 1-hop (~65); tainted B→C = 2-hop (~42)",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      usdc: 50_000,
      eth: 8,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
    },
    D: {
      id: "D",
      accountLabel: "Account D · Clean",
      role: "Latency path — A→D then swap before keeper → inflow FEE_OVERRIDE 8%",
      address: "0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97",
      usdc: 0,
      eth: 2,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
    },
  };
}

/** Shape of the process-wide in-memory state. */
type Store = {
  wallets: Record<WalletId, Wallet>;
  transfers: TransferRecord[];
  events: HookEvent[];
  /** Inflow heuristic baseline (USDC) per wallet — refreshed afterSwap. */
  lastKnownUsdc: Record<WalletId, number>;
  /** Recipients awaiting deferred keeper updateScore (Wallet D demo). */
  keeperPending: Set<WalletId>;
};

function seedLastKnown(wallets: Record<WalletId, Wallet>): Record<WalletId, number> {
  return {
    A: wallets.A.usdc,
    B: wallets.B.usdc,
    C: wallets.C.usdc,
    D: wallets.D.usdc,
  };
}

/** Mutable singleton store for the demo API. */
let store: Store = {
  wallets: seedWallets(),
  transfers: [],
  events: [],
  lastKnownUsdc: seedLastKnown(seedWallets()),
  keeperPending: new Set(),
};

/**
 * Returns a reference to the current store (wallets + histories).
 */
export function getStore(): Store {
  return store;
}

/**
 * Resets the demo to the use-case baseline
 * (seeded wallets, empty transfers and events).
 */
export function resetStore(): Store {
  const wallets = seedWallets();
  store = {
    wallets,
    transfers: [],
    events: [],
    lastKnownUsdc: seedLastKnown(wallets),
    keeperPending: new Set(),
  };
  return store;
}

/**
 * Returns wallets A–D as an array.
 */
export function listWallets(): Wallet[] {
  return (Object.keys(store.wallets) as WalletId[]).map((id) => store.wallets[id]);
}

/**
 * Looks up a wallet by id. Returns null if missing.
 */
export function getWallet(id: WalletId): Wallet | null {
  return store.wallets[id] ?? null;
}

/**
 * Replaces the full wallet map (after a transfer or swap settlement).
 */
export function setWallets(next: Record<WalletId, Wallet>): void {
  store.wallets = next;
}

/**
 * Appends a P2P transfer record to the history.
 */
export function appendTransfer(record: TransferRecord): void {
  store.transfers.push(record);
}

/**
 * Returns a copy of the P2P transfer history.
 */
export function listTransfers(): TransferRecord[] {
  return [...store.transfers];
}

/**
 * Appends a hook event (SwapObserved or WalletBlocked) to the trail.
 */
export function appendEvent(event: HookEvent): void {
  store.events.push(event);
}

/**
 * Returns a copy of the simulated on-chain event trail.
 */
export function listEvents(): HookEvent[] {
  return [...store.events];
}

/** Last observed USDC balance used by the §3.8 inflow heuristic. */
export function getLastKnownUsdc(id: WalletId): number {
  return store.lastKnownUsdc[id] ?? 0;
}

/** Refresh inflow baseline after a successful swap (afterSwap). */
export function setLastKnownUsdc(id: WalletId, usdc: number): void {
  store.lastKnownUsdc[id] = usdc;
}

/** Mark that the keeper has not yet published a post-transfer score. */
export function markKeeperPending(id: WalletId): void {
  store.keeperPending.add(id);
}

/** Clear deferred-keeper flag after catch-up publish. */
export function clearKeeperPending(id: WalletId): void {
  store.keeperPending.delete(id);
}

/** True while updateScore for this wallet is intentionally deferred. */
export function isKeeperPending(id: WalletId): boolean {
  return store.keeperPending.has(id);
}

export { EXPLOIT_SOURCE };
