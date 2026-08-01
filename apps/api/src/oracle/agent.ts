/**
 * Off-chain Compliance Officer / oracle agent runner.
 *
 * MOCK: skill pipeline + fact-scoring (no Anthropic / OpenSanctions / Etherscan).
 * After each evaluation, the keeper publishes to ComplianceOracle.updateScore:
 *   - MOCK trail by default (GET /oracle/publishes, no chain write)
 *   - REAL tx when ORACLE_RPC_URL + COMPLIANCE_ORACLE_ADDRESS + KEEPER_PRIVATE_KEY are set
 */

import { listEvents, listTransfers, listWallets, getWallet } from "../store.js";
import type { WalletId } from "../types.js";
import { buildFacts, scoreFromFacts } from "./factScoring.js";
import {
  clearScorePublishes,
  publishScoreToChain,
} from "./onchainPublisher.js";
import { buildOpinionFromScore } from "./report.js";
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
 * Reevaluates one wallet through the COA skill pipeline, caches the oracle,
 * and publishes the score for the next beforeSwap (mock or on-chain).
 */
export async function reevaluateWallet(
  walletId: WalletId,
  trigger: OracleTrigger,
): Promise<OracleEvaluation> {
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
  const opinion = buildOpinionFromScore(wallet, scoreResult);
  const onChainPublish = await publishScoreToChain(wallet, scoreResult);
  const evaluation: OracleEvaluation = {
    scoreResult,
    opinion,
    onChainPublish,
  };
  setOracleEvaluation(walletId, evaluation);
  return evaluation;
}

/**
 * Seeds oracle scores for A/B/C at process start or after reset.
 */
export async function seedOracleAll(): Promise<void> {
  for (const w of listWallets()) {
    await reevaluateWallet(w.id, "seed");
  }
}

/**
 * Clears oracle cache + publish trail and reseeds baseline scores.
 */
export async function resetOracle(): Promise<void> {
  clearOracleStore();
  clearScorePublishes();
  await seedOracleAll();
}

/**
 * After a P2P transfer: reevaluate recipient (contamination) and sender.
 */
export async function reevaluateAfterTransfer(
  from: WalletId,
  to: WalletId,
): Promise<{ from: OracleEvaluation; to: OracleEvaluation }> {
  return {
    from: await reevaluateWallet(from, "transfer"),
    to: await reevaluateWallet(to, "transfer"),
  };
}

/**
 * After afterSwap SwapObserved: incremental / full reevaluate for next beforeSwap.
 */
export async function reevaluateAfterSwap(
  walletId: WalletId,
): Promise<OracleEvaluation> {
  return reevaluateWallet(walletId, "afterSwap");
}

/**
 * After beforeSwap REVERT (WalletBlocked): still refresh oracle trail/opinion.
 */
export async function reevaluateAfterBlock(
  walletId: WalletId,
): Promise<OracleEvaluation> {
  return reevaluateWallet(walletId, "blocked");
}

/**
 * Returns cached evaluation or runs a fresh seed evaluation.
 */
export async function ensureOracleEvaluation(
  walletId: WalletId,
): Promise<OracleEvaluation> {
  return getOracleEvaluation(walletId) ?? reevaluateWallet(walletId, "manual");
}
