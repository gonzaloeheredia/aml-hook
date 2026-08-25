/**
 * Virtual Compliance Officer Agent runtime.
 *
 * Presents a live skill pipeline + connected information sources.
 * Findings and scores remain deterministic (fact-scoring / N-hop use case).
 */

import { createHash } from "node:crypto";
import type { Wallet } from "../types.js";
import {
  consultCorpusForWallet,
  type CorpusConsult,
  type NormativeCitation,
} from "./corpus.js";
import type { OracleTrigger } from "./types.js";
import type { OfacScreenResult } from "./ofacScreen.js";
import { ofacFindingText, ofacSourceLine } from "./ofacScreen.js";

export type AgentSkillStep = {
  skill: string;
  status: "ok";
  durationMs: number;
  sources: string[];
  finding: string;
};

export type AgentRun = {
  runId: string;
  agent: "Compliance Officer Agent";
  role: "AI AML analyst · Oracle Keeper";
  trigger: OracleTrigger;
  flow: "FULL" | "INCREMENTAL";
  walletId: string;
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  skills: AgentSkillStep[];
  sourcesConsulted: string[];
  /** In-force corpus documents cited by search_regulations. */
  normativeCitations: NormativeCitation[];
  /** True when search_regulations found no in-force documents. */
  corpusCoverageGap: boolean;
  status: "completed";
};

const SKILL_CATALOG: Record<
  string,
  { sources: string[]; finding: (w: Wallet, trigger: OracleTrigger) => string }
> = {
  "task-swap-intake": {
    sources: ["PoolManager swap intake", "Trusted router IMsgSender subject resolve"],
    finding: (w, t) =>
      `Intake accepted for ${w.accountLabel}; trigger=${t}; subject ${w.address.slice(0, 10)}…`,
  },
  "originator-attribution": {
    sources: ["Internal ledger graph", "ERC-20 P2P transfer index"],
    finding: (w) =>
      w.originId
        ? `Attributed contamination path to origin ${w.originId} (hop=${w.hopDistance ?? 0}).`
        : "No exploit-origin attribution on current graph.",
  },
  "ofac-screening": {
    sources: [
      "OFAC SDN (Treasury sanctions list service)",
      "UN Consolidated Sanctions List",
      "EU Consolidated Financial Sanctions",
    ],
    finding: () =>
      "OFAC SDN exact-address screen pending (injected by the live pipeline).",
  },
  "task-onchain-evidence": {
    sources: [
      "Etherscan account API",
      "Uniswap v4 PoolManager logs",
      "ERC-20 Transfer receipts",
    ],
    finding: (w) =>
      `On-chain evidence pack assembled for ${w.address.slice(0, 10)}… (balances, transfers, pool emits).`,
  },
  "wallet-screening": {
    sources: ["Chainalysis-compatible risk feed", "Internal wallet risk cache"],
    finding: (w) =>
      w.exploitConfirmed
        ? "Wallet flagged confirmed exploit cash-out source (external analysis). Officer writes score 100. Do not fund E from A."
        : w.hopDistance != null
          ? `Indirect exposure screen: ${w.hopDistance}-hop from contaminated origin.`
          : "No elevated counterparty cluster on wallet screen.",
  },
  "swap-behavior-analysis": {
    sources: ["SwapObserved trail", "afterSwap behavioral window"],
    finding: (w) =>
      `Behavioral window reviewed for ${w.accountLabel}; USDC=${w.usdc.toLocaleString("en-US")}.`,
  },
  "typology-detection": {
    sources: ["FATF VA red-flag catalog", "Internal typology engine"],
    finding: (w) =>
      w.exploitConfirmed
        ? "Typology: confirmed exploit cash-out. Hook: WalletBlocked (SCORE_REVERT_BAND)."
        : w.hopDistance === 1
          ? "Typology: high-risk counterparty / one-hop propagation."
          : w.hopDistance === 2
            ? "Typology: medium-risk indirect propagation (2-hop)."
            : "No adverse typology above monitoring threshold.",
  },
  "cross-pool-intelligence": {
    sources: ["Cross-pool report registry", "Shared AML Hook intelligence bus"],
    finding: () =>
      "Cross-pool intelligence query completed; no contradictory clean attestations.",
  },
  "uhi10-use-case": {
    sources: ["UHI10 A–E use-case skill"],
    finding: (w) =>
      w.neverScored
        ? "Use-case: Wallet E is unpublished — do not write a COA score."
        : w.exploitConfirmed
          ? "Use-case: Wallet A exploit score 100, not OFAC, REVERT WalletBlocked."
          : w.hopDistance === 1
            ? "Use-case: 1-hop → ~65 / 800 bps FEE_OVERRIDE; one afterSwap must stay ≤70."
            : w.hopDistance === 2
              ? "Use-case: 2-hop → ~42 / 300 bps FEE_OVERRIDE."
              : "Use-case: published-clean path; Floors A–D stay on the hook.",
  },
  "fact-scoring": {
    sources: ["COA fact-scoring model v1", "N-hop decay policy"],
    finding: (w) =>
      w.exploitConfirmed
        ? "Fact engine override → score 100 (EXPLOIT_PROTOCOL_FUNDS). Pool path is WalletBlocked."
        : w.hopDistance != null
          ? `Fact engine applied N-hop decay at hop ${w.hopDistance}.`
          : "Fact engine baseline clean profile → ALLOW band.",
  },
  "task-swap-decision": {
    sources: ["RiskPolicy band map", "Keeper fee schedule"],
    finding: (w) =>
      w.exploitConfirmed
        ? "Decision draft: REVERT WalletBlocked (score 100 · SCORE_REVERT_BAND)."
        : w.hopDistance === 1
          ? "Decision draft: FEE_OVERRIDE (punitive differential → FeeEscrow)."
          : w.hopDistance === 2
            ? "Decision draft: FEE_OVERRIDE (proportional differential → FeeEscrow)."
            : "Decision draft: ALLOW (standard fee).",
  },
  "search_regulations": {
    sources: ["git corpus via search_regulations"],
    finding: () =>
      "Normative consultation against the git-versioned corpus (see pipeline).",
  },
  "task-regulatory-report": {
    sources: [
      "FinCEN SAR Narrative Guidance model",
      "FATF Rec. 1 / 10 / 15 framing",
    ],
    finding: () =>
      "Opinion + SAR-support annex drafted for Compliance Officer (not filed).",
  },
};

function corpusStep(consult: CorpusConsult): {
  sources: string[];
  finding: string;
} {
  if (consult.coverageGap) {
    return {
      sources: ["git corpus (no in-force documents loaded)"],
      finding:
        "Coverage gap: search_regulations returned no in-force corpus documents. No training-memory cite.",
    };
  }
  return {
    sources: consult.citations.map(
      (c) => `${c.framework} · ${c.title} (${c.id}, ${c.publicationDate})`,
    ),
    finding: `search_regulations indexed ${consult.citations.length} in-force document(s): ${consult.citations.map((c) => c.id).join(", ")}.`,
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function stepDurationMs(skill: string, wallet: Wallet): number {
  // Stable pseudo-latency so the agent feels live without slowing seed too much.
  const h = createHash("sha256")
    .update(`${wallet.id}:${skill}`)
    .digest();
  return 35 + (h[0]! % 55);
}

/**
 * Runs the virtual COA skill pipeline against connected (simulated) sources.
 * @param theater When true, awaits per-skill latency (interactive triggers).
 */
export async function runVirtualAgentPipeline(params: {
  wallet: Wallet;
  trigger: OracleTrigger;
  skills: string[];
  flow: "FULL" | "INCREMENTAL";
  theater?: boolean;
  ofac?: OfacScreenResult;
}): Promise<AgentRun> {
  const { wallet, trigger, skills, flow, theater = false, ofac } = params;
  const started = Date.now();
  const startedAt = new Date(started).toISOString();
  const steps: AgentSkillStep[] = [];
  const sourceSet = new Set<string>();
  const consult = consultCorpusForWallet(wallet);

  for (const skill of skills) {
    const durationMs = stepDurationMs(skill, wallet);
    if (theater) await sleep(durationMs);

    const fromCatalog = SKILL_CATALOG[skill] ?? {
      sources: ["Internal COA skill bus"],
      finding: () => `Skill ${skill} completed.`,
    };
    const step =
      skill === "search_regulations"
        ? corpusStep(consult)
        : skill === "ofac-screening" && ofac
          ? {
              sources: [ofacSourceLine(ofac)],
              finding: ofacFindingText(ofac),
            }
          : {
              sources: fromCatalog.sources,
              finding: fromCatalog.finding(wallet, trigger),
            };

    for (const s of step.sources) sourceSet.add(s);
    steps.push({
      skill,
      status: "ok",
      durationMs,
      sources: step.sources,
      finding: step.finding,
    });
  }

  if (ofac && !skills.includes("ofac-screening")) {
    const sources = [ofacSourceLine(ofac)];
    for (const s of sources) sourceSet.add(s);
    steps.push({
      skill: "ofac-screening",
      status: "ok",
      durationMs: 1,
      sources,
      finding: ofacFindingText(ofac),
    });
  }

  const finished = Date.now();
  const runId = `coa_${createHash("sha256")
    .update(`${wallet.id}:${trigger}:${startedAt}:${flow}`)
    .digest("hex")
    .slice(0, 16)}`;

  return {
    runId,
    agent: "Compliance Officer Agent",
    role: "AI AML analyst · Oracle Keeper",
    trigger,
    flow,
    walletId: wallet.id,
    startedAt,
    finishedAt: new Date(finished).toISOString(),
    durationMs: finished - started,
    skills: steps,
    sourcesConsulted: [...sourceSet],
    normativeCitations: consult.citations,
    corpusCoverageGap: consult.coverageGap,
    status: "completed",
  };
}
