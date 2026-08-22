/**
 * Decision truth: AmlHook.previewSwap (same path as beforeSwap).
 * No TypeScript applyFullPolicy fork.
 */

import { decodeErrorResult, type Address } from "viem";
import type {
  Decision,
  HookOutput,
  LatencyMitigation,
  RevertReason,
} from "../types.js";
import { hookAbi, oracleAbi } from "./abi.js";
import { publicClient, requireChain } from "./clients.js";
import { getChainConfig } from "./config.js";

export type ChainRisk = {
  score: number;
  hopDistance: number;
  origin: Address;
  feeBps: number;
  updatedAt: number;
};

export type PreviewResult = {
  decision: Decision;
  hookOutput: HookOutput;
  feeBps: number;
  risk: ChainRisk;
  revertReason: RevertReason;
  latencyMitigation: LatencyMitigation;
  isStale: boolean;
  opsInWindow: number;
  neverScored: boolean;
  hasSignificantInflow: boolean;
  inflowUsd: number;
  assessedUsd: number;
  priceFeedBound: boolean;
};

const ZERO = "0x0000000000000000000000000000000000000000";

function toDecision(d: number): Decision {
  if (d === 1) return "fee_override";
  if (d === 2) return "block";
  return "allow";
}

function toHookOutput(d: Decision): HookOutput {
  if (d === "fee_override") return "FEE_OVERRIDE";
  if (d === "block") return "REVERT";
  return "ALLOW";
}

function decodeRevert(err: unknown): {
  revertReason: RevertReason;
  latencyMitigation: LatencyMitigation;
  assessedUsd: number;
  inflowUsd: number;
} {
  const raw =
    err && typeof err === "object" && "data" in err
      ? String((err as { data?: string }).data ?? "")
      : "";
  const walk = err as { cause?: { data?: string }; message?: string };
  const data =
    raw.startsWith("0x")
      ? raw
      : typeof walk?.cause?.data === "string"
        ? walk.cause.data
        : "";
  try {
    if (data.startsWith("0x")) {
      const decoded = decodeErrorResult({ abi: hookAbi, data: data as `0x${string}` });
      if (decoded.errorName === "WalletBlocked") {
        return {
          revertReason: "WalletBlocked",
          latencyMitigation: null,
          assessedUsd: 0,
          inflowUsd: 0,
        };
      }
      if (decoded.errorName === "SanctionHit") {
        return {
          revertReason: "SanctionHit",
          latencyMitigation: null,
          assessedUsd: 0,
          inflowUsd: 0,
        };
      }
      if (decoded.errorName === "UnscoredMagnitudeBlocked") {
        const assessed = Number(decoded.args[1]) / 1e8;
        return {
          revertReason: "UnscoredMagnitudeBlocked",
          latencyMitigation: "SCORE_NEVER_WRITTEN",
          assessedUsd: assessed,
          inflowUsd: 0,
        };
      }
      if (decoded.errorName === "InflowMagnitudeBlocked") {
        const inflow = Number(decoded.args[1]) / 1e8;
        return {
          revertReason: "InflowMagnitudeBlocked",
          latencyMitigation: "INFLOW_MAGNITUDE",
          assessedUsd: 0,
          inflowUsd: inflow,
        };
      }
      if (decoded.errorName === "MagnitudeQuoteFailed") {
        return {
          revertReason: "MagnitudeQuoteFailed",
          latencyMitigation: "MAGNITUDE_QUOTE_FAILED",
          assessedUsd: 0,
          inflowUsd: 0,
        };
      }
    }
  } catch {
    /* fall through */
  }
  const msg = err instanceof Error ? err.message : String(err);
  if (msg.includes("MagnitudeQuoteFailed")) {
    return {
      revertReason: "MagnitudeQuoteFailed",
      latencyMitigation: "MAGNITUDE_QUOTE_FAILED",
      assessedUsd: 0,
      inflowUsd: 0,
    };
  }
  if (msg.includes("UnscoredMagnitudeBlocked")) {
    return {
      revertReason: "UnscoredMagnitudeBlocked",
      latencyMitigation: null,
      assessedUsd: 0,
      inflowUsd: 0,
    };
  }
  if (msg.includes("InflowMagnitudeBlocked")) {
    return {
      revertReason: "InflowMagnitudeBlocked",
      latencyMitigation: "INFLOW_MAGNITUDE",
      assessedUsd: 0,
      inflowUsd: 0,
    };
  }
  if (msg.includes("SanctionHit")) {
    return {
      revertReason: "SanctionHit",
      latencyMitigation: null,
      assessedUsd: 0,
      inflowUsd: 0,
    };
  }
  return {
    revertReason: "WalletBlocked",
    latencyMitigation: null,
    assessedUsd: 0,
    inflowUsd: 0,
  };
}

async function inferFloor(
  wallet: Address,
  risk: ChainRisk,
  feeBps: number,
  decision: Decision,
): Promise<{
  latencyMitigation: LatencyMitigation;
  isStale: boolean;
  opsInWindow: number;
  neverScored: boolean;
  hasSignificantInflow: boolean;
  inflowUsd: number;
  priceFeedBound: boolean;
}> {
  const cfg = getChainConfig();
  const client = publicClient();
  const [activity, lastKnown, now, staleness, maxOps, inflowBps, feed] =
    await Promise.all([
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "poolActivity",
        args: [wallet],
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "lastKnownBalance",
        args: [wallet, cfg.feeToken],
      }),
      client.getBlock({ blockTag: "latest" }).then((b) => Number(b.timestamp)),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "stalenessThreshold",
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "maxOpsInWindow",
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "inflowThresholdBps",
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "priceFeeds",
        args: [cfg.feeToken],
      }),
    ]);

  const neverScored = risk.updatedAt === 0;
  const isStale =
    neverScored || now > risk.updatedAt + Number(staleness);
  const opsInWindow = Number(activity[1]);
  const priceFeedBound = feed !== ZERO;

  const { erc20Abi } = await import("./abi.js");
  const [bal, tokenDecimals] = await Promise.all([
    client.readContract({
      address: cfg.feeToken,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [wallet],
    }),
    client.readContract({
      address: cfg.feeToken,
      abi: erc20Abi,
      functionName: "decimals",
    }).catch(() => 18 as number),
  ]);
  const divisor = 10 ** tokenDecimals;
  const inflowWei = bal > lastKnown ? bal - lastKnown : 0n;
  const inflowUsd = Number(inflowWei) / divisor;
  const currentUsd = Number(bal) / divisor;
  const deltaBps =
    currentUsd > 0 ? Math.floor((inflowUsd * 10_000) / currentUsd) : 0;
  const hasSignificantInflow = deltaBps > Number(inflowBps);

  let latencyMitigation: LatencyMitigation = null;
  if (decision === "fee_override") {
    if (neverScored) latencyMitigation = "SCORE_NEVER_WRITTEN";
    else if (isStale && opsInWindow > 0) {
      latencyMitigation = "STALE_WITH_POOL_ACTIVITY";
    } else if (opsInWindow >= Number(maxOps)) {
      latencyMitigation = "ACTIVITY_WINDOW_CAP";
    } else if (hasSignificantInflow) {
      latencyMitigation = "INFLOW_HEURISTIC";
    }
  }

  return {
    latencyMitigation,
    isStale,
    opsInWindow,
    neverScored,
    hasSignificantInflow,
    inflowUsd,
    priceFeedBound,
  };
}

export async function readRisk(wallet: Address): Promise<ChainRisk> {
  const cfg = getChainConfig();
  const risk = await publicClient().readContract({
    address: cfg.oracle,
    abi: oracleAbi,
    functionName: "getRisk",
    args: [wallet],
  });
  return {
    score: Number(risk.score),
    hopDistance: Number(risk.hopDistance),
    origin: risk.origin,
    feeBps: Number(risk.feeBps),
    updatedAt: Number(risk.updatedAt),
  };
}

/**
 * eth_call previewSwap. REVERT becomes decision=block with the custom-error name.
 */
export async function previewSwap(
  wallet: Address,
  amountWei: bigint,
): Promise<PreviewResult> {
  await requireChain();
  const cfg = getChainConfig();
  const client = publicClient();
  try {
    const [decisionRaw, feeRaw, riskRaw] = await client.readContract({
      address: cfg.hook,
      abi: hookAbi,
      functionName: "previewSwap",
      args: [wallet, cfg.feeToken, amountWei],
    });
    const decision = toDecision(Number(decisionRaw));
    const risk: ChainRisk = {
      score: Number(riskRaw.score),
      hopDistance: Number(riskRaw.hopDistance),
      origin: riskRaw.origin,
      feeBps: Number(riskRaw.feeBps),
      updatedAt: Number(riskRaw.updatedAt),
    };
    const feeBps = decision === "allow" ? 30 : Number(feeRaw);
    const inferred = await inferFloor(wallet, risk, feeBps, decision);
    return {
      decision,
      hookOutput: toHookOutput(decision),
      feeBps,
      risk,
      revertReason: null,
      assessedUsd: Number(amountWei) / 1e18,
      ...inferred,
    };
  } catch (err) {
    const decoded = decodeRevert(err);
    const risk = await readRisk(wallet).catch(() => ({
      score: 0,
      hopDistance: 0,
      origin: ZERO as Address,
      feeBps: 0,
      updatedAt: 0,
    }));
    const inferred = await inferFloor(wallet, risk, 0, "block").catch(() => ({
      latencyMitigation: decoded.latencyMitigation,
      isStale: risk.updatedAt === 0,
      opsInWindow: 0,
      neverScored: risk.updatedAt === 0,
      hasSignificantInflow: false,
      inflowUsd: decoded.inflowUsd,
      priceFeedBound: true,
    }));
    return {
      decision: "block",
      hookOutput: "REVERT",
      feeBps: 0,
      risk,
      revertReason: decoded.revertReason,
      latencyMitigation:
        decoded.latencyMitigation ?? inferred.latencyMitigation,
      isStale: inferred.isStale,
      opsInWindow: inferred.opsInWindow,
      neverScored: inferred.neverScored,
      hasSignificantInflow: inferred.hasSignificantInflow,
      inflowUsd: decoded.inflowUsd || inferred.inflowUsd,
      assessedUsd: decoded.assessedUsd || Number(amountWei) / 1e18,
      priceFeedBound: inferred.priceFeedBound,
    };
  }
}
