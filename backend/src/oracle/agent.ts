/**
 * Off-chain Compliance Officer / oracle agent runner (MOCK_MODE).
 *
 * Implements the skill flow from agents/oracle-coa/README.md without calling
 * live LLM or vendor APIs. Scoring uses fact-scoring rules over the demo ledger.
 * Results are cached as the pre-swap oracle score and feed Legal Opinion.
 */

import { listEvents, listTransfers, listWallets, getWallet } from "../store.js";
import type { WalletId } from "../types.js";
import { buildFacts, scoreFromFacts } from "./factScoring.js";
import { buildDictamenFromScore } from "./report.js";
import {
  clearOracleStore,
  getOracleEvaluation,
  getOracleScore,
  setOracleEvaluation,
} from "./store.js";
import type { OracleEvaluation, OracleTrigger } from "./types.js";

const FULL_FLOW = [
  "task-swap-intake",
  "originator-attribution",
  "ofac-screening",
  "task-onchain-evidence",
  "wallet-screening",
  "swap-behavior-analysis",
  "typology-detection",
  "cross-pool-intelligence",
  "fact-scoring",
  "task-swap-decision",
  "task-regulatory-report",
] as const;

const INCREMENTAL_FLOW = [
  "task-swap-intake",
  "swap-behavior-analysis",
  "fact-scoring",
  "task-swap-decision",
  "task-regulatory-report",
] as const;

/**
 * Reevaluates one wallet through the COA skill pipeline and writes the oracle.
 */
export function reevaluateWallet(
  walletId: WalletId,
  trigger: OracleTrigger,
): OracleEvaluation {
  const wallet = getWallet(walletId);
  if (!wallet) {
    throw new Error(`Oracle: wallet ${walletId} not found`);
  }

  const prior = getOracleScore(walletId);
  const useIncremental =
    trigger === "afterSwap" &&
    prior != null &&
    !wallet.exploitConfirmed &&
    wallet.hopDistance == null;

  const skills = [...(useIncremental ? INCREMENTAL_FLOW : FULL_FLOW)];
  const facts = buildFacts(wallet, listTransfers(), listEvents());
  const scoreResult = scoreFromFacts(
    wallet,
    facts,
    trigger,
    prior,
    skills,
    useIncremental ? "INCREMENTAL" : "FULL",
  );
  const dictamen = buildDictamenFromScore(wallet, scoreResult);
  const evaluation: OracleEvaluation = { scoreResult, dictamen };
  setOracleEvaluation(walletId, evaluation);
  return evaluation;
}

/**
 * Seeds oracle scores for A/B/C at process start or after reset.
 */
export function seedOracleAll(): void {
  for (const w of listWallets()) {
    reevaluateWallet(w.id, "seed");
  }
}

/**
 * Clears oracle cache and reseeds baseline scores.
 */
export function resetOracle(): void {
  clearOracleStore();
  seedOracleAll();
}

/**
 * After a P2P transfer: reevaluate recipient (contamination) and sender.
 */
export function reevaluateAfterTransfer(
  from: WalletId,
  to: WalletId,
): { from: OracleEvaluation; to: OracleEvaluation } {
  return {
    from: reevaluateWallet(from, "transfer"),
    to: reevaluateWallet(to, "transfer"),
  };
}

/**
 * After afterSwap SwapObserved: incremental / full reevaluate for next beforeSwap.
 */
export function reevaluateAfterSwap(walletId: WalletId): OracleEvaluation {
  return reevaluateWallet(walletId, "afterSwap");
}

/**
 * After beforeSwap REVERT (WalletBlocked): still refresh oracle trail/dictamen.
 */
export function reevaluateAfterBlock(walletId: WalletId): OracleEvaluation {
  return reevaluateWallet(walletId, "blocked");
}

/**
 * Returns cached evaluation or runs a fresh seed evaluation.
 */
export function ensureOracleEvaluation(walletId: WalletId): OracleEvaluation {
  return getOracleEvaluation(walletId) ?? reevaluateWallet(walletId, "manual");
}
