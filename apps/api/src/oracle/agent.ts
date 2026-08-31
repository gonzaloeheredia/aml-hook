/**
 * Off-chain Compliance Officer / oracle agent runner.
 *
 * A–D use the skill interpreter (hop + band). Claude is optional Opinion text.
 * A live-COA miss (billing, 401, timeout) falls back to that skill score so
 * GET /compliance cannot 500 the guided demo. Non-demo live subjects still
 * call Claude; on failure they keep a cached row or the skill score.
 * Tick only stamps the last agent score (no Claude). Bound Wallet E is published.
 */

import {
  clearKeeperPending,
  demoNow,
  getLastScoreAt,
  getStore,
  getWallet,
  isKeeperPending,
  listEvents,
  listTransfers,
  listWallets,
  markKeeperPending,
  setWallets,
  STALENESS_MS,
  touchScoreAt,
} from "../store.js";
import { isBoundWalletE } from "../chain/accounts.js";
import { shouldPublishScore } from "../scoring.js";
import type { WalletId } from "../types.js";
import { buildFacts, collectSanctionFacts, counterpartiesOf, factsFromOfacScreen, scoreFromFacts } from "./factScoring.js";
import { screenWalletOfac, type OfacScreenResult } from "./ofacScreen.js";
import {
  clearScorePublishes,
  publishScoreToChain,
} from "./onchainPublisher.js";
import { buildOpinionFromScore } from "./report.js";
import {
  clearOracleStore,
  getOracleEvaluation,
  getOracleFeeBps,
  getOracleScore,
  setOracleEvaluation,
} from "./store.js";
import type { OracleEvaluation, OracleOpinion, OracleTrigger, ScoreResult } from "./types.js";
import { isMockDemoWallet } from "../demoMode.js";
import { applyLiveOpinionIfNeeded, isLiveCoaEnabled } from "./liveOpinion.js";
import {
  evaluateWithLiveAgent,
  type ScoringEvidence,
} from "./liveScore.js";
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
  "uhi10-use-case",
  "fact-scoring",
  "task-swap-decision",
  "search_regulations",
  "task-regulatory-report",
] as const;

const INCREMENTAL_FLOW = [
  "task-swap-intake",
  "ofac-screening",
  "swap-behavior-analysis",
  "uhi10-use-case",
  "fact-scoring",
  "task-swap-decision",
  "search_regulations",
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

  if (trigger === "tick") {
    return republishTick(walletId);
  }

  const prior = getOracleScore(walletId);
  const useIncremental =
    trigger === "afterSwap" &&
    prior != null &&
    !wallet.exploitConfirmed &&
    wallet.hopDistance == null;

  const skills = [...(useIncremental ? INCREMENTAL_FLOW : FULL_FLOW)];
  const flow = useIncremental ? "INCREMENTAL" : "FULL";
  const live =
    isLiveCoaEnabled() &&
    !wallet.neverScored &&
    !isMockDemoWallet(wallet.id);

  const transfers = listTransfers();
  const events = listEvents();
  const ofac = await screenWalletOfac({
    subject: wallet.address,
    counterparties: counterpartiesOf(wallet, transfers),
  });
  const registryFacts = await collectSanctionFacts(wallet, transfers, events);
  const liveOfacFacts = factsFromOfacScreen(wallet, ofac);
  const extraFacts = [
    ...liveOfacFacts,
    ...registryFacts.filter(
      (f) => !liveOfacFacts.some((live) => live.type === f.type),
    ),
  ];
  const evidence: ScoringEvidence = {
    wallet,
    priorScore: prior,
    transfers,
    events,
    sanctions: {
      subjectListed:
        ofac.subject.match ||
        extraFacts.some((f) => f.type === "OFAC_DIRECT_MATCH"),
      listedCounterparties: extraFacts
        .filter((f) => f.type === "SANCTIONED_COUNTERPARTY")
        .map((f) => f.justification),
      listedContractsTouched: extraFacts
        .filter((f) => f.type === "SANCTIONED_CONTRACT_INTERACTION")
        .map((f) => f.justification),
    },
    ofac,
  };

  async function evaluateWithSkill(): Promise<OracleEvaluation> {
    const agentRun = await runVirtualAgentPipeline({
      wallet,
      trigger,
      skills,
      flow,
      theater: trigger !== "seed",
      ofac,
    });
    const facts = buildFacts(wallet, transfers, events, extraFacts);
    const scoreResult = scoreFromFacts(
      wallet,
      facts,
      trigger,
      prior,
      skills,
      flow,
    );
    return persistEvaluation({
      wallet,
      scoreResult,
      agentRun,
      scoreSource: "skill",
      opinionSource: "mock",
      trigger,
      prior,
      ofac,
    });
  }

  if (live) {
    try {
      const scored = await evaluateWithRetry(evidence, trigger, skills, flow);
      return persistEvaluation({
        wallet,
        scoreResult: scored.scoreResult,
        agentRun: scored.agentRun,
        opinion: scored.opinion,
        scoreSource: "anthropic",
        opinionSource: "anthropic",
        trigger,
        prior,
        ofac,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("live COA failed; falling back to skill score:", message);
      const cached = getOracleEvaluation(walletId);
      if (cached) return cached;
      return evaluateWithSkill();
    }
  }

  return evaluateWithSkill();
}

async function evaluateWithRetry(
  evidence: ScoringEvidence,
  trigger: OracleTrigger,
  skills: string[],
  flow: ScoreResult["flow"],
) {
  let last: unknown;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await evaluateWithLiveAgent({
        evidence,
        trigger,
        skills,
        flow,
      });
    } catch (err) {
      last = err;
    }
  }
  throw last instanceof Error ? last : new Error("live COA failed");
}

async function republishTick(walletId: WalletId): Promise<OracleEvaluation> {
  const wallet = getWallet(walletId);
  if (!wallet) {
    throw new Error(`Oracle: wallet ${walletId} not found`);
  }
  const cached = getOracleEvaluation(walletId);
  if (!cached) {
    return reevaluateWallet(walletId, "seed");
  }
  const onChainPublish = await publishScoreToChain(wallet, cached.scoreResult);
  touchScoreAt(wallet.id);
  const evaluation: OracleEvaluation = {
    ...cached,
    onChainPublish,
  };
  setOracleEvaluation(walletId, evaluation);
  return evaluation;
}

async function persistEvaluation(input: {
  wallet: NonNullable<ReturnType<typeof getWallet>>;
  scoreResult: ScoreResult;
  agentRun: OracleEvaluation["agentRun"];
  opinion?: OracleOpinion;
  scoreSource: "skill" | "anthropic";
  opinionSource: "mock" | "anthropic";
  trigger: OracleTrigger;
  prior: number | null;
  ofac: OfacScreenResult;
}): Promise<OracleEvaluation> {
  const { wallet, scoreResult, agentRun, scoreSource, prior, ofac } = input;
  const opinion =
    input.opinion ?? buildOpinionFromScore(wallet, scoreResult, agentRun, ofac);
  const priorFee = prior == null ? null : getOracleFeeBps(wallet.id);
  const shouldWrite = shouldPublishScore({
    neverScored: wallet.neverScored,
    priorScore: prior,
    nextScore: scoreResult.finalScore,
    priorFeeBps: priorFee,
    nextFeeBps: scoreResult.recommendedFeeBps,
    lastScoreAt: getLastScoreAt(wallet.id),
    now: demoNow(),
    stalenessMs: STALENESS_MS,
    force: input.trigger === "tick",
  });

  const onChainPublish = shouldWrite
    ? await publishScoreToChain(wallet, scoreResult)
    : {
        mode: "rpc" as const,
        status: "skipped" as const,
        walletId: wallet.id,
        address: wallet.address,
        score: scoreResult.finalScore,
        hopDistance: wallet.hopDistance ?? 0,
        origin: wallet.originId ?? "",
        feeBps: scoreResult.recommendedFeeBps,
        at: new Date().toISOString(),
      };

  if (shouldWrite) {
    touchScoreAt(wallet.id);
    if (onChainPublish.status === "submitted" && wallet.neverScored) {
      const current = getStore().wallets;
      setWallets({
        ...current,
        [wallet.id]: { ...current[wallet.id], neverScored: false },
      });
    }
  }
  const evaluation: OracleEvaluation = {
    scoreResult,
    opinion,
    agentRun,
    onChainPublish,
    opinionSource: input.opinionSource,
    scoreSource,
    ofacScreen: ofac,
  };
  setOracleEvaluation(wallet.id, evaluation);
  return evaluation;
}

/**
 * Seeds oracle scores for A–D at process start or after reset. Bound E is included.
 */
export async function seedOracleAll(): Promise<void> {
  for (const w of listWallets()) {
    if (w.id === "E" && !isBoundWalletE(w.address)) continue;
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
 * the recipient is Wallet D (deferred keeper: stale score 0 until catch-up).
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

  if (to === "E") {
    return {
      from: fromEval,
      to: getOracleEvaluation(to),
      keeperPending: false,
    };
  }

  // Wallet D: defer updateScore only when a hop landed (A or a tainted peer).
  // Clean C→D / B→D must not write a hop; inflow still fires off the baseline.
  if (to === "D" && getWallet("D")?.hopDistance != null) {
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
 * Cached evaluation, or a live COA run if nothing has been published yet.
 */
export async function ensureOracleEvaluation(
  walletId: WalletId,
): Promise<OracleEvaluation> {
  const wallet = getWallet(walletId);
  let cached = getOracleEvaluation(walletId);
  if (
    isLiveCoaEnabled() &&
    wallet &&
    !wallet.neverScored &&
    !isMockDemoWallet(walletId) &&
    cached?.scoreSource !== "anthropic"
  ) {
    cached = await reevaluateWallet(walletId, "manual");
  }
  cached =
    cached ?? (await reevaluateWallet(walletId, "manual"));
  return applyLiveOpinionIfNeeded(cached);
}
