/**
 * In-memory oracle score store (stand-in for ComplianceOracle until contracts).
 */

import type { WalletId } from "../types.js";
import type { OracleEvaluation } from "./types.js";

const evaluations = new Map<WalletId, OracleEvaluation>();

/**
 * Returns the cached oracle evaluation for a wallet, if any.
 */
export function getOracleEvaluation(
  walletId: WalletId,
): OracleEvaluation | null {
  return evaluations.get(walletId) ?? null;
}

/**
 * Returns the cached final score, or null when the oracle has not run yet.
 */
export function getOracleScore(walletId: WalletId): number | null {
  return evaluations.get(walletId)?.scoreResult.score_final ?? null;
}

/**
 * Writes (or overwrites) the oracle evaluation for a wallet.
 */
export function setOracleEvaluation(
  walletId: WalletId,
  evaluation: OracleEvaluation,
): void {
  evaluations.set(walletId, evaluation);
}

/**
 * Clears all oracle scores (used on POST /reset).
 */
export function clearOracleStore(): void {
  evaluations.clear();
}

/**
 * Lists all cached evaluations (debug / health).
 */
export function listOracleEvaluations(): OracleEvaluation[] {
  return [...evaluations.values()];
}
