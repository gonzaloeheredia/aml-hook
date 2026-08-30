/**
 * Live fact-scoring: Claude applies N-hop decay and accumulates the oracle record.
 * The keeper publishes whatever ScoreResult the agent returns (clamped 0–100).
 */

import { createHash } from "node:crypto";
import {
  capPublishedFeeBps,
} from "./onchainPublisher.js";
import {
  completeCoaJson,
  isLiveCoaEnabled,
  overlayOpinion,
} from "./liveOpinion.js";
import { buildOpinionFromScore } from "./report.js";
import {
  decisionFromScore,
  toHookOutput,
} from "../scoring.js";
import type { HookEvent, TransferRecord, Wallet } from "../types.js";
import type { AgentRun, AgentSkillStep } from "./virtualAgent.js";
import type { NormativeCitation } from "./corpus.js";
import type { OfacScreenResult } from "./ofacScreen.js";
import { ofacFindingText, ofacSourceLine } from "./ofacScreen.js";
import type {
  FactEvent,
  OracleOpinion,
  OracleTrigger,
  ScoreBreakdown,
  ScoreResult,
} from "./types.js";

export type LiveScoreRun = {
  scoreResult: ScoreResult;
  opinion: OracleOpinion;
  agentRun: AgentRun;
  model: string;
  durationMs: number;
  citations: number;
};

function scoringSystemPrompt(): string {
  return `You are the AML Hook Compliance Officer Agent.
Execute fact-scoring, task-swap-decision, and task-regulatory-report.
TypeScript does not precompute scores, fees, or Opinion text. You emit those.
The keeper publishes your finalScore and recommendedFeeBps to ComplianceOracle;
AMLHook.beforeSwap and FeeEscrow read that row.

Before you emit finalScore, call consult_skill with name uhi10-use-case.
That skill is docs/Use_Case.md in agent form (exploit, N-hop,
unpublished E, D deferral, LP floors, fee bps).
If the subject is not an Anvil A–E key or chain is 11155111, also call
consult_skill with name uhi10-sepolia. A never-written address is Wallet E:
do not publish it on Anvil, and do not auto-publish a new Sepolia EOA.
Do not copy Anvil hops onto Sepolia. If a weight, band, or floor is still
unclear, consult_skill again (fact-scoring, task-swap-decision). Do not
invent a hop table from memory when the skill is available.

Call search_regulations at least once before legalBasis. Never cite norms from
training memory. If the tool is empty, declare a coverage gap.
A live OFAC SDN exact-address screen is in the payload (ofac). Use it. Call
screen_ofac for another address if needed. Do not invent an SDN match.
Demo wallets A–E are not OFAC-listed unless ofac.subject.match is true.
A live SDN match is hook Layer 1 (SanctionRegistry → SanctionHit), not a use-case wallet.
Do not list skill filenames in Opinion sources.

Reply with a single JSON object (no markdown):

{
  "finalScore": 0,
  "recommendedFeeBps": 0,
  "scoreBreakdown": {},
  "triggeringFacts": [],
  "regulatoryFlags": [],
  "skills": [{ "skill": "uhi10-use-case", "finding": "string", "sources": ["string"] }],
  "objectAndScope": "string",
  "riskAndScoring": "string",
  "typologies": "string",
  "sanctionsCheck": "string",
  "sourcesConsulted": ["string: venues, no skill filenames"],
  "decisionExecuted": "string",
  "legalBasis": "string: corpus ids + publicationDate",
  "recommendations": "string",
  "traceability": "string",
  "sarAnnex": null or {
    "narrativeDescription": "string",
    "narrativeAnalysis": "string",
    "narrativeEvidence": "string",
    "narrativeConclusion": "string"
  }
}
`;
}

export type ScoringEvidence = {
  wallet: Wallet;
  priorScore: number | null;
  transfers: TransferRecord[];
  events: HookEvent[];
  sanctions: {
    subjectListed: boolean;
    listedCounterparties: string[];
    listedContractsTouched: string[];
  };
  ofac?: OfacScreenResult;
};

/**
 * Builds the raw dossier. No hop score is precomputed.
 */
export function scoringEvidencePayload(evidence: ScoringEvidence): string {
  const { wallet } = evidence;
  const walletEvents = evidence.events.filter((e) => e.walletId === wallet.id);
  const legs = evidence.transfers.filter(
    (t) => t.from === wallet.id || t.to === wallet.id,
  );
  return JSON.stringify(
    {
      wallet: {
        id: wallet.id,
        accountLabel: wallet.accountLabel,
        address: wallet.address,
        hopDistance: wallet.hopDistance,
        originId: wallet.originId,
        exploitConfirmed: wallet.exploitConfirmed,
        neverScored: wallet.neverScored,
        usdc: wallet.usdc,
      },
      priorScore: evidence.priorScore,
      p2pTransfers: legs.map((t) => ({
        from: t.from,
        to: t.to,
        amountUsd: t.amountUsd,
        hopDistance: t.hopDistance,
        at: t.at,
      })),
      afterSwapEvents: walletEvents.map((e) => ({
        kind: e.kind,
        decision: e.decision,
        amountUsd: e.amountUsd,
        feeBps: e.feeBps,
        at: e.at,
      })),
      sanctions: evidence.sanctions,
      ofac: evidence.ofac
        ? {
            finding: ofacFindingText(evidence.ofac),
            subjectMatch: evidence.ofac.subject.match,
            source: evidence.ofac.snapshot.source,
            addressCount: evidence.ofac.snapshot.addressCount,
            fetchedAt: evidence.ofac.snapshot.fetchedAt,
            publishedAt: evidence.ofac.snapshot.publishedAt,
            registryTx: evidence.ofac.subject.registry?.txHash ?? null,
          }
        : null,
    },
    null,
    2,
  );
}

function emptyBreakdown(): ScoreBreakdown {
  return {
    sanctions: 0,
    structuring: 0,
    mixerExposure: 0,
    networkBehavior: 0,
    geographicRisk: 0,
    defiTypologies: 0,
    mitigants: 0,
    historicalComponent: 0,
  };
}

function parseFacts(raw: unknown): FactEvent[] {
  if (!Array.isArray(raw)) return [];
  const out: FactEvent[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const f = item as Record<string, unknown>;
    const type = typeof f.type === "string" ? f.type : "";
    if (!type) continue;
    const dim = String(f.dimension ?? "NW");
    const dimension = (
      ["S", "ST", "MX", "NW", "GEO", "MT", "DF"] as const
    ).includes(dim as FactEvent["dimension"])
      ? (dim as FactEvent["dimension"])
      : "NW";
    const conf = String(f.confidence ?? "HIGH");
    const confidence: FactEvent["confidence"] =
      conf === "MEDIUM" || conf === "LOW" ? conf : "HIGH";
    const baseWeight = Number(f.baseWeight ?? 0);
    const scoreContribution = Number(f.scoreContribution ?? baseWeight);
    out.push({
      factId:
        typeof f.factId === "string"
          ? f.factId
          : `${type}-${out.length}`,
      type,
      confidence,
      baseWeight: Number.isFinite(baseWeight) ? baseWeight : 0,
      scoreContribution: Number.isFinite(scoreContribution)
        ? scoreContribution
        : 0,
      regulatoryBasis:
        typeof f.regulatoryBasis === "string" ? f.regulatoryBasis : "",
      justification: typeof f.justification === "string" ? f.justification : "",
      dimension,
    });
  }
  return out;
}

function nextReviewIso(score: number): string {
  const days = score >= 71 ? 0 : score >= 51 ? 7 : score >= 21 ? 30 : 90;
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString();
}

/**
 * Normalizes a model JSON blob into a publishable ScoreResult.
 * Bands (ALLOW / FEE_OVERRIDE / REVERT) follow the hook map from finalScore.
 */
export function scoreResultFromAgentDraft(
  draft: Record<string, unknown>,
  wallet: Wallet,
  trigger: OracleTrigger,
  skillsApplied: string[],
  flow: ScoreResult["flow"],
): ScoreResult {
  const nested =
    draft.scoreResult && typeof draft.scoreResult === "object"
      ? (draft.scoreResult as Record<string, unknown>)
      : draft;
  const rawScore = Number(nested.finalScore);
  if (!Number.isFinite(rawScore)) {
    throw new Error("live score: missing finalScore");
  }
  const finalScore = Math.max(0, Math.min(100, Math.round(rawScore)));
  const hookOutput = toHookOutput(decisionFromScore(finalScore));
  const riskLevel: ScoreResult["riskLevel"] =
    finalScore >= 71 ? "BLOCK" : finalScore >= 31 ? "ELEVATED" : "STANDARD";

  let recommendedFeeBps = Number(nested.recommendedFeeBps);
  if (!Number.isFinite(recommendedFeeBps)) {
    recommendedFeeBps = hookOutput === "REVERT" ? 0 : hookOutput === "ALLOW" ? 30 : 300;
  }
  if (hookOutput === "REVERT") recommendedFeeBps = 0;
  recommendedFeeBps = capPublishedFeeBps(recommendedFeeBps);

  const breakdownRaw =
    nested.scoreBreakdown && typeof nested.scoreBreakdown === "object"
      ? (nested.scoreBreakdown as Record<string, unknown>)
      : {};
  const base = emptyBreakdown();
  const scoreBreakdown: ScoreBreakdown = {
    sanctions: Number(breakdownRaw.sanctions) || base.sanctions,
    structuring: Number(breakdownRaw.structuring) || base.structuring,
    mixerExposure: Number(breakdownRaw.mixerExposure) || base.mixerExposure,
    networkBehavior: Number(breakdownRaw.networkBehavior) || base.networkBehavior,
    geographicRisk: Number(breakdownRaw.geographicRisk) || base.geographicRisk,
    defiTypologies: Number(breakdownRaw.defiTypologies) || base.defiTypologies,
    mitigants: Number(breakdownRaw.mitigants) || base.mitigants,
    historicalComponent:
      Number(breakdownRaw.historicalComponent) || base.historicalComponent,
  };

  const triggeringFacts = parseFacts(nested.triggeringFacts);
  const flagsRaw = Array.isArray(nested.regulatoryFlags)
    ? nested.regulatoryFlags
    : [];
  const regulatoryFlags = flagsRaw
    .filter((f): f is Record<string, unknown> => !!f && typeof f === "object")
    .map((f) => ({
      type: String(f.type ?? "NOTE"),
      description: String(f.description ?? ""),
      recommendation: String(f.recommendation ?? ""),
    }));

  const payload = JSON.stringify({
    wallet: wallet.id,
    finalScore,
    recommendedFeeBps,
    triggeringFacts,
    trigger,
  });
  const auditHash = `0x${createHash("sha256").update(payload).digest("hex").slice(0, 16)}`;

  return {
    walletId: wallet.id,
    address: wallet.address,
    finalScore,
    riskLevel,
    hookOutput,
    recommendedFeeBps,
    scoreBreakdown,
    triggeringFacts,
    regulatoryFlags,
    validity: {
      calculatedAt: new Date().toISOString(),
      trigger,
      nextReview: nextReviewIso(finalScore),
    },
    auditHash,
    skillsApplied,
    flow,
  };
}

function parseSkillSteps(
  raw: unknown,
  fallback: string[],
  durationMs: number,
  model: string,
): AgentSkillStep[] {
  const fromModel = Array.isArray(raw)
    ? raw.filter((s): s is Record<string, unknown> => !!s && typeof s === "object")
    : [];
  const names =
    fromModel.length > 0
      ? fromModel.map((s) => String(s.skill ?? "fact-scoring"))
      : fallback;
  return names.map((skill, i) => {
    const row = fromModel[i];
    const sources = Array.isArray(row?.sources)
      ? row.sources.filter((x): x is string => typeof x === "string")
      : [`Anthropic ${model}`];
    return {
      skill,
      status: "ok" as const,
      durationMs: Math.max(1, Math.round(durationMs / names.length)),
      sources: sources.length ? sources : [`Anthropic ${model}`],
      finding:
        typeof row?.finding === "string" && row.finding.trim()
          ? row.finding.trim()
          : `Live COA completed ${skill}.`,
    };
  });
}

function buildLiveAgentRun(input: {
  wallet: Wallet;
  trigger: OracleTrigger;
  flow: ScoreResult["flow"];
  skills: string[];
  draft: Record<string, unknown>;
  citations: NormativeCitation[];
  model: string;
  durationMs: number;
  ofac?: OfacScreenResult;
}): AgentRun {
  const started = Date.now() - input.durationMs;
  const steps = parseSkillSteps(
    input.draft.skills,
    input.skills,
    input.durationMs,
    input.model,
  );
  const sourceSet = new Set<string>([`Anthropic ${input.model}`]);
  for (const s of steps) for (const src of s.sources) sourceSet.add(src);
  for (const c of input.citations) {
    sourceSet.add(`${c.framework} · ${c.title} (${c.id}, ${c.publicationDate})`);
  }
  if (input.ofac) sourceSet.add(ofacSourceLine(input.ofac));
  return {
    runId: `coa_${createHash("sha256")
      .update(`${input.wallet.id}:${input.trigger}:${started}:${input.flow}`)
      .digest("hex")
      .slice(0, 16)}`,
    agent: "Compliance Officer Agent",
    role: "AI AML analyst · Oracle Keeper",
    trigger: input.trigger,
    flow: input.flow,
    walletId: input.wallet.id,
    startedAt: new Date(started).toISOString(),
    finishedAt: new Date().toISOString(),
    durationMs: input.durationMs,
    skills: steps,
    sourcesConsulted: [...sourceSet],
    normativeCitations: input.citations,
    corpusCoverageGap: input.citations.length === 0,
    status: "completed",
  };
}

/**
 * Live COA: score, fee, Opinion, and skill findings from Claude.
 * The keeper publishes finalScore + recommendedFeeBps; hook / FeeEscrow read the row.
 */
export async function evaluateWithLiveAgent(input: {
  evidence: ScoringEvidence;
  trigger: OracleTrigger;
  skills: string[];
  flow: ScoreResult["flow"];
}): Promise<LiveScoreRun> {
  if (!isLiveCoaEnabled()) {
    throw new Error("live score: COA disabled");
  }
  const live = await completeCoaJson({
    system: scoringSystemPrompt(),
    user: `Evaluate this wallet. Call consult_skill (uhi10-use-case) before you emit finalScore. If this is not an Anvil A–E demo key, also consult_skill (uhi10-sepolia). Never publish Wallet E. You emit the score, recommendedFeeBps, Opinion, and skill findings. TypeScript will only publish what you return.\n\n${scoringEvidencePayload(input.evidence)}`,
  });
  const scoreResult = scoreResultFromAgentDraft(
    live.draft,
    input.evidence.wallet,
    input.trigger,
    input.skills,
    input.flow,
  );
  const agentRun = buildLiveAgentRun({
    wallet: input.evidence.wallet,
    trigger: input.trigger,
    flow: input.flow,
    skills: input.skills,
    draft: live.draft,
    citations: live.citations,
    model: live.model,
    durationMs: live.durationMs,
    ofac: input.evidence.ofac,
  });
  const skeleton = buildOpinionFromScore(
    input.evidence.wallet,
    scoreResult,
    agentRun,
    input.evidence.ofac,
  );
  return {
    scoreResult,
    opinion: overlayOpinion(
      skeleton,
      live.draft,
      live.citations,
      live.model,
    ),
    agentRun,
    model: live.model,
    durationMs: live.durationMs,
    citations: live.citations.length,
  };
}
