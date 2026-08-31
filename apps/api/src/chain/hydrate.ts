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

function clearMemoryBagE(): void {
  const current = getStore().wallets;
  setWallets({
    ...current,
    E: { ...current.E, usdc: 0, eth: 0 },
  });
}

async function overlayWalletE(): Promise<void> {
  const current = getStore().wallets;
  if (!isBoundWalletE(current.E.address)) {
    clearMemoryBagE();
    return;
  }
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
 * E is overlaid from chain. On failure the RAM bag is cleared so C→E
 * credits cannot leak into the MetaMask panel.
 */
export async function hydrateWallets(): Promise<Wallet[]> {
  try {
    await withDeadline(overlayWalletE(), E_OVERLAY_MS);
  } catch {
    clearMemoryBagE();
  }
  return WALLET_IDS.map((id) => getStore().wallets[id]);
}

export function memoryWallet(id: WalletId): Wallet {
  return getStore().wallets[id];
}
