/**
 * N-hop decay scoring and fee helpers for the AML Hook.
 * Same rules as the frontend / use-case doc (decay 0.65, ternary bands).
 */

import type { Decision, Wallet, WalletId } from "./types.js";

/** Contamination weight retained per hop. */
export const DECAY_FACTOR = 0.65;
/** Score assigned to a confirmed exploit origin (Wallet A). */
export const ORIGIN_EXPLOIT_SCORE = 100;
/** Demo mark: 1 ETH = 1,000 USDC. */
export const ETH_USD = 1_000;
/** Default swap size in USDC (capped by wallet balance). */
export const DEFAULT_SWAP_USDC = 1_000;
/** Exploit / tainted source wallet in this demo. */
export const EXPLOIT_SOURCE: WalletId = "A";
/** Standard pool fee in basis points (0.30%). */
export const BASE_FEE_BPS = 30;

/**
 * Computes the AML score for a wallet.
 * - Confirmed exploit → 100
 * - No hops → 0
 * - With hops → 100 × 0.65^hops
 */
export function hopScore(wallet: Wallet): number {
  if (wallet.exploitConfirmed) return ORIGIN_EXPLOIT_SCORE;
  if (wallet.hopDistance == null) return 0;
  return Math.round(
    ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** wallet.hopDistance * 1.0,
  );
}

/**
 * Maps a numeric score to the hook's ternary decision:
 * ALLOW (0–30), FEE_OVERRIDE (31–70), or REVERT/block (71–100).
 */
export function decisionFromScore(score: number): Decision {
  if (score >= 71) return "block";
  if (score >= 31) return "fee_override";
  return "allow";
}

/**
 * Returns the applied fee in basis points from score and hop distance.
 * Clean 0.30% · 1-hop 8% · 2-hop 3% · REVERT 0.
 */
export function feeBpsFromHop(score: number, hopDistance: number | null): number {
  if (score >= 71) return 0;
  if (score <= 30) return BASE_FEE_BPS;
  if (hopDistance === 1) return 800;
  if (hopDistance === 2) return 300;
  const t = (score - 31) / 39;
  return Math.round(800 - t * 500);
}

/**
 * Picks how much USDC to sell in a swap: min(preferred, available balance).
 */
export function swapUsdcAmount(wallet: Wallet, preferred = DEFAULT_SWAP_USDC): number {
  return Math.min(preferred, Math.max(0, Math.floor(wallet.usdc)));
}

/**
 * Computes ETH received after selling `usdcIn` USDC, net of pool fee (bps).
 */
export function ethOutFromSwap(usdcIn: number, feeBps: number): number {
  if (usdcIn <= 0) return 0;
  const netUsdc = usdcIn * (1 - feeBps / 10_000);
  return netUsdc / ETH_USD;
}

/**
 * Maps an internal decision to the on-chain hook output label
 * (ALLOW / FEE_OVERRIDE / REVERT).
 */
export function toHookOutput(decision: Decision): "ALLOW" | "FEE_OVERRIDE" | "REVERT" {
  if (decision === "block") return "REVERT";
  if (decision === "fee_override") return "FEE_OVERRIDE";
  return "ALLOW";
}

/**
 * Type guard: returns true when `value` is a demo wallet id (A, B, or C).
 */
export function isWalletId(value: string): value is WalletId {
  return value === "A" || value === "B" || value === "C";
}
