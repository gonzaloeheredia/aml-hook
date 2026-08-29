/**
 * Overlay on-chain balances / neverScored onto the in-memory A–F labels and hops.
 */

import type { Wallet, WalletId } from "../types.js";
import { resetOracle } from "../oracle/index.js";
import { getStore, setWallets } from "../store.js";
import { DEMO_WALLETS, WALLET_IDS, bindOfacDemoWallet } from "./accounts.js";
import { requireChain } from "./clients.js";
import { readRisk } from "./evaluate.js";
import { balanceEth, balanceUsdc, seedBalances } from "./ledger.js";

let seeded = false;

export async function hydrateWallets(): Promise<Wallet[]> {
  await requireChain();
  await bindOfacDemoWallet();
  if (!seeded) {
    const opening = await balanceUsdc(DEMO_WALLETS.A.address);
    if (opening === 0) {
      await seedBalances();
      await resetOracle();
    }
    seeded = true;
  }
  const current = getStore().wallets;
  const next = { ...current };
  for (const id of WALLET_IDS) {
    const address = DEMO_WALLETS[id].address;
    const [usdc, eth, risk] = await Promise.all([
      balanceUsdc(address),
      balanceEth(address),
      readRisk(address),
    ]);
    next[id] = {
      ...current[id],
      address,
      usdc,
      eth,
      neverScored: id === "F" ? false : risk.updatedAt === 0,
      ofacSubject: Boolean(DEMO_WALLETS[id].ofacSubject),
    };
  }
  setWallets(next);
  return WALLET_IDS.map((id) => next[id]);
}

export function memoryWallet(id: WalletId): Wallet {
  return getStore().wallets[id];
}
