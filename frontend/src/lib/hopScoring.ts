/**
 * N-hop decay scoring for the AML Hook demo.
 *
 * Demo rules (product flow):
 * - Wallets A and B start CLEAN → swaps ALLOW at 0.30%.
 * - Wallet C is the exploit / tainted source → swaps REVERT.
 * - Contamination only starts when C transfers to A or B (1-hop → fee 8%).
 * - If that recipient later transfers to the other clean wallet (2-hop → fee 3%).
 *
 * Formula: derived_score = origin_score × (decay_factor ^ hops) × exposed_proportion
 */

import type { DemoCaseId } from "@/data/cases";

export type SimWalletId = DemoCaseId;

export const DECAY_FACTOR = 0.65;
export const ORIGIN_EXPLOIT_SCORE = 100;
/** Shared ETH mark used by MetaMask ledger + Uniswap swap preview (1 ETH = 1,000 USDC) */
export const ETH_USD = 1_000;
/** Default demo swap size in USDC (capped by wallet balance) */
export const DEFAULT_SWAP_USDC = 1_000;
/** Exploit / tainted source wallet in this demo */
export const EXPLOIT_SOURCE: SimWalletId = "C";

export type SimWallet = {
  id: SimWalletId;
  accountLabel: string;
  role: string;
  address: string;
  usdc: number;
  eth: number;
  hopDistance: number | null;
  originId: SimWalletId | null;
  exploitConfirmed: boolean;
};

export type TransferRecord = {
  id: string;
  from: SimWalletId;
  to: SimWalletId;
  amountUsd: number;
  at: string;
  resultingScore: number;
  hopDistance: number;
};

export function caseIdForSimWallet(id: SimWalletId): DemoCaseId {
  return id;
}

/**
 * Computes N-hop derived score for a wallet state.
 */
export function hopScore(wallet: SimWallet): number {
  if (wallet.exploitConfirmed) return ORIGIN_EXPLOIT_SCORE;
  if (wallet.hopDistance == null) return 0;
  return Math.round(
    ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** wallet.hopDistance * 1.0,
  );
}

export function decisionFromScore(score: number): "allow" | "fee_override" | "block" {
  if (score >= 71) return "block";
  if (score >= 31) return "fee_override";
  return "allow";
}

/**
 * Dynamic fee in bps: clean 0.30% · 1-hop 8% · 2-hop 3% · REVERT 0.
 */
export function feeBpsFromHop(score: number, hopDistance: number | null): number {
  if (score >= 71) return 0;
  if (score <= 30) return 30;
  if (hopDistance === 1) return 800;
  if (hopDistance === 2) return 300;
  const t = (score - 31) / 39;
  return Math.round(800 - t * 500);
}

/**
 * Initial ledger: A + B clean, C = exploit source with tainted USDC.
 */
export function initialSimWallets(): Record<SimWalletId, SimWallet> {
  return {
    A: {
      id: "A",
      accountLabel: "Account A · Clean",
      role: "Clean wallet — swaps freely until tainted by C",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      usdc: 50_000,
      eth: 8,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
    },
    B: {
      id: "B",
      accountLabel: "Account B · Clean",
      role: "Clean wallet — swaps freely until tainted by C",
      address: "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD",
      usdc: 25_000,
      eth: 4,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
    },
    C: {
      id: "C",
      accountLabel: "Account C · Exploit",
      role: "Exploit source — REVERT on pool swaps; contaminates A/B via P2P",
      address: "0x8576aCC5C05D6Ce88f4e49bf65BdF0C62F91353C",
      usdc: 10_000_000,
      eth: 12,
      hopDistance: 0,
      originId: "C",
      exploitConfirmed: true,
    },
  };
}

/**
 * P2P USDC transfer between demo addresses.
 * Debits sender and credits recipient (round whole USDC), then propagates
 * N-hop contamination only when the sender is already tainted.
 */
export function applyTransfer(
  wallets: Record<SimWalletId, SimWallet>,
  from: SimWalletId,
  to: SimWalletId,
  amountUsd: number,
): { wallets: Record<SimWalletId, SimWallet>; record: TransferRecord } | null {
  if (from === to) return null;
  const amount = Math.round(amountUsd);
  if (!Number.isFinite(amount) || amount <= 0) return null;

  const sender = wallets[from];
  const recipient = wallets[to];
  if (!sender || !recipient) return null;
  if (sender.usdc < amount) return null;

  const senderIsTainted = sender.exploitConfirmed || sender.hopDistance != null;
  const nextHop = senderIsTainted ? (sender.hopDistance ?? 0) + 1 : null;
  const origin =
    sender.originId ?? (sender.exploitConfirmed ? sender.id : null);

  const nextSender: SimWallet = {
    ...sender,
    usdc: sender.usdc - amount,
  };

  const nextRecipient: SimWallet = {
    ...recipient,
    usdc: recipient.usdc + amount,
    // Never overwrite the exploit source flag on C; only contaminate clean recipients
    hopDistance: recipient.exploitConfirmed
      ? recipient.hopDistance
      : nextHop == null
        ? recipient.hopDistance
        : recipient.hopDistance == null
          ? nextHop
          : Math.min(recipient.hopDistance, nextHop),
    originId: recipient.exploitConfirmed
      ? recipient.originId
      : nextHop == null
        ? recipient.originId
        : (origin ?? recipient.originId),
    accountLabel: recipient.exploitConfirmed
      ? recipient.accountLabel
      : nextHop == null
        ? recipient.accountLabel
        : `Account ${recipient.id} · ${nextHop}-hop`,
    role: recipient.exploitConfirmed
      ? recipient.role
      : nextHop == null
        ? recipient.role
        : `${nextHop}-hop intermediary from origin ${origin ?? "C"}`,
  };

  const next: Record<SimWalletId, SimWallet> = {
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
 * Caps the demo swap to what the wallet can actually spend.
 */
export function swapUsdcAmount(wallet: SimWallet, preferred = DEFAULT_SWAP_USDC): number {
  return Math.min(preferred, Math.max(0, Math.floor(wallet.usdc)));
}

/**
 * ETH received after pool fee (bps) when selling `usdcIn` USDC.
 */
export function ethOutFromSwap(usdcIn: number, feeBps: number): number {
  if (usdcIn <= 0) return 0;
  const netUsdc = usdcIn * (1 - feeBps / 10_000);
  return netUsdc / ETH_USD;
}

/**
 * Settles a successful pool swap against the MetaMask ledger:
 * USDC ↓, ETH ↑. Reverts / blocks leave balances unchanged.
 */
export function applyPoolSwap(
  wallets: Record<SimWalletId, SimWallet>,
  walletId: SimWalletId,
  usdcIn: number,
  feeBps: number,
  decision: "allow" | "fee_override" | "block",
): Record<SimWalletId, SimWallet> | null {
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
