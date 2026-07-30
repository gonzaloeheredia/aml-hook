/**
 * Deterministic fact-scoring engine (MOCK_MODE) implementing
 * agents/oracle-coa/skills/fact-scoring.md for the UHI10 demo ledger.
 *
 * Live vendor APIs are not called — facts are derived from the in-memory
 * N-hop ledger, P2P transfers, and afterSwap / WalletBlocked events.
 */

import { createHash } from "node:crypto";
import {
  DECAY_FACTOR,
  ORIGIN_EXPLOIT_SCORE,
  decisionFromScore,
  toHookOutput,
} from "../scoring.js";
import type { HookEvent, TransferRecord, Wallet, WalletId } from "../types.js";
import type {
  FactEvent,
  OracleTrigger,
  ScoreBreakdown,
  ScoreResult,
} from "./types.js";

/** Historical blend weight (fact-scoring §3.3 default). */
const DECAY_HISTORICO = 0.4;

/**
 * Builds admissible FactEvents for a wallet from live ledger state.
 */
export function buildFacts(
  wallet: Wallet,
  transfers: TransferRecord[],
  events: HookEvent[],
): FactEvent[] {
  const facts: FactEvent[] = [];
  const walletEvents = events.filter((e) => e.walletId === wallet.id);
  const inbound = transfers.filter((t) => t.to === wallet.id);
  const outbound = transfers.filter((t) => t.from === wallet.id);

  if (wallet.exploitConfirmed) {
    facts.push(
      fact(
        "FONDOS_DE_PROTOCOLO_EXPLOTADO",
        "NW",
        100,
        "HIGH",
        "FATF VA Red Flags Cat. 5 · OFAC VC Guidance 2021",
        `${wallet.accountLabel} is the confirmed exploit cash-out source (keeper detection). Override to score 100.`,
        true,
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
        hop === 1 ? "CONTRAPARTE_ALTO_RIESGO" : "CONTRAPARTE_RIESGO_MEDIO",
        "NW",
        weight,
        "HIGH",
        "FATF Rec. 10 · VA Red Flags Cat. 5 (indirect exposure)",
        `${hop}-hop contamination from origin ${origin}. Demo N-hop decay: 100 × ${DECAY_FACTOR}^${hop} ≈ ${weight}.`,
      ),
    );
    if (inbound.length > 0) {
      const last = inbound[inbound.length - 1];
      facts.push(
        fact(
          "TRANSFERENCIA_RAPIDA_BALANCE_TOTAL",
          "NW",
          hop === 1 ? 8 : 5,
          "MEDIUM",
          "FATF VA Red Flags Cat. 2",
          `Inbound P2P ${last.from}→${last.to} for ${last.amountUsd} USDC recorded; hop graph updated.`,
        ),
      );
    }
  }

  const swapObserved = walletEvents.filter((e) => e.kind === "SwapObserved");
  if (swapObserved.length >= 3 && wallet.hopDistance == null && !wallet.exploitConfirmed) {
    facts.push(
      fact(
        "STRUCTURING_VELOCITY_SPIKE",
        "ST",
        5,
        "LOW",
        "FATF VA Red Flags Cat. 1",
        `${swapObserved.length} SwapObserved emits on a clean path — activity noted; not alone grounds for FEE_OVERRIDE.`,
      ),
    );
  }

  if (
    wallet.hopDistance == null &&
    !wallet.exploitConfirmed &&
    outbound.length === 0 &&
    inbound.length === 0
  ) {
    facts.push(
      fact(
        "HISTORIAL_LIMPIO_LARGO",
        "MT",
        -10,
        "MEDIUM",
        "FATF Rec. 1 · Rec. 10 (EBR)",
        "No inbound contamination from exploit origin; clean ledger path.",
      ),
    );
    facts.push(
      fact(
        "PERFIL_TRANSACCIONAL_COHERENTE",
        "MT",
        -8,
        "MEDIUM",
        "FATF Rec. 10",
        "Pool activity consistent with a clean RWA participant profile.",
      ),
    );
  }

  return facts;
}

/**
 * Runs fact-scoring §3 and returns a ScoreResult.
 */
export function scoreFromFacts(
  wallet: Wallet,
  facts: FactEvent[],
  trigger: OracleTrigger,
  priorScore: number | null,
  skillsApplied: string[],
  flow: "FULL" | "INCREMENTAL",
): ScoreResult {
  const override = facts.some(
    (f) =>
      f.type === "FONDOS_DE_PROTOCOLO_EXPLOTADO" ||
      f.type === "OFAC_MATCH_DIRECTO" ||
      (f.base_weight >= 100 && f.dimension === "S"),
  );

  let scorePresent = 0;
  const breakdown: ScoreBreakdown = {
    sanciones: 0,
    structuring: 0,
    exposicion_mixer: 0,
    comportamiento_red: 0,
    riesgo_geografico: 0,
    tipologias_defi: 0,
    mitigantes: 0,
    componente_historico: 0,
  };

  const scoredFacts: FactEvent[] = [];

  if (override && wallet.exploitConfirmed) {
    scorePresent = 100;
    breakdown.sanciones = 100;
    for (const f of facts) {
      const contrib = f.base_weight;
      scoredFacts.push({ ...f, contribucion_score: contrib });
    }
  } else {
    let rawMt = 0;
    for (const f of facts) {
      const confMod =
        f.confidence === "HIGH" ? 1 : f.confidence === "MEDIUM" ? 0.85 : 0.6;
      const contrib = Math.round(f.base_weight * confMod);
      scoredFacts.push({ ...f, contribucion_score: contrib });

      if (f.dimension === "MT") {
        rawMt += Math.abs(contrib);
        breakdown.mitigantes += Math.abs(contrib);
      } else if (f.dimension === "ST") {
        breakdown.structuring += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "MX") {
        breakdown.exposicion_mixer += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "GEO") {
        breakdown.riesgo_geografico += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "DF") {
        breakdown.tipologias_defi += contrib;
        scorePresent += contrib;
      } else if (f.dimension === "S") {
        breakdown.sanciones += contrib;
        scorePresent += contrib;
      } else {
        breakdown.comportamiento_red += contrib;
        scorePresent += contrib;
      }
    }
    const mtCapped = Math.min(rawMt, 40);
    breakdown.mitigantes = mtCapped;
    scorePresent = Math.max(0, scorePresent - mtCapped);
  }

  // Prefer hop-aligned present score when hop facts dominate (demo fidelity)
  if (
    !wallet.exploitConfirmed &&
    typeof wallet.hopDistance === "number" &&
    wallet.hopDistance >= 1
  ) {
    scorePresent = Math.round(
      ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** wallet.hopDistance,
    );
    breakdown.comportamiento_red = scorePresent;
    breakdown.mitigantes = 0;
  }

  let scoreFinal = clamp(scorePresent, 0, 100);
  if (priorScore != null && !wallet.exploitConfirmed) {
    const blended = Math.round(
      priorScore * DECAY_HISTORICO + scorePresent * (1 - DECAY_HISTORICO),
    );
    breakdown.componente_historico = Math.round(priorScore * DECAY_HISTORICO);
    // Keep hop band stable for demo when hop is set
    if (wallet.hopDistance == null) {
      scoreFinal = clamp(blended, 0, 100);
    }
  }

  // Rule 6: block needs HIGH fact — degrade otherwise
  const decision = decisionFromScore(scoreFinal);
  const hasHigh = scoredFacts.some((f) => f.confidence === "HIGH" && f.contribucion_score > 0);
  let salida = toHookOutput(decision);
  const flags: ScoreResult["flags_regulatorios"] = [];

  if (scoreFinal >= 71 && !hasHigh && !wallet.exploitConfirmed) {
    scoreFinal = 70;
    salida = "FEE_OVERRIDE";
    flags.push({
      tipo: "CONFIDENCE_INSUFICIENTE",
      descripcion: "Block band without HIGH fact — degraded to FEE_OVERRIDE.",
      recomendacion: "Human review before fail-closed treatment.",
    });
  }

  if (scoreFinal >= 65 && scoredFacts.filter((f) => f.dimension !== "MT").length >= 2) {
    flags.push({
      tipo: "SOSPECHA_RAZONABLE_ALCANZADA",
      descripcion: "Score ≥ 65 with multiple non-mitigant facts.",
      recomendacion: "Prepare SAR-support annex for Compliance Officer review.",
    });
  }

  if (decision === "block" || wallet.exploitConfirmed) {
    flags.push({
      tipo: "REVISION_HUMANA_REQUERIDA",
      descripcion: "REVERT / exploit path requires human oversight.",
      recomendacion: "Watch outbound P2P contamination of B/C.",
    });
  }

  const nivel =
    scoreFinal >= 71 ? "BLOQUEO" : scoreFinal >= 31 ? "ELEVADO" : "ESTANDAR";

  const payload = JSON.stringify({
    wallet: wallet.id,
    scoreFinal,
    scoredFacts,
    trigger,
  });
  const audit_hash = `0x${createHash("sha256").update(payload).digest("hex").slice(0, 16)}`;

  return {
    walletId: wallet.id,
    address: wallet.address,
    score_final: scoreFinal,
    nivel_riesgo: nivel,
    salida_hook: salida,
    score_breakdown: breakdown,
    hechos_disparadores: scoredFacts,
    flags_regulatorios: flags,
    vigencia: {
      calculado_en: new Date().toISOString(),
      trigger,
      proxima_revision: nextReviewIso(scoreFinal),
    },
    audit_hash,
    skills_applied: skillsApplied,
    flow,
  };
}

function fact(
  type: string,
  dimension: FactEvent["dimension"],
  base_weight: number,
  confidence: FactEvent["confidence"],
  base_regulatoria: string,
  justificacion: string,
  _override = false,
): FactEvent {
  return {
    fact_id: `${type}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
    type,
    confidence,
    base_weight,
    contribucion_score: 0,
    base_regulatoria,
    justificacion,
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
