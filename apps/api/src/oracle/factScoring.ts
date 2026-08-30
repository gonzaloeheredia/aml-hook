/**
 * Fact-scoring engine implementing agents/oracle-coa/skills/fact-scoring.md.
 *
 * Wallet A is locked at 100 (protocol exploit). Other wallets accumulate from
 * the oracle record: SanctionRegistry hits, P2P contamination, and afterSwap
 * SwapObserved / WalletBlocked emits. The hop graph is one fact among those.
 * It does not replace the running record.
 */

import { createHash } from "node:crypto";
import {
  DECAY_FACTOR,
  ORIGIN_EXPLOIT_SCORE,
  decisionFromScore,
  feeBpsFromHop,
  toHookOutput,
} from "../scoring.js";
import type { HookEvent, TransferRecord, Wallet, WalletId } from "../types.js";
import { getWallet } from "../store.js";
import {
  demoContractAddresses,
  isSanctionedAddress,
} from "../chain/sanctions.js";
import type { OfacScreenResult } from "./ofacScreen.js";
import type {
  FactEvent,
  OracleTrigger,
  ScoreBreakdown,
  ScoreResult,
} from "./types.js";

/**
 * Builds admissible FactEvents for a wallet from the oracle record
 * (ledger + afterSwap emits + optional SanctionRegistry hits).
 */
export function buildFacts(
  wallet: Wallet,
  transfers: TransferRecord[],
  events: HookEvent[],
  extraFacts: FactEvent[] = [],
): FactEvent[] {
  const facts: FactEvent[] = [];
  const walletEvents = events.filter((e) => e.walletId === wallet.id);
  const inbound = transfers.filter((t) => t.to === wallet.id);
  const outbound = transfers.filter((t) => t.from === wallet.id);

  if (wallet.exploitConfirmed) {
    facts.push(
      fact(
        "EXPLOIT_PROTOCOL_FUNDS",
        "NW",
        100,
        "HIGH",
        "FATF VA Red Flags Cat. 5",
        `${wallet.accountLabel} is a confirmed exploit cash-out source (officer / external analysis). Not on SanctionRegistry. Keeper score 100 → WalletBlocked. P2P outflows still contaminate B/C/D. Do not fund E from A.`,
      ),
    );
  }

  if (
    typeof wallet.hopDistance === "number" &&
    wallet.hopDistance >= 1 &&
    !wallet.exploitConfirmed
  ) {
    const hop = wallet.hopDistance;
    const origin = wallet.originId ?? "A";
    const weight = Math.round(ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** hop);
    facts.push(
      fact(
        hop === 1 ? "HIGH_RISK_COUNTERPARTY" : "MEDIUM_RISK_COUNTERPARTY",
        "NW",
        weight,
        "HIGH",
        "FATF Rec. 10 · VA Red Flags Cat. 5 (indirect exposure)",
        `${hop}-hop contamination from origin ${origin}. N-hop decay applied by COA: 100 × ${DECAY_FACTOR}^${hop} ≈ ${weight}.`,
      ),
    );
    if (inbound.length > 0) {
      const last = inbound[inbound.length - 1];
      facts.push(
        fact(
          "RAPID_FULL_BALANCE_TRANSFER",
          "NW",
          0,
          "MEDIUM",
          "FATF VA Red Flags Cat. 2",
          `Inbound P2P ${last.from}→${last.to} for ${last.amountUsd} USDC recorded; hop graph updated. Weight is documentary: the hop formula already carries the score.`,
        ),
      );
    }
  }

  const swapObserved = walletEvents.filter((e) => e.kind === "SwapObserved");
  const blocked = walletEvents.filter((e) => e.kind === "WalletBlocked");
  const hopped =
    typeof wallet.hopDistance === "number" && wallet.hopDistance >= 1;

  if (swapObserved.length > 0 && !wallet.exploitConfirmed) {
    const allowN = swapObserved.filter((e) => e.decision === "ALLOW").length;
    const feeN = swapObserved.filter((e) => e.decision === "FEE_OVERRIDE").length;
    const usd = swapObserved.reduce((s, e) => s + e.amountUsd, 0);
    const trailPer = hopped ? 1 : 3;
    const trailCap = hopped ? 8 : 30;
    const trail = Math.min(swapObserved.length * trailPer, trailCap);
    facts.push(
      fact(
        "SWAP_OBSERVED_TRAIL",
        "ST",
        trail,
        "HIGH",
        "FATF Rec. 10 · afterSwap SwapObserved record",
        `${swapObserved.length} SwapObserved on the oracle record (ALLOW ${allowN}, FEE_OVERRIDE ${feeN}, USD ${usd.toLocaleString("en-US")}).`,
      ),
    );
    if (feeN > 0) {
      const feePer = hopped ? 2 : 6;
      const feeCap = hopped ? 8 : 30;
      facts.push(
        fact(
          "AFTERSWAP_FEE_OVERRIDE_SERIES",
          "DF",
          Math.min(feeN * feePer, feeCap),
          "HIGH",
          "FATF Rec. 1 · Rec. 10 (EDD trail)",
          `${feeN} afterSwap FEE_OVERRIDE emit(s) accumulated on the oracle record.`,
        ),
      );
    }
  }

  if (blocked.length > 0 && !wallet.exploitConfirmed) {
    facts.push(
      fact(
        "WALLET_BLOCKED_TRAIL",
        "DF",
        Math.min(blocked.length * 15, 45),
        "HIGH",
        "FATF Rec. 6 · fail-closed pool record",
        `${blocked.length} WalletBlocked emit(s) on the oracle record.`,
      ),
    );
  }

  if (
    wallet.hopDistance == null &&
    !wallet.exploitConfirmed &&
    outbound.length === 0 &&
    inbound.length === 0 &&
    swapObserved.length === 0 &&
    blocked.length === 0
  ) {
    facts.push(
      fact(
        "LONG_CLEAN_HISTORY",
        "MT",
        -10,
        "MEDIUM",
        "FATF Rec. 1 · Rec. 10 (EBR)",
        "No inbound contamination from exploit origin; clean ledger path.",
      ),
    );
    facts.push(
      fact(
        "COHERENT_TRANSACTION_PROFILE",
        "MT",
        -8,
        "MEDIUM",
        "FATF Rec. 10",
        "Pool activity consistent with a clean RWA participant profile.",
      ),
    );
  }

  facts.push(...extraFacts);
  return facts;
}

/**
 * P2P counterparty addresses for a live OFAC screen.
 */
export function counterpartiesOf(
  wallet: Wallet,
  transfers: TransferRecord[],
): string[] {
  const peers = new Set<string>();
  for (const t of transfers) {
    if (t.to === wallet.id) {
      const peer = getWallet(t.from);
      if (peer) peers.add(peer.address);
    }
    if (t.from === wallet.id) {
      const peer = getWallet(t.to);
      if (peer) peers.add(peer.address);
    }
  }
  return [...peers];
}

/**
 * Live SDN hits the COA just screened (and tried to write to SanctionRegistry).
 * Used when the registry write has not landed yet so scoring still fail-closes.
 */
export function factsFromOfacScreen(
  wallet: Wallet,
  ofac: OfacScreenResult,
): FactEvent[] {
  if (ofac.subject.match) {
    return [
      fact(
        "OFAC_DIRECT_MATCH",
        "S",
        100,
        "HIGH",
        "OFAC SDN · FATF Rec. 6",
        `${wallet.accountLabel} is a direct OFAC SDN ETH-address match. COA wrote SanctionRegistry; next swap reads the mapping.`,
      ),
    ];
  }
  const peer = ofac.counterparties.find((c) => c.match);
  if (peer) {
    return [
      fact(
        "SANCTIONED_COUNTERPARTY",
        "S",
        100,
        "HIGH",
        "OFAC SDN · FATF Rec. 6 / Rec. 10",
        `P2P counterparty ${peer.address} is a direct OFAC SDN match. Written to SanctionRegistry.`,
      ),
    ];
  }
  return [];
}

/**
 * SanctionRegistry hits on the subject, P2P counterparties, and pool contracts
 * the wallet actually used (SwapObserved / WalletBlocked). Fail-open if Anvil is down.
 */
export async function collectSanctionFacts(
  wallet: Wallet,
  transfers: TransferRecord[],
  events: HookEvent[],
): Promise<FactEvent[]> {
  const facts: FactEvent[] = [];
  if (await isSanctionedAddress(wallet.address)) {
    facts.push(
      fact(
        "OFAC_DIRECT_MATCH",
        "S",
        100,
        "HIGH",
        "OFAC SDN · FATF Rec. 6",
        `${wallet.accountLabel} is listed on SanctionRegistry. Fail-closed score 100.`,
      ),
    );
    return facts;
  }

  const peers = new Set<string>();
  for (const t of transfers) {
    if (t.to === wallet.id) {
      const peer = getWallet(t.from);
      if (peer) peers.add(peer.address);
    }
    if (t.from === wallet.id) {
      const peer = getWallet(t.to);
      if (peer) peers.add(peer.address);
    }
  }
  for (const addr of peers) {
    if (await isSanctionedAddress(addr)) {
      facts.push(
        fact(
          "SANCTIONED_COUNTERPARTY",
          "S",
          100,
          "HIGH",
          "OFAC SDN · FATF Rec. 6 / Rec. 10",
          `P2P counterparty ${addr} is listed on SanctionRegistry.`,
        ),
      );
      break;
    }
  }

  const usedPool = events.some(
    (e) =>
      e.walletId === wallet.id &&
      (e.kind === "SwapObserved" || e.kind === "WalletBlocked"),
  );
  if (usedPool && !wallet.exploitConfirmed) {
    for (const contract of demoContractAddresses()) {
      if (await isSanctionedAddress(contract)) {
        facts.push(
          fact(
            "SANCTIONED_CONTRACT_INTERACTION",
            "S",
            100,
            "HIGH",
            "OFAC SDN · FATF Rec. 6 (listed contract)",
            `Pool activity while ${contract} is listed on SanctionRegistry.`,
          ),
        );
        break;
      }
    }
  }
  return facts;
}

/**
 * Runs fact-scoring and returns a ScoreResult.
 */
export function scoreFromFacts(
  wallet: Wallet,
  facts: FactEvent[],
  trigger: OracleTrigger,
  priorScore: number | null,
  skillsApplied: string[],
  flow: "FULL" | "INCREMENTAL",
): ScoreResult {
  void priorScore;
  const override = facts.some(
    (f) =>
      f.type === "EXPLOIT_PROTOCOL_FUNDS" ||
      f.type === "OFAC_DIRECT_MATCH" ||
      f.type === "SANCTIONED_COUNTERPARTY" ||
      f.type === "SANCTIONED_CONTRACT_INTERACTION" ||
      (f.baseWeight >= 100 && f.dimension === "S"),
  );

  let scorePresent = 0;
  const breakdown: ScoreBreakdown = {
    sanctions: 0,
    structuring: 0,
    mixerExposure: 0,
    networkBehavior: 0,
    geographicRisk: 0,
    defiTypologies: 0,
    mitigants: 0,
    historicalComponent: 0,
  };

  const scoredFacts: FactEvent[] = [];

  if (override) {
    scorePresent = 100;
    if (facts.some((f) => f.type === "EXPLOIT_PROTOCOL_FUNDS")) {
      breakdown.defiTypologies = 100;
    } else {
      breakdown.sanctions = 100;
    }
    for (const f of facts) {
      scoredFacts.push({ ...f, scoreContribution: f.baseWeight });
    }
  } else {
    let rawMt = 0;
    for (const f of facts) {
      const confMod =
        f.confidence === "HIGH" ? 1 : f.confidence === "MEDIUM" ? 0.85 : 0.6;
      const contrib = Math.round(f.baseWeight * confMod);
      scoredFacts.push({ ...f, scoreContribution: contrib });

      if (f.dimension === "MT") {
        rawMt += Math.abs(contrib);
        breakdown.mitigants += Math.abs(contrib);
      } else if (f.dimension === "ST") {
        breakdown.structuring += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "MX") {
        breakdown.mixerExposure += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "GEO") {
        breakdown.geographicRisk += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "DF") {
        breakdown.defiTypologies += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "S") {
        breakdown.sanctions += contrib;
        scorePresent += contrib;
      } else {
        breakdown.networkBehavior += contrib;
        scorePresent += contrib;
      }
    }
    const mtCapped = Math.min(rawMt, 40);
    breakdown.mitigants = mtCapped;
    scorePresent = Math.max(0, scorePresent - mtCapped);
  }

  let finalScore = clamp(scorePresent, 0, 100);

  const decision = decisionFromScore(finalScore);
  const hasHigh = scoredFacts.some(
    (f) => f.confidence === "HIGH" && f.scoreContribution > 0,
  );
  let hookOutput = toHookOutput(decision);
  const regulatoryFlags: ScoreResult["regulatoryFlags"] = [];

  if (finalScore >= 71 && !hasHigh && !wallet.exploitConfirmed) {
    finalScore = 70;
    hookOutput = "FEE_OVERRIDE";
    regulatoryFlags.push({
      type: "INSUFFICIENT_CONFIDENCE",
      description: "Block band without HIGH fact: degraded to FEE_OVERRIDE.",
      recommendation: "Human review before fail-closed treatment.",
    });
  }

  if (
    finalScore >= 65 &&
    scoredFacts.filter((f) => f.dimension !== "MT").length >= 2
  ) {
    regulatoryFlags.push({
      type: "REASONABLE_SUSPICION_REACHED",
      description: "Score ≥ 65 with multiple non-mitigant facts.",
      recommendation: "Prepare SAR-support annex for Compliance Officer review.",
    });
  }

  if (decision === "block" || wallet.exploitConfirmed) {
    regulatoryFlags.push({
      type: "HUMAN_REVIEW_REQUIRED",
      description: "REVERT / exploit path requires human oversight.",
      recommendation: "Watch outbound P2P contamination of B/C.",
    });
  }

  const riskLevel =
    finalScore >= 71 ? "BLOCK" : finalScore >= 31 ? "ELEVATED" : "STANDARD";

  // COA owns the recommended fee (total friction; hook splits pool standard vs FeeEscrow differential).
  const recommendedFeeBps = feeBpsFromHop(finalScore, wallet.hopDistance);

  const payload = JSON.stringify({
    wallet: wallet.id,
    finalScore,
    recommendedFeeBps,
    scoredFacts,
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
    scoreBreakdown: breakdown,
    triggeringFacts: scoredFacts,
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

function fact(
  type: string,
  dimension: FactEvent["dimension"],
  baseWeight: number,
  confidence: FactEvent["confidence"],
  regulatoryBasis: string,
  justification: string,
): FactEvent {
  return {
    factId: `${type}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
    type,
    confidence,
    baseWeight,
    scoreContribution: 0,
    regulatoryBasis,
    justification,
    dimension,
  };
}

function clamp(n: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, n));
}

function nextReviewIso(score: number): string {
  const days = score >= 71 ? 0 : score >= 51 ? 7 : score >= 21 ? 30 : 90;
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString();
}

export type { WalletId };
