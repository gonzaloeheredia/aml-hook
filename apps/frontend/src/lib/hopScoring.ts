/**
 * N-hop decay scoring for the AML Hook demo.
 *
 * Use case (`docs/Use_Case.md`):
 * - Wallet A = confirmed exploit, score 100 → WalletBlocked on pool swaps.
 * - Wallets B and C both start clean (ALLOW 0.30%, green). Swaps never add score.
 * - Wallet D = published score 0. Already-held funds ALLOW; clean C→D is inflow, not a hop.
 * - Wallet E = unknown, starts empty. Clean C funds E (no hop). Floor A/D by bag and swap.
 * - Risk only via MetaMask P2P hops:
 *   - Receive from A → hop 1 → score ≈ 65 → FEE_OVERRIDE 8% (yellow)
 *   - Receive from a 1-hop peer (B↔C after A tainted one) → hop 2 → ≈ 42 → 3%
 * - Closer hop wins if a wallet is contaminated more than once.
 *
 * Formula: derived_score = origin_score × (decay_factor ^ hops) × exposed_proportion
 */

import type { DemoCaseId } from "@/data/cases";

export type SimWalletId = DemoCaseId;

export const DECAY_FACTOR = 0.65;
export const ORIGIN_EXPLOIT_SCORE = 100;
/** Shared ETH mark used by MetaMask ledger + Uniswap swap preview (1 ETH = 1,000 USDC) */
export const ETH_USD = 1_000;
/** Default demo swap size in USDC (capped by wallet balance) */
export const DEFAULT_SWAP_USDC = 1_000;
/** Exploit / tainted source wallet in this demo */
export const EXPLOIT_SOURCE: SimWalletId = "A";
export type PolicyKnobs = {
  unscoredFeeThresholdUsd: number;
  unscoredRevertThresholdUsd: number;
  proportionalFeeBps: number;
  punitiveFeeBps: number;
  poolImpactThresholdBps: number;
};

export const DEFAULT_POLICY_KNOBS: PolicyKnobs = {
  unscoredFeeThresholdUsd: 1_000,
  unscoredRevertThresholdUsd: 15_000,
  proportionalFeeBps: 300,
  punitiveFeeBps: 800,
  poolImpactThresholdBps: 2_000,
};

let policyKnobs: PolicyKnobs = { ...DEFAULT_POLICY_KNOBS };

export function getPolicyKnobs(): PolicyKnobs {
  return policyKnobs;
}

export function setPolicyKnobs(next: Partial<PolicyKnobs>): PolicyKnobs {
  policyKnobs = { ...policyKnobs, ...next };
  return policyKnobs;
}

export function formatFeePct(bps: number): string {
  if (bps % 100 === 0) return `${bps / 100}%`;
  return `${(bps / 100).toFixed(2)}%`;
}

export function formatUsdFloor(usd: number): string {
  return `$${usd.toLocaleString("en-US")}`;
}

/** Dust example that stays strictly under the officer fee floor. */
export function dustExampleUsd(feeThresholdUsd = getPolicyKnobs().unscoredFeeThresholdUsd): number {
  if (feeThresholdUsd > 500) return 500;
  return Math.max(1, Math.floor(feeThresholdUsd / 2));
}

/** Mid-band example ($10k when that still sits between the live floors). */
export function midBandExampleUsd(
  feeThresholdUsd = getPolicyKnobs().unscoredFeeThresholdUsd,
  revertThresholdUsd = getPolicyKnobs().unscoredRevertThresholdUsd,
): number {
  if (10_000 >= feeThresholdUsd && 10_000 < revertThresholdUsd) return 10_000;
  const mid = Math.round((feeThresholdUsd + revertThresholdUsd) / 2);
  return Math.min(Math.max(feeThresholdUsd, mid), Math.max(feeThresholdUsd, revertThresholdUsd - 1));
}

/** E size chips: dust · fee floor · mid bag · revert floor. */
export function neverScoredAmountPresets(knobs: PolicyKnobs = getPolicyKnobs()): number[] {
  const fee = knobs.unscoredFeeThresholdUsd;
  const revert = knobs.unscoredRevertThresholdUsd;
  return [...new Set([dustExampleUsd(fee), fee, midBandExampleUsd(fee, revert), revert])]
    .filter((n) => n > 0)
    .sort((a, b) => a - b);
}

/** C→D chips: mid inflow · high / revert-band inflow. */
export function inflowAmountPresets(knobs: PolicyKnobs = getPolicyKnobs()): number[] {
  const fee = knobs.unscoredFeeThresholdUsd;
  const revert = knobs.unscoredRevertThresholdUsd;
  return [...new Set([midBandExampleUsd(fee, revert), revert])].filter((n) => n > 0);
}

/** C→E fund chips: dust bag · mid bag · revert-band bag. */
export function unknownFundPresets(knobs: PolicyKnobs = getPolicyKnobs()): number[] {
  const fee = knobs.unscoredFeeThresholdUsd;
  const revert = knobs.unscoredRevertThresholdUsd;
  return [...new Set([dustExampleUsd(fee), midBandExampleUsd(fee, revert), revert])].filter(
    (n) => n > 0,
  );
}

/** Floor D/B label for an inbound or assessed USD amount. */
export function inflowBandLabel(usd: number): string {
  const feeBps = publishedUsdBandFee(usd);
  return feeBps === 0 ? "pass" : formatFeePct(feeBps);
}

export function hopFeePct(hop: 1 | 2, knobs: PolicyKnobs = getPolicyKnobs()): string {
  return formatFeePct(hop === 1 ? knobs.punitiveFeeBps : knobs.proportionalFeeBps);
}

/**
 * Same mapping as RiskPolicy for a never-written wallet:
 * Floor A = this swap (proportional / punitive / REVERT).
 * Floor D = unpublished bag (pass / proportional / punitive).
 * Stricter fee wins. A still reverts at the high floor on this swap.
 */
export function neverScoredQuote(
  swapUsd: number,
  bagUsd: number,
): { feeBps: number; revert: boolean; aFee: number; dFee: number } {
  const knobs = getPolicyKnobs();
  const dFee = publishedUsdBandFee(bagUsd);
  if (swapUsd >= knobs.unscoredRevertThresholdUsd) {
    return { feeBps: 0, revert: true, aFee: 0, dFee };
  }
  const aFee =
    swapUsd >= knobs.unscoredFeeThresholdUsd
      ? knobs.punitiveFeeBps
      : knobs.proportionalFeeBps;
  return { feeBps: aFee > dFee ? aFee : dFee, revert: false, aFee, dFee };
}

/** Chip label for a never-scored size, including Floor D on the unpublished bag. */
export function bandLabelForUsd(swapUsd: number, bagUsd = 0): string {
  const quote = neverScoredQuote(swapUsd, bagUsd);
  if (quote.revert) return "revert";
  return formatFeePct(quote.feeBps);
}

/** Deploy-default latency / inflow floor. Live value: `punitiveFeeBps`. */
export const LATENCY_FEE_BPS = DEFAULT_POLICY_KNOBS.punitiveFeeBps;
/** Inbound USD share (bps of current USD bag) that flags a medium-risk increment */
export const INFLOW_THRESHOLD_BPS = 5000;
export const UNSCORED_FEE_THRESHOLD_USD = DEFAULT_POLICY_KNOBS.unscoredFeeThresholdUsd;
export const UNSCORED_REVERT_THRESHOLD_USD = DEFAULT_POLICY_KNOBS.unscoredRevertThresholdUsd;
export const UNSCORED_DUST_FEE_BPS = DEFAULT_POLICY_KNOBS.proportionalFeeBps;
export const UNSCORED_MID_FEE_BPS = DEFAULT_POLICY_KNOBS.punitiveFeeBps;

/** Floor B/D: dust pass, mid proportional, high punitive. */
export function publishedUsdBandFee(usd: number): number {
  const knobs = getPolicyKnobs();
  if (usd >= knobs.unscoredRevertThresholdUsd) return knobs.punitiveFeeBps;
  if (usd >= knobs.unscoredFeeThresholdUsd) return knobs.proportionalFeeBps;
  return 0;
}
/** Floor B window — keep in lockstep with `apps/api` / `AmlHookLogic.DEFAULT_STALENESS`. */
export const STALENESS_MS = 300_000;
export const ACTIVITY_WINDOW_MS = 3_600_000;
/** Floor C — BSA CTR-style 24-hour USD aggregation. */
export const DAILY_WINDOW_MS = 86_400_000;

let demoOffsetMs = 0;
let priceFeedBound = true;

export function demoNow(): number {
  return Date.now() + demoOffsetMs;
}

export function elapseDemo(ms: number): number {
  demoOffsetMs += Math.max(0, ms);
  return demoNow();
}

export function setPriceFeedBound(bound: boolean): void {
  priceFeedBound = bound;
}

export function isPriceFeedBound(): boolean {
  return priceFeedBound;
}

export function resetDemoClock(): void {
  demoOffsetMs = 0;
  priceFeedBound = true;
}

export type LatencyMitigation =
  | "INFLOW_HEURISTIC"
  | "INFLOW_MAGNITUDE"
  | "SCORE_NEVER_WRITTEN"
  | "STALE_WITH_POOL_ACTIVITY"
  | "ACTIVITY_WINDOW_CAP"
  | "DAILY_AGGREGATION"
  | "MAGNITUDE_QUOTE_FAILED"
  | null;

export type SimWallet = {
  id: SimWalletId;
  accountLabel: string;
  role: string;
  address: string;
  usdc: number;
  eth: number;
  hopDistance: number | null;
  originId: SimWalletId | null;
  exploitConfirmed: boolean;
  /** True while deferred keeper has not published post-transfer score (Wallet D). */
  keeperPending?: boolean;
  /** Inflow baseline USDC (refreshed afterSwap). */
  lastKnownUsdc?: number;
  /** True when the oracle has never published a row (Wallet E). */
  neverScored?: boolean;
  opsInWindow?: number;
  windowUsd?: number;
  windowStart?: number;
  dailyUsd?: number;
  dailyStart?: number;
  lastScoreAt?: number;
  lastKnownAt?: number;
};

export type TransferRecord = {
  id: string;
  from: SimWalletId;
  to: SimWalletId;
  amountUsd: number;
  at: string;
  resultingScore: number;
  hopDistance: number;
};

export function caseIdForSimWallet(id: SimWalletId): DemoCaseId {
  return id;
}

/**
 * Computes N-hop derived score for a wallet state (ledger truth).
 * When keeperPending, the oracle still reads stale 0 — use resolveDemoRisk.
 */
export function hopScore(wallet: SimWallet): number {
  if (wallet.neverScored) return 0;
  if (wallet.exploitConfirmed) return ORIGIN_EXPLOIT_SCORE;
  if (wallet.hopDistance == null) return 0;
  return Math.round(
    ORIGIN_EXPLOIT_SCORE * DECAY_FACTOR ** wallet.hopDistance * 1.0,
  );
}

export function decisionFromScore(score: number): "allow" | "fee_override" | "block" {
  if (score >= 71) return "block";
  if (score >= 31) return "fee_override";
  return "allow";
}

/**
 * Dynamic fee in bps: clean 0.30% · 1-hop 8% · 2-hop 3% · REVERT 0.
 */
export function feeBpsFromHop(score: number, hopDistance: number | null): number {
  const knobs = getPolicyKnobs();
  if (score >= 71) return 0;
  if (score <= 30) return 30;
  if (hopDistance === 1) return knobs.punitiveFeeBps;
  if (hopDistance === 2) return knobs.proportionalFeeBps;
  return score >= 55 ? knobs.punitiveFeeBps : knobs.proportionalFeeBps;
}

export function inflowDeltaBps(currentUsdc: number, lastKnownUsdc: number): number {
  if (currentUsdc <= 0) return 0;
  const delta = currentUsdc > lastKnownUsdc ? currentUsdc - lastKnownUsdc : 0;
  return Math.floor((delta * 10_000) / currentUsdc);
}

/**
 * Offline beforeSwap — same order as RiskPolicy + Mitigation C.
 */
export function resolveDemoRisk(
  wallet: SimWallet,
  preferredUsdc?: number,
): {
  score: number;
  decision: "allow" | "fee_override" | "block";
  feeBps: number;
  latencyMitigation: LatencyMitigation;
  keeperPending: boolean;
} {
  const keeperPending = Boolean(wallet.keeperPending);
  const usdcIn = swapUsdcAmount(wallet, preferredUsdc);
  const now = demoNow();
  const windowStart = wallet.windowStart ?? 0;
  const windowLive =
    windowStart > 0 && now < windowStart + ACTIVITY_WINDOW_MS
      ? { ops: wallet.opsInWindow ?? 0, usd: wallet.windowUsd ?? 0 }
      : { ops: 0, usd: 0 };
  const dailyStart = wallet.dailyStart ?? 0;
  const priorDaily =
    dailyStart > 0 && now < dailyStart + DAILY_WINDOW_MS ? (wallet.dailyUsd ?? 0) : 0;
  const knobs = getPolicyKnobs();
  const dailyBlocks =
    priorDaily > 0 && priorDaily + usdcIn >= knobs.unscoredRevertThresholdUsd;
  const lastScoreAt = wallet.lastScoreAt ?? (wallet.neverScored ? 0 : now);
  const lastKnownAt = wallet.lastKnownAt ?? lastScoreAt;
  const isStale = wallet.neverScored || now > lastScoreAt + STALENESS_MS;
  const inflowLive = lastScoreAt <= lastKnownAt;

  if (wallet.neverScored) {
    if (!priceFeedBound) {
      return {
        score: 0,
        decision: "block",
        feeBps: 0,
        latencyMitigation: "MAGNITUDE_QUOTE_FAILED",
        keeperPending: false,
      };
    }
    const assessed = usdcIn;
    if (assessed >= knobs.unscoredRevertThresholdUsd) {
      return {
        score: 0,
        decision: "block",
        feeBps: 0,
        latencyMitigation: "SCORE_NEVER_WRITTEN",
        keeperPending: false,
      };
    }
    if (dailyBlocks) {
      return {
        score: 0,
        decision: "block",
        feeBps: 0,
        latencyMitigation: "DAILY_AGGREGATION",
        keeperPending: false,
      };
    }
    const quote = neverScoredQuote(assessed, wallet.usdc);
    return {
      score: 0,
      decision: "fee_override",
      feeBps: quote.feeBps,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
      keeperPending: false,
    };
  }
  if (wallet.exploitConfirmed) {
    return {
      score: 100,
      decision: "block",
      feeBps: 0,
      latencyMitigation: null,
      keeperPending,
    };
  }

  const baseline = wallet.lastKnownUsdc ?? 0;
  const rawInflow = wallet.usdc > baseline ? wallet.usdc - baseline : 0;
  const inflowUsd = inflowLive ? rawInflow : 0;
  const score = keeperPending ? 0 : hopScore(wallet);

  if (inflowUsd > 0 && !priceFeedBound) {
    return {
      score,
      decision: "block",
      feeBps: 0,
      latencyMitigation: "MAGNITUDE_QUOTE_FAILED",
      keeperPending,
    };
  }

  if (score >= 31) {
    if (dailyBlocks) {
      return {
        score,
        decision: "block",
        feeBps: 0,
        latencyMitigation: "DAILY_AGGREGATION",
        keeperPending,
      };
    }
    return {
      score,
      decision: "fee_override",
      feeBps: feeBpsFromHop(score, wallet.hopDistance),
      latencyMitigation: null,
      keeperPending,
    };
  }

  if ((isStale && windowLive.ops > 0) && !priceFeedBound) {
    return {
      score,
      decision: "block",
      feeBps: 0,
      latencyMitigation: "MAGNITUDE_QUOTE_FAILED",
      keeperPending,
    };
  }

  if (dailyBlocks) {
    return {
      score,
      decision: "block",
      feeBps: 0,
      latencyMitigation: "DAILY_AGGREGATION",
      keeperPending,
    };
  }

  const dFee = publishedUsdBandFee(inflowUsd);
  const bFee =
    isStale && windowLive.ops > 0 ? publishedUsdBandFee(usdcIn + windowLive.usd) : 0;
  const floorFee = dFee > bFee ? dFee : bFee;
  if (floorFee > 0) {
    return {
      score,
      decision: "fee_override",
      feeBps: floorFee,
      latencyMitigation: dFee >= bFee && dFee > 0 ? "INFLOW_HEURISTIC" : "STALE_WITH_POOL_ACTIVITY",
      keeperPending,
    };
  }

  return {
    score,
    decision: "allow",
    feeBps: 30,
    latencyMitigation: null,
    keeperPending,
  };
}

/**
 * Initial ledger: A exploit; B/C clean; D published score 0; E unknown.
 */
export function initialSimWallets(): Record<SimWalletId, SimWallet> {
  resetDemoClock();
  const t = demoNow();
  return {
    A: {
      id: "A",
      accountLabel: "Account A · Exploit",
      role: "Confirmed exploit — score 100 · WalletBlocked on pool; P2P can still contaminate B/C/D",
      address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      usdc: 10_000_000,
      eth: 5,
      hopDistance: 0,
      originId: "A",
      exploitConfirmed: true,
      neverScored: false,
      lastKnownUsdc: 10_000_000,
      lastScoreAt: t,
      lastKnownAt: t,
      opsInWindow: 0,
      windowUsd: 0,
      dailyUsd: 0,
    },
    B: {
      id: "B",
      accountLabel: "Account B · Clean",
      role: "Clean wallet — A→B = 1-hop (~65); tainted C→B = 2-hop (~42)",
      address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
      usdc: 25_000,
      eth: 4,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: false,
      lastKnownUsdc: 25_000,
      lastScoreAt: t,
      lastKnownAt: t,
      opsInWindow: 0,
      windowUsd: 0,
    },
    C: {
      id: "C",
      accountLabel: "Account C · Clean",
      role: "Clean wallet — fund E (unknown) or D (inflow); A→C = 1-hop (~65)",
      address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
      usdc: 50_000,
      eth: 8,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: false,
      lastKnownUsdc: 50_000,
      lastScoreAt: t,
      lastKnownAt: t,
      opsInWindow: 0,
      windowUsd: 0,
    },
    D: {
      id: "D",
      accountLabel: "Account D · Score 0",
      role: `Published score 0 — ALLOW on already-held funds; clean C→D → inflow ${formatFeePct(getPolicyKnobs().proportionalFeeBps)} / ${formatFeePct(getPolicyKnobs().punitiveFeeBps)} by size (no hop)`,
      address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
      usdc: 5_000,
      eth: 2,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: false,
      keeperPending: false,
      lastKnownUsdc: 5_000,
      lastScoreAt: t,
      lastKnownAt: t,
      opsInWindow: 0,
      windowUsd: 0,
    },
    E: {
      id: "E",
      accountLabel: "Account E · Unknown",
      role: "Unknown wallet — starts empty. Fund from clean C (no hop). Floor A/D by bag and swap size",
      address: "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
      usdc: 0,
      eth: 1,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: true,
      lastKnownUsdc: 0,
      lastKnownAt: t,
      opsInWindow: 0,
      windowUsd: 0,
    },
    N: {
      id: "N",
      accountLabel: "New wallet",
      role: "Judge wallet — starts at 0 with unknown score. Mint on this account, then swap",
      address: "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
      usdc: 0,
      eth: 0,
      hopDistance: null,
      originId: null,
      exploitConfirmed: false,
      neverScored: true,
      lastKnownUsdc: 0,
      lastKnownAt: t,
      opsInWindow: 0,
      windowUsd: 0,
    },
  };
}

/** True when this wallet would pass a hop to a recipient. */
export function isSenderTainted(wallet: SimWallet): boolean {
  return Boolean(wallet.exploitConfirmed || wallet.hopDistance != null);
}

/**
 * What a P2P send will do — used by the MetaMask send screen.
 * Clean C→D / B→D is inflow (no hop). A→D or tainted C→D is a hop.
 */
export function previewTransfer(
  sender: SimWallet,
  recipient: SimWallet,
  amountUsd: number,
): { title: string; detail: string; tone: "ok" | "warn" | "bad" } {
  const amount = Math.round(amountUsd);
  if (recipient.neverScored) {
    const knobs = getPolicyKnobs();
    const nextBag = recipient.usdc + amount;
    const quote = neverScoredQuote(DEFAULT_SWAP_USDC, nextBag);
    const dust = formatUsdFloor(dustExampleUsd(knobs.unscoredFeeThresholdUsd));
    return {
      title: "No hop · unknown wallet",
      detail: quote.revert
        ? `E never takes a hop. The next ${formatUsdFloor(knobs.unscoredRevertThresholdUsd)} swap still reverts (Floor A).`
        : `E never takes a hop. Unpublished bag $${nextBag.toLocaleString("en-US")} — Floor D ${formatFeePct(quote.dFee || quote.feeBps)}. A ${dust} swap still pays the stricter of A and D.`,
      tone: "warn",
    };
  }
  const knobs = getPolicyKnobs();
  const midPct = formatFeePct(knobs.proportionalFeeBps);
  const highPct = formatFeePct(knobs.punitiveFeeBps);
  if (isSenderTainted(sender)) {
    const hop = (sender.hopDistance ?? 0) + 1;
    return {
      title: `${hop}-hop contamination`,
      detail:
        hop === 1
          ? `Recipient score ≈ 65 · FEE_OVERRIDE ${highPct}. Do not use this path to demo D inflow.`
          : `Recipient score ≈ 42 · FEE_OVERRIDE ${midPct}.`,
      tone: hop === 1 && recipient.id === "D" ? "bad" : "warn",
    };
  }
  if (recipient.id === "D" && amount > 0) {
    const nextUsdc = recipient.usdc + amount;
    const baseline = recipient.lastKnownUsdc ?? recipient.usdc;
    const inflow = nextUsdc > baseline ? nextUsdc - baseline : 0;
    const dFee = publishedUsdBandFee(inflow);
    if (dFee === knobs.punitiveFeeBps) {
      return {
        title: `No hop · inflow ${highPct}`,
        detail: `D stays score 0. Inbound $${inflow.toLocaleString("en-US")} ≥ ${formatUsdFloor(knobs.unscoredRevertThresholdUsd)} → FEE_OVERRIDE ${highPct}.`,
        tone: "warn",
      };
    }
    if (dFee === knobs.proportionalFeeBps && knobs.proportionalFeeBps > 0) {
      return {
        title: `No hop · inflow ${midPct}`,
        detail: `D stays score 0. +$${inflow.toLocaleString("en-US")} → FEE_OVERRIDE ${midPct}.`,
        tone: "warn",
      };
    }
    return {
      title: "No hop · small inbound",
      detail: `D stays score 0. Inbound under ${formatUsdFloor(knobs.unscoredFeeThresholdUsd)} — Floor D passes.`,
      tone: "ok",
    };
  }
  return {
    title: "Clean to clean",
    detail: "No hop. Recipient score stays 0.",
    tone: "ok",
  };
}

/**
 * P2P USDC transfer between demo addresses.
 * Debits sender and credits recipient (round whole USDC).
 *
 * Contamination rules (B, C, D start clean; E stays unknown):
 * - Receive from exploit A → hop 1 → score ≈ 65 (FEE_OVERRIDE 8%)
 * - Receive from a tainted peer → hop = sender.hop + 1
 * - Clean C→D / B→D: no hop; next D swap may hit the inflow floor
 * - Wallet E: credits USDC only; no hop and no keeper write
 */
export function applyTransfer(
  wallets: Record<SimWalletId, SimWallet>,
  from: SimWalletId,
  to: SimWalletId,
  amountUsd: number,
): { wallets: Record<SimWalletId, SimWallet>; record: TransferRecord } | null {
  if (from === to) return null;
  const amount = Math.round(amountUsd);
  if (!Number.isFinite(amount) || amount <= 0) return null;

  const sender = wallets[from];
  const recipient = wallets[to];
  if (!sender || !recipient) return null;
  if (sender.usdc < amount) return null;

  if (recipient.neverScored) {
    const next: Record<SimWalletId, SimWallet> = {
      ...wallets,
      [from]: { ...sender, usdc: sender.usdc - amount },
      [to]: { ...recipient, usdc: recipient.usdc + amount },
    };
    return {
      wallets: next,
      record: {
        id: `tx-${Date.now()}`,
        from,
        to,
        amountUsd: amount,
        at: new Date().toISOString(),
        resultingScore: 0,
        hopDistance: 0,
      },
    };
  }

  const senderIsTainted = sender.exploitConfirmed || sender.hopDistance != null;
  const incomingHop = senderIsTainted ? (sender.hopDistance ?? 0) + 1 : null;
  const origin =
    sender.originId ?? (sender.exploitConfirmed ? sender.id : null);

  const nextSender: SimWallet = {
    ...sender,
    usdc: sender.usdc - amount,
  };

  const resolvedHop = recipient.exploitConfirmed
    ? recipient.hopDistance
    : incomingHop == null
      ? recipient.hopDistance
      : recipient.hopDistance == null
        ? incomingHop
        : Math.min(recipient.hopDistance, incomingHop);

  const resolvedOrigin = recipient.exploitConfirmed
    ? recipient.originId
    : incomingHop == null
      ? recipient.originId
      : (origin ?? recipient.originId);

  const deferKeeper = to === "D" && incomingHop != null;

  const nextRecipient: SimWallet = {
    ...recipient,
    usdc: recipient.usdc + amount,
    hopDistance: resolvedHop,
    originId: resolvedOrigin,
    lastScoreAt:
      deferKeeper || incomingHop == null
        ? recipient.lastScoreAt
        : demoNow(),
    keeperPending: deferKeeper ? true : recipient.keeperPending,
    accountLabel: recipient.exploitConfirmed
      ? recipient.accountLabel
      : deferKeeper
        ? `Account ${recipient.id} · Latency window`
        : resolvedHop == null
          ? `Account ${recipient.id} · Clean`
          : `Account ${recipient.id} · ${resolvedHop}-hop`,
    role: recipient.exploitConfirmed
      ? recipient.role
      : deferKeeper
        ? `Latency path — keeper pending; next swap uses inflow ${formatFeePct(getPolicyKnobs().proportionalFeeBps)} / ${formatFeePct(getPolicyKnobs().punitiveFeeBps)} by inbound USD`
        : resolvedHop == null
          ? `Clean wallet — ALLOW until contaminated by A or a tainted peer`
          : `${resolvedHop}-hop from origin ${resolvedOrigin ?? EXPLOIT_SOURCE}`,
  };

  const next: Record<SimWalletId, SimWallet> = {
    ...wallets,
    [from]: nextSender,
    [to]: nextRecipient,
  };

  return {
    wallets: next,
    record: {
      id: `tx-${Date.now()}`,
      from,
      to,
      amountUsd: amount,
      at: new Date().toISOString(),
      resultingScore: deferKeeper ? 0 : hopScore(next[to]),
      hopDistance: next[to].hopDistance ?? 0,
    },
  };
}

/**
 * Caps the demo swap to what the wallet can actually spend.
 */
export function swapUsdcAmount(wallet: SimWallet, preferred = DEFAULT_SWAP_USDC): number {
  return Math.min(preferred, Math.max(0, Math.floor(wallet.usdc)));
}

/**
 * ETH received after pool fee (bps) when selling `usdcIn` USDC.
 */
export function ethOutFromSwap(usdcIn: number, feeBps: number): number {
  if (usdcIn <= 0) return 0;
  const netUsdc = usdcIn * (1 - feeBps / 10_000);
  return netUsdc / ETH_USD;
}

/**
 * Settles a successful pool swap against the MetaMask ledger:
 * USDC ↓, ETH ↑. Clears keeperPending and refreshes lastKnownUsdc (afterSwap).
 */
export function applyPoolSwap(
  wallets: Record<SimWalletId, SimWallet>,
  walletId: SimWalletId,
  usdcIn: number,
  feeBps: number,
  decision: "allow" | "fee_override" | "block",
): Record<SimWalletId, SimWallet> | null {
  if (decision === "block") return null;
  const amount = Math.round(usdcIn);
  if (amount <= 0) return null;
  const wallet = wallets[walletId];
  if (!wallet || wallet.usdc < amount) return null;

  const ethOut = ethOutFromSwap(amount, feeBps);
  const nextUsdc = wallet.usdc - amount;
  const wasPending = Boolean(wallet.keeperPending);
  const now = demoNow();
  const windowLive =
    (wallet.windowStart ?? 0) > 0 && now < (wallet.windowStart ?? 0) + ACTIVITY_WINDOW_MS;
  const nextOps = windowLive ? (wallet.opsInWindow ?? 0) + 1 : 1;
  const nextWindowUsd = windowLive ? (wallet.windowUsd ?? 0) + amount : amount;
  const dailyLive =
    (wallet.dailyStart ?? 0) > 0 && now < (wallet.dailyStart ?? 0) + DAILY_WINDOW_MS;
  const nextDailyUsd = dailyLive ? (wallet.dailyUsd ?? 0) + amount : amount;

  return {
    ...wallets,
    [walletId]: {
      ...wallet,
      usdc: nextUsdc,
      eth: Math.round((wallet.eth + ethOut) * 10_000) / 10_000,
      lastKnownUsdc: nextUsdc,
      lastKnownAt: now,
      lastScoreAt: wasPending ? now : wallet.lastScoreAt,
      opsInWindow: nextOps,
      windowUsd: nextWindowUsd,
      windowStart: windowLive ? wallet.windowStart : now,
      dailyUsd: nextDailyUsd,
      dailyStart: dailyLive ? wallet.dailyStart : now,
      // Offline catch-up: after latency swap, clear pending so hop score applies next.
      keeperPending: false,
      accountLabel:
        wasPending && wallet.hopDistance != null
          ? `Account ${wallet.id} · ${wallet.hopDistance}-hop`
          : wallet.accountLabel,
      role:
        wasPending && wallet.hopDistance != null
          ? `${wallet.hopDistance}-hop from origin ${wallet.originId ?? EXPLOIT_SOURCE}`
          : wallet.role,
    },
  };
}
