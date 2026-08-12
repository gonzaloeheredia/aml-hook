/**
 * Virtual Compliance Officer Agent runtime.
 *
 * Presents a live skill pipeline + connected information sources.
 * Findings and scores remain deterministic (fact-scoring / N-hop use case).
 */

import { createHash } from "node:crypto";
import type { Wallet } from "../types.js";
import type { OracleTrigger } from "./types.js";

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
  status: "completed";
};

const SKILL_CATALOG: Record<
  string,
  { sources: string[]; finding: (w: Wallet, trigger: OracleTrigger) => string }
> = {
  "task-swap-intake": {
    sources: ["PoolManager swap intake", "Router hookData subject resolve"],
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
      "OFAC SDN API",
      "UN Consolidated Sanctions List",
      "EU Consolidated Financial Sanctions",
    ],
    finding: (w) =>
      w.exploitConfirmed
        ? "No direct SDN string match; exploit-source designation applied from keeper threat feed."
        : "Clear on OFAC / UN / EU list screens (live query path).",
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
        ? "Wallet flagged as confirmed exploit cash-out source."
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
        ? "Typology: exploit cash-out / layering precursor."
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
  "fact-scoring": {
    sources: ["COA fact-scoring model v1", "N-hop decay policy"],
    finding: (w) =>
      w.exploitConfirmed
        ? "Fact engine override → score 100 (exploit confirmed)."
        : w.hopDistance != null
          ? `Fact engine applied N-hop decay at hop ${w.hopDistance}.`
          : "Fact engine baseline clean profile → ALLOW band.",
  },
  "task-swap-decision": {
    sources: ["RiskPolicy band map", "Keeper fee schedule"],
    finding: (w) =>
      w.exploitConfirmed
        ? "Decision draft: REVERT (fail-closed)."
        : w.hopDistance === 1
          ? "Decision draft: FEE_OVERRIDE (punitive differential → FeeEscrow)."
          : w.hopDistance === 2
            ? "Decision draft: FEE_OVERRIDE (proportional differential → FeeEscrow)."
            : "Decision draft: ALLOW (standard fee).",
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
}): Promise<AgentRun> {
  const { wallet, trigger, skills, flow, theater = false } = params;
  const started = Date.now();
  const startedAt = new Date(started).toISOString();
  const steps: AgentSkillStep[] = [];
  const sourceSet = new Set<string>();

  for (const skill of skills) {
    const meta = SKILL_CATALOG[skill] ?? {
      sources: ["Internal COA skill bus"],
      finding: () => `Skill ${skill} completed.`,
    };
    const durationMs = stepDurationMs(skill, wallet);
    if (theater) await sleep(durationMs);
    for (const s of meta.sources) sourceSet.add(s);
    steps.push({
      skill,
      status: "ok",
      durationMs,
      sources: meta.sources,
      finding: meta.finding(wallet, trigger),
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
    status: "completed",
  };
}
