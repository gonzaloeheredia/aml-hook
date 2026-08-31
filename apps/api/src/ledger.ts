/**
 * MOCK in-memory ledger mutations: P2P transfers and pool swap settlement.
 * These are not Uniswap PoolManager swaps. The API simulates settlement and fees
 * for the demo UI. Risk propagation (hops) is real product logic, stored in memory
 * and then published on-chain by the keeper when RPC env is set.
 */

import {
  ethOutFromSwap,
  EXPLOIT_SOURCE,
  swapUsdcAmount,
} from "./scoring.js";
import type { Decision, Wallet, WalletId } from "./types.js";

/**
 * Debits sender USDC and credits recipient, then applies hop contamination.
 * Used for A–D (and A–D→E) P2P so balances never leave the in-memory store.
 */
export function applyP2pTransfer(
  wallets: Record<WalletId, Wallet>,
  from: WalletId,
  to: WalletId,
  amountUsd: number,
): Record<WalletId, Wallet> | null {
  const amount = Math.round(amountUsd);
  const sender = wallets[from];
  const recipient = wallets[to];
  if (!sender || !recipient || from === to || amount <= 0) return null;
  if (sender.usdc < amount) return null;
  const withBalances: Record<WalletId, Wallet> = {
    ...wallets,
    [from]: { ...sender, usdc: sender.usdc - amount },
    [to]: { ...recipient, usdc: recipient.usdc + amount },
  };
  return applyHopContamination(withBalances, from, to);
}

/**
 * Updates hop / origin. Receive from A → hop 1 (~65); from a 1-hop peer → hop 2 (~42).
 * Clean→clean does not contaminate. E (neverScored) is unchanged.
 */
export function applyHopContamination(
  wallets: Record<WalletId, Wallet>,
  from: WalletId,
  to: WalletId,
): Record<WalletId, Wallet> {
  const sender = wallets[from];
  const recipient = wallets[to];
  if (!sender || !recipient || from === to) return wallets;
  if (recipient.neverScored) return wallets;

  const senderIsTainted = sender.exploitConfirmed || sender.hopDistance != null;
  const incomingHop = senderIsTainted ? (sender.hopDistance ?? 0) + 1 : null;
  const origin = sender.originId ?? (sender.exploitConfirmed ? sender.id : null);
  const resolvedHop = recipient.exploitConfirmed
    ? recipient.hopDistance
    : incomingHop == null
      ? recipient.hopDistance
      : recipient.hopDistance == null
        ? incomingHop
        : Math.min(recipient.hopDistance, incomingHop);
  const resolvedOrigin = recipient.exploitConfirmed
    ? recipient.originId
    : incomingHop == null
      ? recipient.originId
      : (origin ?? recipient.originId);

  return {
    ...wallets,
    [to]: {
      ...recipient,
      hopDistance: resolvedHop,
      originId: resolvedOrigin,
      accountLabel: recipient.exploitConfirmed
        ? recipient.accountLabel
        : resolvedHop == null
          ? `Account ${recipient.id} · Clean`
          : `Account ${recipient.id} · ${resolvedHop}-hop`,
      role: recipient.exploitConfirmed
        ? recipient.role
        : resolvedHop == null
          ? `Clean wallet. ALLOW until contaminated by A or a tainted peer`
          : `${resolvedHop}-hop from origin ${resolvedOrigin ?? EXPLOIT_SOURCE}`,
    },
  };
}

/**
 * Settles a USDC→ETH pool swap on the ledger when the decision is not REVERT.
 * Debits USDC and credits ETH net of fee. Returns null if blocked or underfunded.
 * Does not change hopDistance or behavioral score. Clean wallets stay green
 * after any number of swaps. Risk moves only via P2P hops.
 */
export function applyPoolSwap(
  wallets: Record<WalletId, Wallet>,
  walletId: WalletId,
  usdcIn: number,
  feeBps: number,
  decision: Decision,
): Record<WalletId, Wallet> | null {
  if (decision === "block") return null;
  const amount = Math.round(usdcIn);
  if (amount <= 0) return null;
  const wallet = wallets[walletId];
  if (!wallet || wallet.usdc < amount) return null;

  const ethOut = ethOutFromSwap(amount, feeBps);
  return {
    ...wallets,
    [walletId]: {
      ...wallet,
      usdc: wallet.usdc - amount,
      eth: Math.round((wallet.eth + ethOut) * 10_000) / 10_000,
    },
  };
}

/** Re-export: computes how much USDC a wallet can spend in a swap. */
export { swapUsdcAmount };
