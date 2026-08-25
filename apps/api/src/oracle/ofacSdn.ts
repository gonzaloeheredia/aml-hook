/**
 * Live OFAC SDN ETH-address set for the COA.
 *
 * The hook never fetches Treasury. This module downloads the public SDN export,
 * caches ETH/EVM addresses, and answers exact-address screens. Fail-open when
 * the list cannot be loaded: Layer 1 on the swap still fail-closes on the mapping.
 */

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ETH_ADDR = /0x[a-fA-F0-9]{40}(?![a-fA-F0-9])/g;
const DEFAULT_TTL_MS = 6 * 60 * 60 * 1000;
const FETCH_MS = 25_000;

/** Official OFAC SDN dumps (CSV first — smaller than SDN Advanced XML). */
export const OFAC_SDN_URLS = [
  "https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/SDN.CSV",
  "https://www.treasury.gov/ofac/downloads/sdn.csv",
  "https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/SDN.XML",
  "https://www.treasury.gov/ofac/downloads/sdn.xml",
] as const;

export type OfacSdnSnapshot = {
  ok: boolean;
  live: boolean;
  source: string;
  fetchedAt: string | null;
  publishedAt: string | null;
  addressCount: number;
  stale: boolean;
  error?: string;
};

type DiskCache = {
  source: string;
  fetchedAt: string;
  publishedAt: string | null;
  addresses: string[];
};

type MemoryCache = {
  snapshot: OfacSdnSnapshot;
  set: Set<string>;
  loadedAt: number;
};

let memory: MemoryCache | null = null;
let inflight: Promise<MemoryCache> | null = null;
let fetchImpl: typeof fetch = globalThis.fetch.bind(globalThis);

/**
 * True when the COA should hit Treasury. Tests default off (`OFAC_LIVE=0` implied).
 */
export function isOfacLiveEnabled(): boolean {
  if (process.env.OFAC_LIVE === "0") return false;
  if (process.env.npm_lifecycle_event === "test" && process.env.OFAC_LIVE !== "1") {
    return false;
  }
  return true;
}

function ttlMs(): number {
  const raw = Number(process.env.OFAC_SDN_TTL_MS);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_TTL_MS;
}

function cachePath(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  return join(here, "..", "..", ".cache", "ofac-sdn-eth.json");
}

/**
 * Replace fetch (unit tests). Pass `null` to restore.
 */
export function setOfacFetch(next: typeof fetch | null): void {
  fetchImpl = next ?? globalThis.fetch.bind(globalThis);
}

/**
 * Drop memory + optional disk cache so the next screen reloads.
 */
export function resetOfacSdnCache(opts?: { disk?: boolean }): void {
  memory = null;
  inflight = null;
  if (opts?.disk) {
    try {
      const path = cachePath();
      if (existsSync(path)) unlinkSync(path);
    } catch {
      /* ignore */
    }
  }
}

/**
 * Extract EVM addresses from an OFAC SDN CSV/XML/text dump.
 */
export function parseEthAddressesFromSdn(text: string): string[] {
  const set = new Set<string>();
  for (const match of text.matchAll(ETH_ADDR)) {
    set.add(match[0]!.toLowerCase());
  }
  return [...set];
}

function emptySnapshot(error: string, live: boolean): OfacSdnSnapshot {
  return {
    ok: false,
    live,
    source: "none",
    fetchedAt: null,
    publishedAt: null,
    addressCount: 0,
    stale: false,
    error,
  };
}

function snapshotFromDisk(disk: DiskCache, stale: boolean): MemoryCache {
  const set = new Set(disk.addresses.map((a) => a.toLowerCase()));
  return {
    set,
    loadedAt: Date.now(),
    snapshot: {
      ok: true,
      live: true,
      source: disk.source,
      fetchedAt: disk.fetchedAt,
      publishedAt: disk.publishedAt,
      addressCount: set.size,
      stale,
    },
  };
}

function readDisk(): DiskCache | null {
  try {
    const path = cachePath();
    if (!existsSync(path)) return null;
    const raw = readFileSync(path, "utf8").trim();
    if (!raw) return null;
    const parsed = JSON.parse(raw) as DiskCache;
    if (!Array.isArray(parsed.addresses) || !parsed.source || !parsed.fetchedAt) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

function writeDisk(disk: DiskCache): void {
  try {
    const path = cachePath();
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify(disk));
  } catch (err) {
    console.error("OFAC SDN disk cache write failed:", err instanceof Error ? err.message : err);
  }
}

async function downloadSdn(): Promise<DiskCache> {
  let lastError = "all OFAC SDN URLs failed";
  for (const url of OFAC_SDN_URLS) {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), FETCH_MS);
    try {
      const res = await fetchImpl(url, {
        signal: ac.signal,
        headers: {
          accept: "text/csv, application/xml, text/plain, */*",
          "user-agent": "aml-hook-coa/0.1 (Uniswap v4 AML Hook; OFAC SDN screening)",
        },
      });
      if (!res.ok) {
        lastError = `${url} → HTTP ${res.status}`;
        continue;
      }
      const text = await res.text();
      const addresses = parseEthAddressesFromSdn(text);
      if (addresses.length === 0) {
        lastError = `${url} → no ETH addresses parsed`;
        continue;
      }
      const publishedAt = res.headers.get("last-modified");
      return {
        source: url,
        fetchedAt: new Date().toISOString(),
        publishedAt: publishedAt ? new Date(publishedAt).toISOString() : null,
        addresses,
      };
    } catch (err) {
      lastError = `${url} → ${err instanceof Error ? err.message : String(err)}`;
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(lastError);
}

async function loadMemory(): Promise<MemoryCache> {
  if (!isOfacLiveEnabled()) {
    return {
      set: new Set(),
      loadedAt: Date.now(),
      snapshot: emptySnapshot("OFAC_LIVE=0", false),
    };
  }

  if (memory && Date.now() - memory.loadedAt < ttlMs() && memory.snapshot.ok) {
    return memory;
  }

  const disk = readDisk();
  if (disk) {
    const age = Date.now() - Date.parse(disk.fetchedAt);
    if (Number.isFinite(age) && age >= 0 && age < ttlMs()) {
      memory = snapshotFromDisk(disk, false);
      return memory;
    }
  }

  try {
    const fresh = await downloadSdn();
    if (process.env.npm_lifecycle_event !== "test") writeDisk(fresh);
    memory = snapshotFromDisk(fresh, false);
    return memory;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (disk && disk.addresses.length > 0) {
      memory = snapshotFromDisk(disk, true);
      memory.snapshot.error = message;
      return memory;
    }
    memory = {
      set: new Set(),
      loadedAt: Date.now(),
      snapshot: emptySnapshot(message, true),
    };
    return memory;
  }
}

async function ensureMemory(): Promise<MemoryCache> {
  if (inflight) return inflight;
  inflight = loadMemory().finally(() => {
    inflight = null;
  });
  return inflight;
}

/**
 * Cached SDN metadata without forcing a Treasury round-trip when memory is empty.
 */
export function getOfacSdnStatus(): OfacSdnSnapshot {
  if (memory) return memory.snapshot;
  if (!isOfacLiveEnabled()) return emptySnapshot("OFAC_LIVE=0", false);
  const disk = readDisk();
  if (disk) return snapshotFromDisk(disk, false).snapshot;
  return {
    ok: false,
    live: true,
    source: "none",
    fetchedAt: null,
    publishedAt: null,
    addressCount: 0,
    stale: false,
    error: "not_fetched",
  };
}

/**
 * Load (or refresh) the SDN ETH set and return status.
 */
export async function loadOfacSdn(): Promise<OfacSdnSnapshot> {
  const mem = await ensureMemory();
  return mem.snapshot;
}

/** Preferred live SDN ETH addresses (Garantex, still listed as of 2026). */
export const PREFERRED_SDN_ETH = [
  "0x7ff9cfad3877f21d41da833e2f775db0569ee3d9",
  "0x8dce2aac0de82bdcaf6b4373b79f94331b8e4995",
  "0xf4377eda661e04b6dda78969796ed31658d602d4",
] as const;

/**
 * Pick Wallet F's address from the live SDN set.
 * Prefers known Garantex ETH identifiers; otherwise the sorted first live address.
 */
export async function pickLiveSdnAddress(
  preferred: readonly string[] = PREFERRED_SDN_ETH,
): Promise<{ address: string; fromLiveList: boolean; preferredHit: boolean }> {
  const mem = await ensureMemory();
  const preferredNorm = preferred.map((a) => a.toLowerCase());
  if (mem.snapshot.ok && mem.set.size > 0) {
    for (const p of preferredNorm) {
      if (mem.set.has(p)) {
        return { address: p, fromLiveList: true, preferredHit: true };
      }
    }
    const first = [...mem.set].sort()[0]!;
    return { address: first, fromLiveList: true, preferredHit: false };
  }
  return {
    address: preferredNorm[0] ?? PREFERRED_SDN_ETH[0],
    fromLiveList: false,
    preferredHit: false,
  };
}

function normalize(address: string): string | null {
  const trimmed = address.trim().toLowerCase();
  if (!/^0x[a-f0-9]{40}$/.test(trimmed)) return null;
  return trimmed;
}

/**
 * Exact-address SDN screen. Does not write the chain.
 */
export async function screenOfacAddress(address: string): Promise<{
  snapshot: OfacSdnSnapshot;
  match: boolean;
  address: string;
}> {
  const normalized = normalize(address);
  const mem = await ensureMemory();
  return {
    snapshot: mem.snapshot,
    address: normalized ?? address,
    match: Boolean(normalized && mem.snapshot.ok && mem.set.has(normalized)),
  };
}
