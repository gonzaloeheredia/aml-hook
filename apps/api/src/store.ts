/**
 * MOCK in-memory demo store (not on-chain state).
 * Holds wallets, P2P transfers, and hook events for the guided UI.
 * State is lost when the process restarts (no database).
 * On-chain scores live in ComplianceOracle when the keeper publishes via RPC.
 */

import { DEMO_WALLETS } from "./chain/accounts.js";
import { EXPLOIT_SOURCE } from "./scoring.js";
import type { HookEvent, TransferRecord, Wallet, WalletId } from "./types.js";

/**
 * Builds the initial A–E wallet ledger from the use case:
 * A = exploit origin (score 100, not OFAC-listed); B and C start clean (symmetric N-hop);
 * D = published score 0 (already-held funds ALLOW; clean C→D is inflow, not a hop);
 * E = unknown, starts empty (fund from C).
 */
function seedWallets(): Record<WalletId, Wallet> {
  return {
    A: {
      id: "A",
      accountLabel: "Account A · Exploit",
      role: "Confirmed exploit — score 100 · WalletBlocked on pool; P2P can still contaminate B/C/D",
      address: DEMO_WALLETS.A.address,
      usdc: 10_000_000,
      eth: 5,
      hopDistance: 0,
      originId: "A",
      exploitConfirmed: true,
      neverScored: false,
    },
    B: {
      id: "B",
      accountLabel: "Account B · Clean",
      role: "Clean wallet — A→B = 1-hop (~65); tainted C→B = 2-hop (~42)",
      address: DEMO_WALLETS.B.address,
      usdc: 25_000,
      eth: 4,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: false,
    },
    C: {
      id: "C",
      accountLabel: "Account C · Clean",
      role: "Clean wallet — fund E (unknown) or D (inflow); A→C = 1-hop (~65)",
      address: DEMO_WALLETS.C.address,
      usdc: 50_000,
      eth: 8,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: false,
    },
    D: {
      id: "D",
      accountLabel: "Account D · Score 0",
      role: "Published score 0 — ALLOW on already-held funds; clean C→D → inflow by size (no hop)",
      address: DEMO_WALLETS.D.address,
      usdc: 5_000,
      eth: 2,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: false,
    },
    E: {
      id: "E",
      accountLabel: "Account E · Unknown",
      role: "Unknown wallet — starts empty. Fund from clean C (no hop). Floor A/D by bag and swap size",
      address: DEMO_WALLETS.E.address,
      usdc: 0,
      eth: 1,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: true,
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
  /** Demo clock when lastKnownUsdc was last written (D: score newer than this clears inflow). */
  lastKnownAt: Record<WalletId, number>;
  /** Recipients awaiting deferred keeper updateScore (Wallet D demo). */
  keeperPending: Set<WalletId>;
  /** Last keeper write time (ms), demo clock. Missing = never written. */
  lastScoreAt: Partial<Record<WalletId, number>>;
  /** Rolling 1-hour pool activity (Floor B ops + hour USD). */
  activity: Record<WalletId, { windowStart: number; ops: number; windowUsd: number }>;
  /** Rolling 24-hour USD (Floor C, BSA CTR-style aggregation). */
  daily: Record<WalletId, { windowStart: number; usd: number }>;
  /** Shift applied to Date.now() so Mitigation B can be exercised without waiting. */
  demoOffsetMs: number;
  /** Governor-bound USDC/USD feed. False → lastFx if quoted in the last 24h, else MagnitudeQuoteFailed. */
  priceFeedBound: boolean;
};

export type WalletActivity = { windowStart: number; ops: number; windowUsd: number };
export type DailyActivity = { windowStart: number; usd: number };

const EMPTY_ACTIVITY: WalletActivity = { windowStart: 0, ops: 0, windowUsd: 0 };
const EMPTY_DAILY: DailyActivity = { windowStart: 0, usd: 0 };

export const ACTIVITY_WINDOW_MS = 3_600_000;
/** Floor C — BSA CTR-style 24-hour USD aggregation. */
export const DAILY_WINDOW_MS = 86_400_000;
/** Floor B: same window as `AmlHookLogic.DEFAULT_STALENESS` (5 minutes). */
export const STALENESS_MS = 300_000;

function seedLastKnown(wallets: Record<WalletId, Wallet>): Record<WalletId, number> {
  return {
    A: wallets.A.usdc,
    B: wallets.B.usdc,
    C: wallets.C.usdc,
    D: wallets.D.usdc,
    E: wallets.E.usdc,
  };
}

function seedActivity(): Record<WalletId, WalletActivity> {
  return {
    A: { ...EMPTY_ACTIVITY },
    B: { ...EMPTY_ACTIVITY },
    C: { ...EMPTY_ACTIVITY },
    D: { ...EMPTY_ACTIVITY },
    E: { ...EMPTY_ACTIVITY },
  };
}

function seedDaily(): Record<WalletId, DailyActivity> {
  return {
    A: { ...EMPTY_DAILY },
    B: { ...EMPTY_DAILY },
    C: { ...EMPTY_DAILY },
    D: { ...EMPTY_DAILY },
    E: { ...EMPTY_DAILY },
  };
}

function seedLastScoreAt(): Partial<Record<WalletId, number>> {
  const t = Date.now();
  return { A: t, B: t, C: t, D: t };
}

function seedLastKnownAt(): Record<WalletId, number> {
  const t = Date.now();
  return { A: t, B: t, C: t, D: t, E: t };
}

/** Mutable singleton store for the demo API. */
let store: Store = {
  wallets: seedWallets(),
  transfers: [],
  events: [],
  lastKnownUsdc: seedLastKnown(seedWallets()),
  lastKnownAt: seedLastKnownAt(),
  keeperPending: new Set(),
  lastScoreAt: seedLastScoreAt(),
  activity: seedActivity(),
  daily: seedDaily(),
  demoOffsetMs: 0,
  priceFeedBound: true,
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
    lastKnownAt: seedLastKnownAt(),
    keeperPending: new Set(),
    lastScoreAt: seedLastScoreAt(),
    activity: seedActivity(),
    daily: seedDaily(),
    demoOffsetMs: 0,
    priceFeedBound: true,
  };
  return store;
}

/** Demo clock (real now + offset from POST /demo/elapse). */
export function demoNow(): number {
  return Date.now() + store.demoOffsetMs;
}

/** Advance the demo clock (Floor B: 301s makes a published score stale). */
export function elapseDemo(ms: number): number {
  store.demoOffsetMs += Math.max(0, ms);
  return demoNow();
}

export function isPriceFeedBound(): boolean {
  return store.priceFeedBound;
}

export function setPriceFeedBound(bound: boolean): void {
  store.priceFeedBound = bound;
}

export function getLastScoreAt(id: WalletId): number | null {
  return store.lastScoreAt[id] ?? null;
}

export function touchScoreAt(id: WalletId): void {
  store.lastScoreAt[id] = demoNow();
}

export function getActivity(id: WalletId): WalletActivity {
  const raw = store.activity[id] ?? { ...EMPTY_ACTIVITY };
  if (raw.windowStart === 0) return raw;
  if (demoNow() >= raw.windowStart + ACTIVITY_WINDOW_MS) {
    store.activity[id] = { ...EMPTY_ACTIVITY };
    return store.activity[id];
  }
  return raw;
}

export function getDaily(id: WalletId): DailyActivity {
  const raw = store.daily[id] ?? { ...EMPTY_DAILY };
  if (raw.windowStart === 0) return raw;
  if (demoNow() >= raw.windowStart + DAILY_WINDOW_MS) {
    store.daily[id] = { ...EMPTY_DAILY };
    return store.daily[id];
  }
  return raw;
}

/** afterSwap: increment 1-hour ops/USD and 24-hour Floor C USD (USDC = $1 in the demo). */
export function recordAfterSwap(id: WalletId, usd: number): WalletActivity {
  const now = demoNow();
  const cur = getActivity(id);
  const next: WalletActivity =
    cur.windowStart === 0
      ? { windowStart: now, ops: 1, windowUsd: usd }
      : {
          windowStart: cur.windowStart,
          ops: cur.ops + 1,
          windowUsd: cur.windowUsd + usd,
        };
  store.activity[id] = next;
  const day = getDaily(id);
  store.daily[id] =
    day.windowStart === 0
      ? { windowStart: now, usd }
      : { windowStart: day.windowStart, usd: day.usd + usd };
  return next;
}

export function dailyUsd(id: WalletId): number {
  return getDaily(id).usd;
}

export function opsInCurrentWindow(id: WalletId): number {
  return getActivity(id).ops;
}

export function windowUsd(id: WalletId): number {
  return getActivity(id).windowUsd;
}

export function isScoreStale(id: WalletId): boolean {
  const at = getLastScoreAt(id);
  if (at == null) return true;
  return demoNow() > at + STALENESS_MS;
}

/**
 * Returns wallets A–E as an array.
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
  store.lastKnownAt[id] = demoNow();
}

/** When the inflow baseline was last written (ms, demo clock). */
export function getLastKnownAt(id: WalletId): number {
  return store.lastKnownAt[id] ?? 0;
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
