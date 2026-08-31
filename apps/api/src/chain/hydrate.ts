/**
 * Wallet listing: A–D stay on the in-memory store. E may overlay Sepolia
 * balances / neverScored. A dead RPC must not fail the guided demo.
 */

import { getAddress, type Address } from "viem";
import type { Wallet, WalletId } from "../types.js";
import { withDeadline } from "../demoMode.js";
import { getStore, setWallets } from "../store.js";
import { WALLET_IDS, isBoundWalletE } from "./accounts.js";
import { readRisk } from "./evaluate.js";
import { balanceEth, balanceUsdc } from "./ledger.js";

const E_OVERLAY_MS = 2_500;

async function overlayWalletE(): Promise<void> {
  const current = getStore().wallets;
  if (!isBoundWalletE(current.E.address)) return;
  const address = getAddress(current.E.address) as Address;
  const [usdc, eth, risk] = await Promise.all([
    balanceUsdc(address),
    balanceEth(address),
    readRisk(address),
  ]);
  setWallets({
    ...current,
    E: {
      ...current.E,
      address,
      usdc,
      eth,
      neverScored: risk.updatedAt === 0,
    },
  });
}

/**
 * Returns A–E. A–D are store state as-is (no balanceOf / getRisk).
 * E is optionally overlaid from chain; on failure the store row is kept.
 */
export async function hydrateWallets(): Promise<Wallet[]> {
  try {
    await withDeadline(overlayWalletE(), E_OVERLAY_MS);
  } catch {
    /* Sepolia down or slow: keep memory E */
  }
  return WALLET_IDS.map((id) => getStore().wallets[id]);
}

export function memoryWallet(id: WalletId): Wallet {
  return getStore().wallets[id];
}
