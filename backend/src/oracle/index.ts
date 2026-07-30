/**
 * Public oracle surface for the demo API.
 */

export {
  ensureOracleEvaluation,
  reevaluateAfterBlock,
  reevaluateAfterSwap,
  reevaluateAfterTransfer,
  reevaluateWallet,
  resetOracle,
  seedOracleAll,
} from "./agent.js";
export {
  getOracleEvaluation,
  getOracleScore,
  listOracleEvaluations,
} from "./store.js";
export type { OracleEvaluation, OracleOpinion, ScoreResult } from "./types.js";
