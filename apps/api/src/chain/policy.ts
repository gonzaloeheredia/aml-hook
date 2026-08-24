/**
 * Live policy knobs from AmlHookLogic. Demo labels / hop helpers follow these
 * instead of hardcoded 3% / 8% / $1,000 / $15,000.
 */

import { hookAbi } from "./abi.js";
import { publicClient, requireChain } from "./clients.js";
import { getChainConfig } from "./config.js";

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

const USD8 = 10 ** 8;
const TTL_MS = 5_000;

let cache: { knobs: PolicyKnobs; at: number } | null = null;

function usd8ToNumber(value: bigint): number {
  return Number(value) / USD8;
}

export function getPolicyKnobsSync(): PolicyKnobs {
  return cache?.knobs ?? DEFAULT_POLICY_KNOBS;
}

export function formatFeePct(bps: number): string {
  if (bps % 100 === 0) return `${bps / 100}%`;
  return `${(bps / 100).toFixed(2)}%`;
}

export function formatUsdFloor(usd: number): string {
  return `$${usd.toLocaleString("en-US")}`;
}

export async function readPolicyKnobs(force = false): Promise<PolicyKnobs> {
  if (!force && cache && Date.now() - cache.at < TTL_MS) {
    return cache.knobs;
  }
  try {
    await requireChain();
    const cfg = getChainConfig();
    const client = publicClient();
    const [feeTh, revertTh, proportional, punitive, poolImpact] = await Promise.all([
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "unscoredFeeThreshold",
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "unscoredRevertThreshold",
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "proportionalFeeBps",
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "punitiveFeeBps",
      }),
      client.readContract({
        address: cfg.hook,
        abi: hookAbi,
        functionName: "poolImpactThresholdBps",
      }),
    ]);
    const knobs: PolicyKnobs = {
      unscoredFeeThresholdUsd: usd8ToNumber(feeTh),
      unscoredRevertThresholdUsd: usd8ToNumber(revertTh),
      proportionalFeeBps: Number(proportional),
      punitiveFeeBps: Number(punitive),
      poolImpactThresholdBps: Number(poolImpact),
    };
    cache = { knobs, at: Date.now() };
    return knobs;
  } catch {
    return getPolicyKnobsSync();
  }
}

export function clearPolicyKnobsCache(): void {
  cache = null;
}
