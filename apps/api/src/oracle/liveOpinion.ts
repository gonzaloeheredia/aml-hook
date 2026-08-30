/**
 * Live Compliance Officer via Anthropic.
 *
 * Transfer / afterSwap / block: Claude scores (liveScore.ts). This module
 * drafts the operator Opinion on GET. Failures keep the template Opinion.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import type { Wallet } from "../types.js";
import {
  getActiveVersionAt,
  searchRegulations,
  type CorpusFramework,
  type NormativeCitation,
} from "./corpus.js";
import { consultSkill, listSkillNames } from "./skills.js";
import { screenOfacAddress } from "./ofacSdn.js";
import { ofacFindingText, screenWalletOfac, type OfacScreenResult } from "./ofacScreen.js";
import { getWallet, listTransfers } from "../store.js";
import { setOracleEvaluation } from "./store.js";
import type { OracleEvaluation, OracleOpinion } from "./types.js";
import type { AgentRun } from "./virtualAgent.js";
import { counterpartiesOf } from "./factScoring.js";

const MAX_TOOL_ROUNDS = 8;
const CORPUS_FRAMEWORKS = new Set([
  "FATF",
  "OFAC",
  "MICA",
  "TFR",
  "FINCEN",
  "TREASURY",
  "WOLFSBERG",
]);

export type OpinionSource = "mock" | "anthropic";

const inflight = new Map<string, Promise<OracleEvaluation>>();

/**
 * True when a key is loaded and tests / COA_LIVE=0 have not disabled the loop.
 */
export function isLiveCoaEnabled(): boolean {
  if (process.env.COA_LIVE === "0") return false;
  if (process.env.npm_lifecycle_event === "test") return false;
  return Boolean(process.env.ANTHROPIC_API_KEY?.trim());
}

/**
 * Anthropic model id. Override with ANTHROPIC_MODEL.
 */
export function anthropicModel(): string {
  return process.env.ANTHROPIC_MODEL?.trim() || "claude-sonnet-4-5";
}

function repoRoot(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  return join(here, "..", "..", "..", "..");
}

function loadSystemPrompt(): string {
  const path = join(repoRoot(), "agents", "oracle-coa", "prompts", "system.md");
  const base = existsSync(path)
    ? readFileSync(path, "utf8")
    : "You are the AML Hook Compliance Officer Agent.";
  return `${base}

## Live Opinion task

The numeric score and hook output are already computed. Do not change them.
Call \`search_regulations\` at least once before you write legalBasis.
A live OFAC SDN exact-address screen is already in the payload (\`ofac\`).
Use it for sanctionsCheck. You may call \`screen_ofac\` for another address.
Do not invent an SDN hit. Demo wallets A–E are not OFAC-listed unless
\`ofac.subject.match\` is true (Wallet A is an exploit, not an SDN match).
A live SDN match is hook Layer 1 (SanctionRegistry → SanctionHit), not a
use-case wallet and not WalletBlocked.
If the frozen score looks inconsistent with wallets A–E or the use-case
floors, call \`consult_skill\` with name \`uhi10-use-case\` (and
\`uhi10-sepolia\` if the subject is not an Anvil A–E key). Do not change
the published score. Never-scored is Floor A, not a COA 0.
Cite only documents returned by that tool (git corpus). Never fill norms from
training memory. If the tool returns nothing, declare a coverage gap.

After tool use, reply with a single JSON object (no markdown) using this shape:

{
  "objectAndScope": "string (WHO)",
  "riskAndScoring": "string (WHY)",
  "typologies": "string (WHAT)",
  "sanctionsCheck": "string (WHEN)",
  "sourcesConsulted": ["string (WHERE: venue / evidence, no skill names)"],
  "decisionExecuted": "string (HOW)",
  "legalBasis": "string: cite corpus ids with publicationDate",
  "recommendations": "string: for the pool Compliance Officer only",
  "traceability": "string",
  "sarAnnex": null or {
    "narrativeDescription": "string",
    "narrativeAnalysis": "string",
    "narrativeEvidence": "string",
    "narrativeConclusion": "string"
  }
}

Do not list skill filenames. Do not claim a FinCEN filing. The agent never files.
`;
}

const TOOLS: Anthropic.Tool[] = [
  {
    name: "search_regulations",
    description:
      "Search the git-versioned regulatory corpus. Returns only loaded documents. Use asOf (YYYY-MM-DD) to reconstruct the in-force text on a past fact date.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Natural-language or keyword query" },
        asOf: {
          type: "string",
          description: "Optional ISO date; includes superseded docs in force that day",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "get_active_version_at",
    description:
      "Return the corpus document in force for a framework+series on a given date.",
    input_schema: {
      type: "object",
      properties: {
        framework: {
          type: "string",
          description: "FATF | OFAC | MICA | TFR | FINCEN | TREASURY | WOLFSBERG",
        },
        series: { type: "string" },
        date: { type: "string", description: "ISO date or datetime" },
      },
      required: ["framework", "series", "date"],
    },
  },
  {
    name: "consult_skill",
    description:
      "Load a COA skill from agents/oracle-coa/skills. When hop decay, Wallet A exploit, unpublished E, deferred D, LP floors, or fee bps is unclear, call with name uhi10-use-case. For Sepolia / non-demo subjects call uhi10-sepolia. Omit name to list skills.",
    input_schema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description:
            "Kebab-case skill id, e.g. uhi10-use-case, uhi10-sepolia, fact-scoring, task-swap-decision",
        },
      },
    },
  },
  {
    name: "screen_ofac",
    description:
      "Exact-address screen against the live OFAC SDN ETH/EVM address set. Does not change the published score. Direct matches are written to SanctionRegistry by the COA writer outside this tool.",
    input_schema: {
      type: "object",
      properties: {
        address: {
          type: "string",
          description: "0x-prefixed 20-byte address to screen",
        },
      },
      required: ["address"],
    },
  },
];

function asCitation(hit: NormativeCitation): NormativeCitation {
  return {
    id: hit.id,
    title: hit.title,
    framework: hit.framework,
    series: hit.series,
    publicationDate: hit.publicationDate,
    retrievedAt: hit.retrievedAt,
    sha256: hit.sha256,
  };
}

async function executeTool(
  name: string,
  input: Record<string, unknown>,
  citations: Map<string, NormativeCitation>,
): Promise<unknown> {
  if (name === "search_regulations") {
    const query = String(input.query ?? "");
    const asOf = input.asOf ? String(input.asOf) : undefined;
    const hits = searchRegulations(query, { asOf, limit: 8 });
    for (const hit of hits) citations.set(hit.id, asCitation(hit));
    return {
      hits: hits.map((h) => ({
        id: h.id,
        title: h.title,
        framework: h.framework,
        series: h.series,
        publicationDate: h.publicationDate,
        retrievedAt: h.retrievedAt,
        sha256: h.sha256,
        excerpt: h.excerpt,
      })),
    };
  }
  if (name === "get_active_version_at") {
    const framework = String(input.framework ?? "").toUpperCase();
    const series = String(input.series ?? "");
    const date = String(input.date ?? "");
    if (!CORPUS_FRAMEWORKS.has(framework)) {
      return { error: `unknown framework ${framework}` };
    }
    const doc = getActiveVersionAt(
      framework as CorpusFramework,
      series,
      date,
    );
    if (!doc) return { document: null };
    const cite = asCitation(doc);
    citations.set(cite.id, cite);
    return { document: cite };
  }
  if (name === "consult_skill") {
    const skillName = String(input.name ?? "").trim();
    if (!skillName) {
      return { skills: listSkillNames() };
    }
    return consultSkill(skillName);
  }
  if (name === "screen_ofac") {
    const address = String(input.address ?? "");
    const hit = await screenOfacAddress(address);
    return {
      address: hit.address,
      match: hit.match,
      list: hit.match ? "OFAC_SDN" : null,
      snapshot: hit.snapshot,
    };
  }
  return { error: `unknown tool ${name}` };
}

/**
 * Runs the COA tool loop and returns the first JSON object in the model reply.
 */
export async function completeCoaJson(params: {
  system: string;
  user: string;
}): Promise<{
  draft: Record<string, unknown>;
  citations: NormativeCitation[];
  model: string;
  durationMs: number;
}> {
  const apiKey = process.env.ANTHROPIC_API_KEY?.trim();
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY missing");
  }
  const model = anthropicModel();
  const client = new Anthropic({ apiKey });
  const citations = new Map<string, NormativeCitation>();
  const started = Date.now();
  const messages: Anthropic.MessageParam[] = [
    { role: "user", content: params.user },
  ];

  let text = "";
  for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
    const resp = await client.messages.create({
      model,
      max_tokens: 4096,
      system: params.system,
      tools: TOOLS,
      messages,
    });

    if (resp.stop_reason === "tool_use") {
      messages.push({ role: "assistant", content: resp.content });
      const toolResults: Anthropic.ToolResultBlockParam[] = [];
      for (const block of resp.content) {
        if (block.type !== "tool_use") continue;
        const input =
          block.input && typeof block.input === "object"
            ? (block.input as Record<string, unknown>)
            : {};
        const result = await executeTool(block.name, input, citations);
        toolResults.push({
          type: "tool_result",
          tool_use_id: block.id,
          content: JSON.stringify(result),
        });
      }
      messages.push({ role: "user", content: toolResults });
      continue;
    }

    text = resp.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("\n");
    break;
  }

  if (!text.trim()) {
    throw new Error("live COA: empty model reply");
  }

  return {
    draft: extractJsonObject(text),
    citations: [...citations.values()],
    model,
    durationMs: Date.now() - started,
  };
}

export function extractJsonObject(text: string): Record<string, unknown> {
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const raw = (fence ? fence[1] : text).trim();
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) {
    throw new Error("live COA: model reply had no JSON object");
  }
  const parsed = JSON.parse(raw.slice(start, end + 1)) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("live COA: JSON root is not an object");
  }
  return parsed as Record<string, unknown>;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

export function overlayOpinion(
  base: OracleOpinion,
  draft: Record<string, unknown>,
  citations: NormativeCitation[],
  model: string,
): OracleOpinion {
  const nested =
    draft.technicalOpinion && typeof draft.technicalOpinion === "object"
      ? (draft.technicalOpinion as Record<string, unknown>)
      : draft;
  const tech = base.technicalOpinion;
  const sources = Array.isArray(nested.sourcesConsulted)
    ? nested.sourcesConsulted.filter((s): s is string => typeof s === "string")
    : tech.sourcesConsulted;

  let sarAnnex = base.sarAnnex;
  const sarDraft = draft.sarAnnex;
  if (sarAnnex && sarDraft && typeof sarDraft === "object") {
    const s = sarDraft as Record<string, unknown>;
    sarAnnex = {
      ...sarAnnex,
      narrativeDescription:
        str(s.narrativeDescription) ?? sarAnnex.narrativeDescription,
      narrativeAnalysis: str(s.narrativeAnalysis) ?? sarAnnex.narrativeAnalysis,
      narrativeEvidence: str(s.narrativeEvidence) ?? sarAnnex.narrativeEvidence,
      narrativeConclusion:
        str(s.narrativeConclusion) ?? sarAnnex.narrativeConclusion,
    };
  }

  return {
    ...base,
    technicalOpinion: {
      ...tech,
      objectAndScope: str(nested.objectAndScope) ?? tech.objectAndScope,
      riskAndScoring: str(nested.riskAndScoring) ?? tech.riskAndScoring,
      typologies: str(nested.typologies) ?? tech.typologies,
      sanctionsCheck: str(nested.sanctionsCheck) ?? tech.sanctionsCheck,
      sourcesConsulted: sources.length ? sources : tech.sourcesConsulted,
      decisionExecuted: str(nested.decisionExecuted) ?? tech.decisionExecuted,
      legalBasis: str(nested.legalBasis) ?? tech.legalBasis,
      recommendations: str(nested.recommendations) ?? tech.recommendations,
      traceability: str(nested.traceability) ?? tech.traceability,
      normativeCitations: citations,
    },
    sarAnnex,
    note: `${base.note} Live COA via Anthropic ${model}.`,
  };
}

function caseBrief(
  wallet: Wallet,
  evaluation: OracleEvaluation,
  ofac?: OfacScreenResult,
): string {
  const score = evaluation.scoreResult;
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
      ofac: ofac
        ? {
            finding: ofacFindingText(ofac),
            subjectMatch: ofac.subject.match,
            source: ofac.snapshot.source,
            addressCount: ofac.snapshot.addressCount,
            fetchedAt: ofac.snapshot.fetchedAt,
            publishedAt: ofac.snapshot.publishedAt,
            registryWrote: ofac.subject.registry?.ok && !ofac.subject.registry.skipped,
            counterparties: ofac.counterparties
              .filter((c) => c.match)
              .map((c) => c.address),
          }
        : null,
      score: {
        finalScore: score.finalScore,
        riskLevel: score.riskLevel,
        hookOutput: score.hookOutput,
        recommendedFeeBps: score.recommendedFeeBps,
        triggeringFacts: score.triggeringFacts.map((f) => ({
          type: f.type,
          confidence: f.confidence,
          regulatoryBasis: f.regulatoryBasis,
          justification: f.justification,
          dimension: f.dimension,
        })),
        regulatoryFlags: score.regulatoryFlags,
        calculatedAt: score.validity.calculatedAt,
        auditHash: score.auditHash,
      },
    },
    null,
    2,
  );
}

async function draftLiveOpinion(
  wallet: Wallet,
  evaluation: OracleEvaluation,
): Promise<{
  opinion: OracleOpinion;
  citations: NormativeCitation[];
  model: string;
  durationMs: number;
}> {
  const ofac = evaluation.ofacScreen;
  const live = await completeCoaJson({
    system: loadSystemPrompt(),
    user: `Draft the operator Opinion for this evaluation. Frozen score/output must stay as given.\n\n${caseBrief(wallet, evaluation, ofac)}`,
  });
  return {
    opinion: overlayOpinion(
      evaluation.opinion,
      live.draft,
      live.citations,
      live.model,
    ),
    citations: live.citations,
    model: live.model,
    durationMs: live.durationMs,
  };
}

function withLiveRun(
  run: AgentRun,
  citations: NormativeCitation[],
  model: string,
  durationMs: number,
): AgentRun {
  const sourceSet = new Set(run.sourcesConsulted);
  sourceSet.add(`Anthropic ${model}`);
  for (const c of citations) {
    sourceSet.add(`${c.framework} · ${c.title} (${c.id}, ${c.publicationDate})`);
  }
  return {
    ...run,
    durationMs: run.durationMs + durationMs,
    finishedAt: new Date().toISOString(),
    sourcesConsulted: [...sourceSet],
    normativeCitations: citations.length ? citations : run.normativeCitations,
    corpusCoverageGap: citations.length === 0,
    skills: [
      ...run.skills,
      {
        skill: "live-opinion",
        status: "ok",
        durationMs,
        sources: [`Anthropic ${model}`, "git corpus via search_regulations"],
        finding: citations.length
          ? `Live Opinion drafted. Corpus cites: ${citations.map((c) => c.id).join(", ")}.`
          : "Live Opinion drafted. Coverage gap: search_regulations returned no documents.",
      },
    ],
  };
}

/**
 * Replaces the mock Opinion with a live Claude draft when the API key is set.
 * Score is unchanged. Failures keep the mock Opinion.
 */
export async function applyLiveOpinionIfNeeded(
  evaluation: OracleEvaluation,
): Promise<OracleEvaluation> {
  if (!isLiveCoaEnabled()) return evaluation;
  if (evaluation.opinionSource === "anthropic") return evaluation;

  const walletId = evaluation.scoreResult.walletId;
  const pending = inflight.get(walletId);
  if (pending) return pending;

  const job = (async () => {
    const wallet = getWallet(walletId);
    if (!wallet) return evaluation;
    try {
      const ofac =
        evaluation.ofacScreen ??
        (await screenWalletOfac({
          subject: wallet.address,
          counterparties: counterpartiesOf(wallet, listTransfers()),
        }));
      const base: OracleEvaluation = {
        ...evaluation,
        ofacScreen: ofac,
      };
      const live = await draftLiveOpinion(wallet, base);
      const next: OracleEvaluation = {
        ...base,
        opinion: live.opinion,
        agentRun: withLiveRun(
          base.agentRun,
          live.citations,
          live.model,
          live.durationMs,
        ),
        opinionSource: "anthropic",
      };
      setOracleEvaluation(walletId, next);
      return next;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("live COA failed; keeping mock Opinion:", message);
      return evaluation;
    }
  })().finally(() => {
    inflight.delete(walletId);
  });

  inflight.set(walletId, job);
  return job;
}
