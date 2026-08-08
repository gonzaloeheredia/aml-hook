/**
 * N-hop decay scoring for the AML Hook demo.
 *
 * Use case (`docs/Use_Case.md`):
 * - Wallet A = exploit attacker → REVERT on pool swaps.
 * - Wallets B and C both start clean (ALLOW 0.30%, green). Swaps never add score.
 * - Wallet D = latency path: A→D defers keeper; swap under stale 0 → inflow 8%.
 * - Risk only via MetaMask P2P hops:
 *   - Receive from A → hop 1 → score ≈ 65 → FEE_OVERRIDE 8% (yellow)
 *   - Receive from a 1-hop peer (B↔C after A tainted one) → hop 2 → ≈ 42 → 3%
 * - Closer hop wins if a wallet is contaminated more than once.
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
export const EXPLOIT_SOURCE: SimWalletId = "A";
/** §3.8 latency / inflow floor (8%) when keeper fee is absent */
export const LATENCY_FEE_BPS = 800;
/** Balance-delta share (bps) that flags significant inflow */
export const INFLOW_THRESHOLD_BPS = 5000;

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
  /** True while deferred keeper has not published post-transfer score (Wallet D). */
  keeperPending?: boolean;
  /** Inflow baseline USDC (refreshed afterSwap). */
  lastKnownUsdc?: number;
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
 * Computes N-hop derived score for a wallet state (ledger truth).
 * When keeperPending, the oracle still reads stale 0 — use resolveDemoRisk.
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

export function inflowDeltaBps(currentUsdc: number, lastKnownUsdc: number): number {
  if (currentUsdc <= 0) return 0;
  const delta = currentUsdc > lastKnownUsdc ? currentUsdc - lastKnownUsdc : 0;
  return Math.floor((delta * 10_000) / currentUsdc);
}

/**
 * Offline beforeSwap resolution: hop score, or stale 0 + inflow floor when keeperPending.
 */
export function resolveDemoRisk(wallet: SimWallet): {
  score: number;
  decision: "allow" | "fee_override" | "block";
  feeBps: number;
  latencyMitigation: "INFLOW_HEURISTIC" | null;
  keeperPending: boolean;
} {
  const keeperPending = Boolean(wallet.keeperPending);
  if (wallet.exploitConfirmed) {
    return {
      score: 100,
      decision: "block",
      feeBps: 0,
      latencyMitigation: null,
      keeperPending,
    };
  }

  if (keeperPending) {
    const baseline = wallet.lastKnownUsdc ?? 0;
    const deltaBps = inflowDeltaBps(wallet.usdc, baseline);
    if (deltaBps > INFLOW_THRESHOLD_BPS) {
      return {
        score: 0,
        decision: "fee_override",
        feeBps: LATENCY_FEE_BPS,
        latencyMitigation: "INFLOW_HEURISTIC",
        keeperPending,
      };
    }
    return {
      score: 0,
      decision: "allow",
      feeBps: 30,
      latencyMitigation: null,
      keeperPending,
    };
  }

  const score = hopScore(wallet);
  const decision = decisionFromScore(score);
  return {
    score,
    decision,
    feeBps: feeBpsFromHop(score, wallet.hopDistance),
    latencyMitigation: null,
    keeperPending: false,
  };
}

/**
 * Initial ledger: A = exploit source; B + C + D start clean (D at 0 USDC for inflow demo).
 */
export function initialSimWallets(): Record<SimWalletId, SimWallet> {
  return {
    A: {
      id: "A",
      accountLabel: "Account A · Exploit",
      role: "Exploit attacker — REVERT on pool; contaminates B, C, or D via P2P",
      address: "0x8576aCC5C05D6Ce88f4e49bf65BdF0C62F91353C",
      usdc: 10_000_000,
      eth: 5,
      hopDistance: 0,
      originId: "A",
      exploitConfirmed: true,
      lastKnownUsdc: 10_000_000,
    },
    B: {
      id: "B",
      accountLabel: "Account B · Clean",
      role: "Clean wallet — A→B = 1-hop (~65); tainted C→B = 2-hop (~42)",
      address: "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD",
      usdc: 25_000,
      eth: 4,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      lastKnownUsdc: 25_000,
    },
    C: {
      id: "C",
      accountLabel: "Account C · Clean",
      role: "Clean wallet — A→C = 1-hop (~65); tainted B→C = 2-hop (~42)",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      usdc: 50_000,
      eth: 8,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      lastKnownUsdc: 50_000,
    },
    D: {
      id: "D",
      accountLabel: "Account D · Clean",
      role: "Latency path — A→D then swap before keeper → inflow FEE_OVERRIDE 8%",
      address: "0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97",
      usdc: 0,
      eth: 2,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      keeperPending: false,
      lastKnownUsdc: 0,
    },
  };
}

/**
 * P2P USDC transfer between demo addresses.
 * Debits sender and credits recipient (round whole USDC).
 *
 * Contamination rules (B, C, D both start clean):
 * - Receive from exploit A → hop 1 → score ≈ 65 (FEE_OVERRIDE 8%)
 * - Receive from a tainted peer → hop = sender.hop + 1
 * - Wallet D: sets keeperPending so offline overlay uses stale score + inflow
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
  const incomingHop = senderIsTainted ? (sender.hopDistance ?? 0) + 1 : null;
  const origin =
    sender.originId ?? (sender.exploitConfirmed ? sender.id : null);

  const nextSender: SimWallet = {
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

  const deferKeeper = to === "D" && incomingHop != null;

  const nextRecipient: SimWallet = {
    ...recipient,
    usdc: recipient.usdc + amount,
    hopDistance: resolvedHop,
    originId: resolvedOrigin,
    keeperPending: deferKeeper ? true : recipient.keeperPending,
    accountLabel: recipient.exploitConfirmed
      ? recipient.accountLabel
      : deferKeeper
        ? `Account ${recipient.id} · Latency window`
        : resolvedHop == null
          ? `Account ${recipient.id} · Clean`
          : `Account ${recipient.id} · ${resolvedHop}-hop`,
    role: recipient.exploitConfirmed
      ? recipient.role
      : deferKeeper
        ? "Latency path — keeper pending; swap under stale score 0 → inflow 8%"
        : resolvedHop == null
          ? `Clean wallet — ALLOW until contaminated by A or a tainted peer`
          : `${resolvedHop}-hop from origin ${resolvedOrigin ?? EXPLOIT_SOURCE}`,
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
      resultingScore: deferKeeper ? 0 : hopScore(next[to]),
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
 * USDC ↓, ETH ↑. Clears keeperPending and refreshes lastKnownUsdc (afterSwap).
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
  const nextUsdc = wallet.usdc - amount;
  const wasPending = Boolean(wallet.keeperPending);

  return {
    ...wallets,
    [walletId]: {
      ...wallet,
      usdc: nextUsdc,
      eth: Math.round((wallet.eth + ethOut) * 10_000) / 10_000,
      lastKnownUsdc: nextUsdc,
      // Offline catch-up: after latency swap, clear pending so hop score applies next.
      keeperPending: false,
      accountLabel:
        wasPending && wallet.hopDistance != null
          ? `Account ${wallet.id} · ${wallet.hopDistance}-hop`
          : wallet.accountLabel,
      role:
        wasPending && wallet.hopDistance != null
          ? `${wallet.hopDistance}-hop from origin ${wallet.originId ?? EXPLOIT_SOURCE}`
          : wallet.role,
    },
  };
}
