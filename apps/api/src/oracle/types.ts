/**
 * Off-chain oracle types: ScoreResult + Opinion from the COA agent skills.
 * Spec: agents/oracle-coa/skills/fact-scoring.md · task-regulatory-report.md
 */

import type { HookOutput, WalletId } from "../types.js";
import type { NormativeCitation } from "./corpus.js";
import type { OfacScreenResult } from "./ofacScreen.js";
import type { AgentRun } from "./virtualAgent.js";

export type { NormativeCitation } from "./corpus.js";

export type { AgentRun, AgentSkillStep } from "./virtualAgent.js";

export type OracleTrigger =
  | "seed"
  | "transfer"
  | "afterSwap"
  | "blocked"
  | "manual"
  | "tick";

export type FactConfidence = "HIGH" | "MEDIUM" | "LOW";

export type FactEvent = {
  factId: string;
  type: string;
  confidence: FactConfidence;
  baseWeight: number;
  scoreContribution: number;
  regulatoryBasis: string;
  justification: string;
  dimension: "S" | "ST" | "MX" | "NW" | "GEO" | "MT" | "DF";
};

export type ScoreBreakdown = {
  sanctions: number;
  structuring: number;
  mixerExposure: number;
  networkBehavior: number;
  geographicRisk: number;
  defiTypologies: number;
  mitigants: number;
  historicalComponent: number;
};

export type RiskLevel = "BLOCK" | "ELEVATED" | "STANDARD";

export type ScoreResult = {
  walletId: WalletId;
  address: string;
  finalScore: number;
  riskLevel: RiskLevel;
  hookOutput: HookOutput;
  /** COA recommended total fee friction in bps (e.g. 800). On FEE_OVERRIDE the pool keeps ~30 bps; differential goes to FeeEscrow. */
  recommendedFeeBps: number;
  scoreBreakdown: ScoreBreakdown;
  triggeringFacts: FactEvent[];
  regulatoryFlags: {
    type: string;
    description: string;
    recommendation: string;
  }[];
  validity: {
    calculatedAt: string;
    trigger: OracleTrigger;
    nextReview: string;
  };
  auditHash: string;
  skillsApplied: string[];
  flow: "FULL" | "INCREMENTAL";
};

export type OracleOpinion = {
  status: string;
  documentType: string;
  confidence: FactConfidence;
  humanReview: boolean;
  retentionYears: number;
  auditHash: string;
  technicalOpinion: {
    issued: boolean;
    objectAndScope: string;
    riskAndScoring: string;
    typologies: string;
    sanctionsCheck: string;
    sourcesConsulted: string[];
    decisionExecuted: string;
    legalBasis: string;
    recommendations: string;
    traceability: string;
    /** Corpus documents actually used at calculation time (point-in-time). */
    normativeCitations: NormativeCitation[];
  };
  sarAnnex: {
    produced: boolean;
    status: string;
    activityPeriod: string;
    amountInvolved: string;
    operationState: string;
    narrativeDescription: string;
    narrativeAnalysis: string;
    narrativeEvidence: string;
    narrativeConclusion: string;
    warnings: string[];
  } | null;
  decisionRecord: {
    score: string;
    output: HookOutput;
    mainFacts: string;
    basis: string;
    nextReview: string;
  };
  note: string;
};

/** Keeper → ComplianceOracle.updateScore attempt. */
export type ScorePublishResult = {
  mode: "mock" | "rpc";
  status: "recorded" | "submitted" | "failed" | "skipped";
  walletId: WalletId;
  address: string;
  score: number;
  hopDistance: number;
  origin: string;
  feeBps: number;
  at: string;
  txHash?: string;
  error?: string;
};

/** Full oracle evaluation cached per wallet. */
export type OracleEvaluation = {
  scoreResult: ScoreResult;
  opinion: OracleOpinion;
  /** Virtual COA skill run (connected sources; deterministic outcomes). */
  agentRun: AgentRun;
  /** Keeper → ComplianceOracle.updateScore (virtual receipt or rpc tx). */
  onChainPublish?: ScorePublishResult;
  /** Who drafted the Opinion narrative. */
  opinionSource?: "mock" | "anthropic";
  /** Who produced finalScore. Tick republishes the last agent score. */
  scoreSource?: "skill" | "anthropic";
  /** Live OFAC SDN screen that wrote SanctionRegistry on a direct match. */
  ofacScreen?: OfacScreenResult;
};
