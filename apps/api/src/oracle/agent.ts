/**
 * Off-chain Compliance Officer / oracle agent runner.
 *
 * Runs the virtual AI AML analyst pipeline (skills + connected sources), then
 * scores deterministically for the A/B/C/D use case and publishes via the keeper.
 *
 * Wallet D (§3.8 / use-case §7): after inbound P2P, updateScore is deferred so the
 * next swap can demonstrate the inflow heuristic under a stale score of 0.
 */

import {
  clearKeeperPending,
  getWallet,
  isKeeperPending,
  listEvents,
  listTransfers,
  listWallets,
  markKeeperPending,
} from "../store.js";
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
import { runVirtualAgentPipeline } from "./virtualAgent.js";

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
 * and publishes the score for the next beforeSwap.
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
  const flow = useIncremental ? "INCREMENTAL" : "FULL";
  // Theater latency on interactive triggers only (keep seed/reset snappy).
  const theater = trigger !== "seed";

  const agentRun = await runVirtualAgentPipeline({
    wallet,
    trigger,
    skills,
    flow,
    theater,
  });

  const facts = buildFacts(wallet, listTransfers(), listEvents());
  const scoreResult = scoreFromFacts(
    wallet,
    facts,
    trigger,
    prior,
    skills,
    flow,
  );
  const opinion = buildOpinionFromScore(wallet, scoreResult, agentRun);
  const onChainPublish = await publishScoreToChain(wallet, scoreResult);
  const evaluation: OracleEvaluation = {
    scoreResult,
    opinion,
    agentRun,
    onChainPublish,
  };
  setOracleEvaluation(walletId, evaluation);
  return evaluation;
}

/**
 * Seeds oracle scores for A–D at process start or after reset.
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
 * After a P2P transfer: reevaluate sender always; recipient immediately unless
 * the recipient is Wallet D (deferred keeper — stale score 0 until catch-up).
 */
export async function reevaluateAfterTransfer(
  from: WalletId,
  to: WalletId,
): Promise<{
  from: OracleEvaluation;
  to: OracleEvaluation | null;
  keeperPending: boolean;
}> {
  const fromEval = await reevaluateWallet(from, "transfer");

  // Wallet D latency path: ledger hops update, but updateScore waits for catch-up.
  if (to === "D") {
    markKeeperPending("D");
    return {
      from: fromEval,
      to: getOracleEvaluation("D"),
      keeperPending: true,
    };
  }

  clearKeeperPending(to);
  return {
    from: fromEval,
    to: await reevaluateWallet(to, "transfer"),
    keeperPending: false,
  };
}

/**
 * Keeper catch-up: publish the decay score after the deferred window (Wallet D → ~65).
 */
export async function catchUpKeeper(walletId: WalletId): Promise<OracleEvaluation> {
  const evaluation = await reevaluateWallet(walletId, "transfer");
  clearKeeperPending(walletId);
  return evaluation;
}

/**
 * True when this wallet still awaits a deferred updateScore (Wallet D demo).
 */
export function walletKeeperPending(walletId: WalletId): boolean {
  return isKeeperPending(walletId);
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
