/**
 * Off-chain oracle types — ScoreResult + dictamen from the COA agent skills.
 * Spec: agents/oracle-coa/skills/fact-scoring.md · task-regulatory-report.md
 */

import type { HookOutput, WalletId } from "../types.js";

export type OracleTrigger =
  | "seed"
  | "transfer"
  | "afterSwap"
  | "blocked"
  | "manual";

export type FactConfidence = "HIGH" | "MEDIUM" | "LOW";

export type FactEvent = {
  fact_id: string;
  type: string;
  confidence: FactConfidence;
  base_weight: number;
  contribucion_score: number;
  base_regulatoria: string;
  justificacion: string;
  dimension: "S" | "ST" | "MX" | "NW" | "GEO" | "MT" | "DF";
};

export type ScoreBreakdown = {
  sanciones: number;
  structuring: number;
  exposicion_mixer: number;
  comportamiento_red: number;
  riesgo_geografico: number;
  tipologias_defi: number;
  mitigantes: number;
  componente_historico: number;
};

export type ScoreResult = {
  walletId: WalletId;
  address: string;
  score_final: number;
  nivel_riesgo: "BLOQUEO" | "ELEVADO" | "ESTANDAR";
  salida_hook: HookOutput;
  score_breakdown: ScoreBreakdown;
  hechos_disparadores: FactEvent[];
  flags_regulatorios: {
    tipo: string;
    descripcion: string;
    recomendacion: string;
  }[];
  vigencia: {
    calculado_en: string;
    trigger: OracleTrigger;
    proxima_revision: string;
  };
  audit_hash: string;
  skills_applied: string[];
  flow: "FULL" | "INCREMENTAL";
};

export type OracleDictamen = {
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

/** Full oracle evaluation cached per wallet. */
export type OracleEvaluation = {
  scoreResult: ScoreResult;
  dictamen: OracleDictamen;
};
