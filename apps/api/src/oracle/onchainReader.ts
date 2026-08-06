/**
 * beforeSwap-style score read from ComplianceOracle (REAL eth_call when RPC is set).
 * Used by the demo API hybrid path instead of only reading the in-memory COA cache.
 * Returns null / ignores unset rows (updatedAt==0) so MOCK memory/hop can still apply.
 */

import { createPublicClient, http, type Address } from "viem";
import { anvil } from "viem/chains";
import { complianceOracleAbi } from "./abi.js";
import { getPublishMode } from "./onchainPublisher.js";

export type ScoreSource = "onchain" | "memory" | "hop";

let client: ReturnType<typeof createPublicClient> | null = null;

function getClient() {
  if (client) return client;
  const rpc = process.env.ORACLE_RPC_URL?.trim();
  if (!rpc) return null;
  const chain = {
    ...anvil,
    id: Number(process.env.ORACLE_CHAIN_ID ?? anvil.id),
  };
  client = createPublicClient({ chain, transport: http(rpc) });
  return client;
}

/**
 * True when demo should prefer on-chain getScore (rpc env + SCORE_SOURCE=onchain).
 */
export function preferOnChainScore(): boolean {
  if (getPublishMode() !== "rpc") return false;
  const src = (process.env.SCORE_SOURCE ?? "onchain").toLowerCase();
  return src === "onchain" || src === "hybrid";
}

/**
 * eth_call ComplianceOracle.getScore(wallet). Returns null if unavailable.
 */
export async function readScoreFromChain(
  walletAddress: string,
): Promise<number | null> {
  const oracle = process.env.COMPLIANCE_ORACLE_ADDRESS?.trim() as
    | Address
    | undefined;
  const publicClient = getClient();
  if (!oracle || !publicClient) return null;

  try {
    const score = await publicClient.readContract({
      address: oracle,
      abi: complianceOracleAbi,
      functionName: "getScore",
      args: [walletAddress as Address],
    });
    return Number(score);
  } catch {
    return null;
  }
}

/**
 * eth_call ComplianceOracle.getRisk(wallet).
 */
export async function readRiskFromChain(walletAddress: string): Promise<{
  score: number;
  hopDistance: number;
  origin: string;
  feeBps: number;
  updatedAt: number;
} | null> {
  const oracle = process.env.COMPLIANCE_ORACLE_ADDRESS?.trim() as
    | Address
    | undefined;
  const publicClient = getClient();
  if (!oracle || !publicClient) return null;

  try {
    const risk = await publicClient.readContract({
      address: oracle,
      abi: complianceOracleAbi,
      functionName: "getRisk",
      args: [walletAddress as Address],
    });
    return {
      score: Number(risk.score),
      hopDistance: Number(risk.hopDistance),
      origin: risk.origin,
      feeBps: Number(risk.feeBps),
      updatedAt: Number(risk.updatedAt),
    };
  } catch {
    return null;
  }
}
