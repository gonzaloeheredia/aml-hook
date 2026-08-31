/**
 * Guided-demo wallets A–D stay in the in-memory store.
 * Wallet E is the Sepolia / Uniswap path.
 */

import type { WalletId } from "./types.js";

/**
 * True for the in-memory guided-demo wallets (A–D).
 * Those IDs must never issue eth_call, txs, or hydrate overlays from chain.
 */
export function isMockDemoWallet(id: WalletId): boolean {
  return id === "A" || id === "B" || id === "C" || id === "D";
}

/** Bound a promise so a dead Sepolia RPC cannot stall A–D listing. */
export async function withDeadline<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => {
        timer = setTimeout(() => reject(new Error("deadline")), ms);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
