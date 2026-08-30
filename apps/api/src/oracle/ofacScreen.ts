/**
 * COA OFAC screen: live SDN lookup + SanctionRegistry writer.
 * The swap still only reads `isSanctioned`. This module is the writer.
 */

import { writeSanction, type SanctionWriteResult } from "../chain/sanctions.js";
import {
  getOfacSdnStatus,
  loadOfacSdn,
  screenOfacAddress,
  type OfacSdnSnapshot,
} from "./ofacSdn.js";

export type OfacHit = {
  address: string;
  match: boolean;
  registry: SanctionWriteResult | null;
};

export type OfacScreenResult = {
  snapshot: OfacSdnSnapshot;
  subject: OfacHit;
  counterparties: OfacHit[];
};

function emptyWrite(listed: boolean): SanctionWriteResult {
  return {
    ok: true,
    skipped: true,
    listedBefore: listed,
    listedAfter: listed,
  };
}

async function screenAndWrite(address: string): Promise<OfacHit> {
  const hit = await screenOfacAddress(address);
  if (!hit.match) {
    return { address: hit.address, match: false, registry: null };
  }
  const registry = await writeSanction(hit.address, true);
  if (!registry.ok) {
    console.error(
      `OFAC match ${hit.address} but SanctionRegistry write failed: ${registry.error ?? "unknown"}`,
    );
  } else if (!registry.skipped) {
    console.info(`OFAC SDN match → SanctionRegistry.setSanctioned ${hit.address} ${registry.txHash ?? ""}`);
  }
  return { address: hit.address, match: true, registry };
}

/**
 * Screen the subject (and optional counterparties) against live OFAC SDN.
 * Direct matches are written to SanctionRegistry so the next swap fail-closes at L1.
 */
export async function screenWalletOfac(params: {
  subject: string;
  counterparties?: string[];
}): Promise<OfacScreenResult> {
  const snapshot = await loadOfacSdn();
  const subject = snapshot.ok
    ? await screenAndWrite(params.subject)
    : {
        address: params.subject,
        match: false,
        registry: emptyWrite(false),
      };

  const seen = new Set([subject.address.toLowerCase()]);
  const counterparties: OfacHit[] = [];
  for (const addr of params.counterparties ?? []) {
    const key = addr.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    counterparties.push(
      snapshot.ok
        ? await screenAndWrite(addr)
        : { address: addr, match: false, registry: null },
    );
  }

  return { snapshot, subject, counterparties };
}

/**
 * Cached SDN status for /health (does not download).
 */
export function ofacHealth(): OfacSdnSnapshot {
  return getOfacSdnStatus();
}

/**
 * One-line finding for the ofac-screening skill and Opinion sources.
 */
export function ofacFindingText(result: OfacScreenResult): string {
  const { snapshot, subject } = result;
  if (!snapshot.live) {
    return "OFAC SDN HTTP disabled (OFAC_LIVE=0). Layer 1 mapping unchanged.";
  }
  if (!snapshot.ok) {
    return `OFAC SDN fetch failed (${snapshot.error ?? "unknown"}). Layer 1 mapping unchanged; swap still reads SanctionRegistry.`;
  }
  const src = snapshot.source;
  const asOf = snapshot.publishedAt ?? snapshot.fetchedAt ?? "unknown";
  const n = snapshot.addressCount.toLocaleString("en-US");
  const stale = snapshot.stale ? " stale-cache" : "";
  if (subject.match) {
    const wrote = subject.registry?.skipped
      ? "already on SanctionRegistry"
      : subject.registry?.ok
        ? `written to SanctionRegistry${subject.registry.txHash ? ` (${subject.registry.txHash})` : ""}`
        : `registry write failed (${subject.registry?.error ?? "unknown"})`;
    return `DIRECT MATCH on OFAC SDN ETH list (${n} addresses, ${src}, as of ${asOf}${stale}). Subject ${subject.address}: ${wrote}. Next swap reads the mapping (SanctionHit).`;
  }
  const peer = result.counterparties.find((c) => c.match);
  if (peer) {
    return `Subject ${subject.address} clear on OFAC SDN (${n} addresses, ${src}, as of ${asOf}${stale}). P2P counterparty ${peer.address} is a DIRECT MATCH: written to SanctionRegistry. Subject has indirect exposure. The subject is not a list hit.`;
  }
  return `Clear on OFAC SDN ETH list (${n} addresses, ${src}, as of ${asOf}${stale}). Exact-address screen; not written to SanctionRegistry.`;
}

/**
 * Source label for Opinion `sourcesConsulted`.
 */
export function ofacSourceLine(result: OfacScreenResult): string {
  const { snapshot } = result;
  if (!snapshot.ok) {
    return `OFAC SDN (live fetch failed: ${snapshot.error ?? "unknown"})`;
  }
  return `OFAC SDN ETH addresses (${snapshot.addressCount} loaded from ${snapshot.source}${snapshot.stale ? ", stale cache" : ""})`;
}
