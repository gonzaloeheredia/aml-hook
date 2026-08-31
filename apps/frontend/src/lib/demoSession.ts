/**
 * sessionStorage snapshot for the AML Hook guided demo.
 * Survives reload / new tab in the same browser session; clears when the
 * browser session ends or the user clicks Restart data.
 */

import type { DemoCaseId } from "@/data/cases";
import type { ApiCompliancePack } from "@/lib/api";
import type { DemoStage } from "@/components/StageRail";
import {
  initialSimWallets,
  isBoundWalletE,
  type SimWallet,
  type SimWalletId,
  type TransferRecord,
} from "@/lib/hopScoring";
import type { HookChainEvent } from "@/lib/hookEvents";

export const DEMO_SESSION_KEY = "aml-hook.demo.session";
const LEGACY_PROGRESS_KEY = "aml-hook-demo-progress";

export type SwapStats = { count: number; tradedUsd: number; tradedEth: number };

export const WALLET_IDS: DemoCaseId[] = ["A", "B", "C", "D", "E"];

export const EMPTY_STATS: Record<DemoCaseId, SwapStats> = {
  A: { count: 0, tradedUsd: 0, tradedEth: 0 },
  B: { count: 0, tradedUsd: 0, tradedEth: 0 },
  C: { count: 0, tradedUsd: 0, tradedEth: 0 },
  D: { count: 0, tradedUsd: 0, tradedEth: 0 },
  E: { count: 0, tradedUsd: 0, tradedEth: 0 },
};

export const EMPTY_UNLOCK: Record<DemoCaseId, DemoStage> = {
  A: "swap",
  B: "swap",
  C: "swap",
  D: "swap",
  E: "swap",
};

export const STAGE_ORDER: DemoStage[] = [
  "swap",
  "hook",
  "fees",
  "stats",
  "opinion",
  "event",
];

export type DemoSessionSnapshot = {
  v: 1;
  simWallets: Record<SimWalletId, SimWallet>;
  transfers: TransferRecord[];
  chainEvents: HookChainEvent[];
  swapStats: Record<DemoCaseId, SwapStats>;
  complianceByWallet: Partial<Record<DemoCaseId, ApiCompliancePack>>;
  unlockByWallet: Record<DemoCaseId, DemoStage>;
  caseId: DemoCaseId;
  connected: boolean;
  swapAmountUsd: number;
  stage: DemoStage;
};

function isWalletId(value: unknown): value is DemoCaseId {
  return (
    value === "A" ||
    value === "B" ||
    value === "C" ||
    value === "D" ||
    value === "E"
  );
}

function isStage(value: unknown): value is DemoStage {
  return typeof value === "string" && STAGE_ORDER.includes(value as DemoStage);
}

function asNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function asNullableNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/**
 * Copies only public SimWallet ledger fields (never keys or faucet secrets).
 */
function sanitizeWallet(raw: unknown, seed: SimWallet): SimWallet {
  if (!raw || typeof raw !== "object") return seed;
  const w = raw as Partial<SimWallet>;
  return {
    id: seed.id,
    accountLabel:
      typeof w.accountLabel === "string" ? w.accountLabel : seed.accountLabel,
    role: typeof w.role === "string" ? w.role : seed.role,
    address: typeof w.address === "string" ? w.address : seed.address,
    usdc: asNumber(w.usdc, seed.usdc),
    eth: asNumber(w.eth, seed.eth),
    hopDistance:
      w.hopDistance === null
        ? null
        : w.hopDistance === undefined
          ? seed.hopDistance
          : asNullableNumber(w.hopDistance),
    originId: isWalletId(w.originId) ? w.originId : w.originId === null ? null : seed.originId,
    exploitConfirmed: Boolean(w.exploitConfirmed ?? seed.exploitConfirmed),
    keeperPending: w.keeperPending,
    lastKnownUsdc: w.lastKnownUsdc,
    neverScored: w.neverScored,
    opsInWindow: w.opsInWindow,
    windowUsd: w.windowUsd,
    windowStart: w.windowStart,
    dailyUsd: w.dailyUsd,
    dailyStart: w.dailyStart,
    lastScoreAt: w.lastScoreAt,
    lastKnownAt: w.lastKnownAt,
  };
}

function sanitizeStats(raw: unknown): Record<DemoCaseId, SwapStats> {
  const out = { ...EMPTY_STATS };
  if (!raw || typeof raw !== "object") return out;
  const rec = raw as Partial<Record<DemoCaseId, Partial<SwapStats>>>;
  for (const id of WALLET_IDS) {
    const row = rec[id];
    if (!row) continue;
    out[id] = {
      count: Math.max(0, asNumber(row.count, 0)),
      tradedUsd: Math.max(0, asNumber(row.tradedUsd, 0)),
      tradedEth: Math.max(0, asNumber(row.tradedEth, 0)),
    };
  }
  return out;
}

function sanitizeUnlock(raw: unknown): Record<DemoCaseId, DemoStage> {
  const out = { ...EMPTY_UNLOCK };
  if (!raw || typeof raw !== "object") return out;
  const rec = raw as Partial<Record<DemoCaseId, unknown>>;
  for (const id of WALLET_IDS) {
    if (isStage(rec[id])) out[id] = rec[id];
  }
  return out;
}

function sanitizeWallets(raw: unknown): Record<SimWalletId, SimWallet> {
  const seed = initialSimWallets();
  if (!raw || typeof raw !== "object") return seed;
  const rec = raw as Partial<Record<SimWalletId, unknown>>;
  const out = { ...seed };
  for (const id of WALLET_IDS) {
    out[id] = sanitizeWallet(rec[id], seed[id]);
  }
  if (!isBoundWalletE(out.E.address)) {
    out.E = { ...seed.E };
  } else {
    out.E = { ...out.E, usdc: 0, eth: 0, neverScored: true };
  }
  return out;
}

function sanitizeTransfers(raw: unknown): TransferRecord[] {
  if (!Array.isArray(raw)) return [];
  const out: TransferRecord[] = [];
  for (const row of raw) {
    if (!row || typeof row !== "object") continue;
    const t = row as Partial<TransferRecord>;
    if (!isWalletId(t.from) || !isWalletId(t.to)) continue;
    if (typeof t.id !== "string" || typeof t.at !== "string") continue;
    out.push({
      id: t.id,
      from: t.from,
      to: t.to,
      amountUsd: asNumber(t.amountUsd, 0),
      at: t.at,
      resultingScore: asNumber(t.resultingScore, 0),
      hopDistance: asNumber(t.hopDistance, 0),
    });
  }
  return out;
}

function sanitizeEvents(raw: unknown): HookChainEvent[] {
  if (!Array.isArray(raw)) return [];
  const out: HookChainEvent[] = [];
  for (const row of raw) {
    if (!row || typeof row !== "object") continue;
    const e = row as Partial<HookChainEvent>;
    if (typeof e.id !== "string" || !isWalletId(e.walletId)) continue;
    if (e.eventName !== "SwapObserved" && e.eventName !== "WalletBlocked") {
      continue;
    }
    out.push(e as HookChainEvent);
  }
  return out;
}

function sanitizeComplianceMap(
  raw: unknown,
): Partial<Record<DemoCaseId, ApiCompliancePack>> {
  if (!raw || typeof raw !== "object") return {};
  const rec = raw as Partial<Record<DemoCaseId, ApiCompliancePack>>;
  const out: Partial<Record<DemoCaseId, ApiCompliancePack>> = {};
  for (const id of WALLET_IDS) {
    const pack = rec[id];
    if (!pack || typeof pack !== "object") continue;
    if (pack.walletId !== id) continue;
    if (typeof pack.address !== "string") continue;
    out[id] = pack;
  }
  return out;
}

/**
 * True when the API trail is behind the local session (Railway memory wiped).
 */
export function railwayLooksStale(
  localEvents: HookChainEvent[],
  apiEvents: HookChainEvent[],
  localTransfers: TransferRecord[],
  apiTransfers: TransferRecord[],
): boolean {
  if (localTransfers.length > apiTransfers.length) return true;
  if (localEvents.length > apiEvents.length) return true;
  const apiEventIds = new Set(apiEvents.map((e) => e.id));
  if (localEvents.some((e) => !apiEventIds.has(e.id))) return true;
  const apiTxIds = new Set(apiTransfers.map((t) => t.id));
  if (localTransfers.some((t) => !apiTxIds.has(t.id))) return true;
  return false;
}

/**
 * Union transfers by id so an empty GET /transfers cannot wipe P2P history.
 */
export function mergeTransfers(
  prev: TransferRecord[],
  incoming: TransferRecord[],
): TransferRecord[] {
  const byId = new Map(prev.map((t) => [t.id, t]));
  for (const t of incoming) byId.set(t.id, t);
  return [...byId.values()];
}

function closerHop(
  a: number | null | undefined,
  b: number | null | undefined,
): number | null {
  if (a == null) return b ?? null;
  if (b == null) return a;
  return Math.min(a, b);
}

/**
 * On-chain USDC/ETH from GET /wallets win. Hop / contamination overlay is
 * kept from the session when Railway looks like a fresh (empty) process.
 */
export function mergeSimWallets(
  local: Record<SimWalletId, SimWallet>,
  api: Record<SimWalletId, SimWallet>,
  staleApi: boolean,
): Record<SimWalletId, SimWallet> {
  const out = { ...api };
  for (const id of WALLET_IDS) {
    const a = api[id];
    const l = local[id];
    if (!a) continue;
    if (id === "E") {
      const bound = isBoundWalletE(a.address)
        ? a.address
        : isBoundWalletE(l?.address)
          ? l.address
          : "";
      out[id] = {
        ...a,
        address: bound,
        usdc: 0,
        eth: 0,
        neverScored: true,
      };
      continue;
    }
    if (!staleApi || !l) {
      out[id] = a;
      continue;
    }
    const hop = closerHop(l.hopDistance, a.hopDistance);
    const keepLocalHop = l.hopDistance != null && a.hopDistance == null;
    out[id] = {
      ...a,
      usdc: a.usdc,
      eth: a.eth,
      hopDistance: hop,
      originId: l.originId ?? a.originId,
      exploitConfirmed: Boolean(l.exploitConfirmed || a.exploitConfirmed),
      keeperPending: l.keeperPending ?? a.keeperPending,
      neverScored: a.neverScored,
      lastKnownUsdc: l.lastKnownUsdc ?? a.lastKnownUsdc,
      lastScoreAt: l.lastScoreAt ?? a.lastScoreAt,
      lastKnownAt: l.lastKnownAt ?? a.lastKnownAt,
      opsInWindow: Math.max(l.opsInWindow ?? 0, a.opsInWindow ?? 0),
      windowUsd: Math.max(l.windowUsd ?? 0, a.windowUsd ?? 0),
      windowStart: l.windowStart ?? a.windowStart,
      dailyUsd: Math.max(l.dailyUsd ?? 0, a.dailyUsd ?? 0),
      dailyStart: l.dailyStart ?? a.dailyStart,
      accountLabel: keepLocalHop ? l.accountLabel : a.accountLabel,
      role: keepLocalHop ? l.role : a.role,
    };
  }
  return out;
}

/**
 * Prefer the pack that still reflects hop / score when Railway reseeds.
 * Matching hop+score keeps the API pack (fresher opinion copy).
 */
export function preferFresherCompliance(
  cached: ApiCompliancePack | undefined,
  incoming: ApiCompliancePack,
): ApiCompliancePack {
  if (!cached || cached.walletId !== incoming.walletId) return incoming;
  const cachedHop = cached.hopDistance;
  const inHop = incoming.hopDistance;
  if (cachedHop != null && inHop == null) return cached;
  if (cached.score > incoming.score) return cached;
  return incoming;
}

function parseLegacyProgress(raw: string): DemoSessionSnapshot | null {
  try {
    const parsed = JSON.parse(raw) as {
      stats?: unknown;
      unlock?: unknown;
    };
    return {
      v: 1,
      simWallets: initialSimWallets(),
      transfers: [],
      chainEvents: [],
      swapStats: sanitizeStats(parsed.stats),
      complianceByWallet: {},
      unlockByWallet: sanitizeUnlock(parsed.unlock),
      caseId: "A",
      connected: false,
      swapAmountUsd: 0,
      stage: "swap",
    };
  } catch {
    return null;
  }
}

function parseSnapshot(raw: string): DemoSessionSnapshot | null {
  try {
    const parsed = JSON.parse(raw) as Partial<DemoSessionSnapshot> & {
      stats?: unknown;
      unlock?: unknown;
    };
    if (parsed && parsed.v === 1 && parsed.simWallets) {
      const caseId = isWalletId(parsed.caseId) ? parsed.caseId : "A";
      const unlockByWallet = sanitizeUnlock(parsed.unlockByWallet);
      const stage = isStage(parsed.stage) ? parsed.stage : "swap";
      const unlock = unlockByWallet[caseId];
      const clampedStage =
        STAGE_ORDER.indexOf(stage) <= STAGE_ORDER.indexOf(unlock)
          ? stage
          : unlock;
      return {
        v: 1,
        simWallets: sanitizeWallets(parsed.simWallets),
        transfers: sanitizeTransfers(parsed.transfers),
        chainEvents: sanitizeEvents(parsed.chainEvents),
        swapStats: sanitizeStats(parsed.swapStats),
        complianceByWallet: sanitizeComplianceMap(parsed.complianceByWallet),
        unlockByWallet,
        caseId,
        connected: Boolean(parsed.connected),
        swapAmountUsd: asNumber(parsed.swapAmountUsd, 0),
        stage: clampedStage,
      };
    }
    if (parsed?.stats || parsed?.unlock) {
      return parseLegacyProgress(raw);
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Reads the compact demo snapshot (or the older progress-only key).
 */
export function loadDemoSession(): DemoSessionSnapshot | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = sessionStorage.getItem(DEMO_SESSION_KEY);
    if (raw) {
      const snap = parseSnapshot(raw);
      if (snap) return snap;
    }
    const legacy = sessionStorage.getItem(LEGACY_PROGRESS_KEY);
    if (!legacy) return null;
    const migrated = parseLegacyProgress(legacy);
    if (migrated) {
      saveDemoSession(migrated);
      sessionStorage.removeItem(LEGACY_PROGRESS_KEY);
    }
    return migrated;
  } catch {
    return null;
  }
}

/**
 * Writes the snapshot. Strips unknown keys so secrets never land in storage.
 */
export function saveDemoSession(snap: DemoSessionSnapshot): void {
  if (typeof window === "undefined") return;
  try {
    const safe: DemoSessionSnapshot = {
      v: 1,
      simWallets: sanitizeWallets(snap.simWallets),
      transfers: sanitizeTransfers(snap.transfers),
      chainEvents: sanitizeEvents(snap.chainEvents),
      swapStats: sanitizeStats(snap.swapStats),
      complianceByWallet: sanitizeComplianceMap(snap.complianceByWallet),
      unlockByWallet: sanitizeUnlock(snap.unlockByWallet),
      caseId: isWalletId(snap.caseId) ? snap.caseId : "A",
      connected: Boolean(snap.connected),
      swapAmountUsd: asNumber(snap.swapAmountUsd, 0),
      stage: isStage(snap.stage) ? snap.stage : "swap",
    };
    sessionStorage.setItem(DEMO_SESSION_KEY, JSON.stringify(safe));
    sessionStorage.removeItem(LEGACY_PROGRESS_KEY);
  } catch {
    /* quota / private mode */
  }
}

/** Clears both the current key and the legacy progress key. */
export function clearDemoSession(): void {
  if (typeof window === "undefined") return;
  try {
    sessionStorage.removeItem(DEMO_SESSION_KEY);
    sessionStorage.removeItem(LEGACY_PROGRESS_KEY);
  } catch {
    /* ignore */
  }
}
