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
 * Applies a P2P USDC transfer between two wallets.
 * Risk and score change only here. Pool swaps never raise behavioral score.
 *
 * Hop rules (B, C, D start clean / published score 0; E stays unknown):
 * - Receive from exploit A → hop 1 → score ≈ 65 → fee 8%
 * - Receive from a 1-hop peer (e.g. tainted B→C or C→B) → hop 2 → score ≈ 42 → fee 3%
 * - A second inbound from A keeps the closer hop (min); hop 1 wins over hop 2
 * - Clean→clean P2P does not contaminate
 * - Wallet D: ledger hop updates immediately; keeper publish may be deferred (API layer)
 *
 * Returns the next wallet map + transfer record, or null on failure.
 */
/**
 * Updates hop / origin only. Balances live on-chain; the keeper publishes this hop.
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
