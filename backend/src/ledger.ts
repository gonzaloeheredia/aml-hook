/**
 * In-memory ledger mutations: P2P transfers and pool swap settlement.
 */

import {
  ethOutFromSwap,
  EXPLOIT_SOURCE,
  hopScore,
  swapUsdcAmount,
} from "./scoring.js";
import type { Decision, TransferRecord, Wallet, WalletId } from "./types.js";

/**
 * Applies a P2P USDC transfer between two wallets.
 * - Debits the sender and credits the recipient.
 * - B and C both start clean. Receive from A → hop 1 (~score 65).
 * - Receive from a tainted peer → hop = sender.hop + 1 (score decays: 100 × 0.65^hops).
 * - Keeps the closer hop if the recipient was already contaminated.
 * - Does not clear exploitConfirmed on the exploit source (A).
 * Returns the next wallet map + transfer record, or null on failure.
 */
export function applyTransfer(
  wallets: Record<WalletId, Wallet>,
  from: WalletId,
  to: WalletId,
  amountUsd: number,
): { wallets: Record<WalletId, Wallet>; record: TransferRecord } | null {
  if (from === to) return null;
  const amount = Math.round(amountUsd);
  if (!Number.isFinite(amount) || amount <= 0) return null;

  const sender = wallets[from];
  const recipient = wallets[to];
  if (!sender || !recipient) return null;
  if (sender.usdc < amount) return null;

  const senderIsTainted = sender.exploitConfirmed || sender.hopDistance != null;
  const incomingHop = senderIsTainted ? (sender.hopDistance ?? 0) + 1 : null;
  const origin =
    sender.originId ?? (sender.exploitConfirmed ? sender.id : null);

  const nextSender: Wallet = {
    ...sender,
    usdc: sender.usdc - amount,
  };

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

  const nextRecipient: Wallet = {
    ...recipient,
    usdc: recipient.usdc + amount,
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
        ? `Clean wallet — ALLOW until contaminated by A or a tainted peer`
        : `${resolvedHop}-hop from origin ${resolvedOrigin ?? EXPLOIT_SOURCE}`,
  };

  const next: Record<WalletId, Wallet> = {
    ...wallets,
    [from]: nextSender,
    [to]: nextRecipient,
  };

  return {
    wallets: next,
    record: {
      id: `tx-${Date.now()}`,
      from,
      to,
      amountUsd: amount,
      at: new Date().toISOString(),
      resultingScore: hopScore(next[to]),
      hopDistance: next[to].hopDistance ?? 0,
    },
  };
}

/**
 * Settles a USDC→ETH pool swap on the ledger when the decision is not REVERT.
 * Debits USDC and credits ETH net of fee. Returns null if blocked or underfunded.
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
