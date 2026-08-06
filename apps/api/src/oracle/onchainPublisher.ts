/**
 * Oracle Keeper → ComplianceOracle.updateScore
 *
 * Writes COA finalScore + recommendedFeeBps (feeBps on-chain).
 * Without RPC env, issues a virtual keeper receipt (txHash) so the trail looks live.
 * With RPC env, broadcasts a real updateScore tx.
 */

import { createHash } from "node:crypto";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { anvil } from "viem/chains";
import { getWallet } from "../store.js";
import type { Wallet } from "../types.js";
import { complianceOracleAbi } from "./abi.js";
import type { ScorePublishResult, ScoreResult } from "./types.js";

export type PublishMode = "mock" | "rpc";

function virtualTxHash(wallet: Wallet, score: ScoreResult): Hex {
  const digest = createHash("sha256")
    .update(
      [
        wallet.address,
        score.finalScore,
        score.recommendedFeeBps,
        score.auditHash,
        score.validity.calculatedAt,
      ].join(":"),
    )
    .digest("hex");
  return `0x${digest}` as Hex;
}

const publishes: ScorePublishResult[] = [];

/**
 * Resolves publisher mode from env.
 */
export function getPublishMode(): PublishMode {
  const rpc = process.env.ORACLE_RPC_URL?.trim();
  const oracle = process.env.COMPLIANCE_ORACLE_ADDRESS?.trim();
  const key = process.env.KEEPER_PRIVATE_KEY?.trim();
  if (rpc && oracle && key) return "rpc";
  return "mock";
}

/**
 * Publisher status for /health.
 */
export function getPublisherStatus() {
  const mode = getPublishMode();
  return {
    mode,
    channel: mode === "rpc" ? "compliance-oracle-rpc" : "compliance-oracle-virtual",
    agent: "Compliance Officer Agent",
    oracleAddress: process.env.COMPLIANCE_ORACLE_ADDRESS ?? null,
    rpcConfigured: Boolean(process.env.ORACLE_RPC_URL?.trim()),
    publishCount: publishes.length,
  };
}

/**
 * Recent on-chain publish attempts (mock + rpc).
 */
export function listScorePublishes(limit = 50): ScorePublishResult[] {
  return publishes.slice(-limit);
}

/**
 * Clears the publish trail (used on POST /reset).
 */
export function clearScorePublishes(): void {
  publishes.length = 0;
}

/**
 * Maps demo originId (A/B/C) to an address, or zero for clean wallets.
 */
function resolveOriginAddress(wallet: Wallet): Address {
  if (wallet.exploitConfirmed) return wallet.address as Address;
  if (!wallet.originId) return "0x0000000000000000000000000000000000000000";
  const origin = getWallet(wallet.originId);
  return (origin?.address ??
    "0x0000000000000000000000000000000000000000") as Address;
}

/**
 * Writes score to ComplianceOracle (mock record or real tx).
 */
export async function publishScoreToChain(
  wallet: Wallet,
  score: ScoreResult,
): Promise<ScorePublishResult> {
  const hopDistance =
    wallet.hopDistance == null ? 0 : Math.min(255, Math.max(0, wallet.hopDistance));
  const origin = resolveOriginAddress(wallet);
  const feeBps = Math.min(
    10_000,
    Math.max(0, Math.round(score.recommendedFeeBps)),
  );
  const base = {
    walletId: wallet.id,
    address: wallet.address,
    score: score.finalScore,
    hopDistance,
    origin,
    feeBps,
    at: new Date().toISOString(),
  };

  const mode = getPublishMode();
  if (mode === "mock") {
    const result: ScorePublishResult = {
      ...base,
      mode: "mock",
      status: "submitted",
      txHash: virtualTxHash(wallet, score),
    };
    publishes.push(result);
    return result;
  }

  try {
    const rpcUrl = process.env.ORACLE_RPC_URL!.trim();
    const oracleAddress = process.env
      .COMPLIANCE_ORACLE_ADDRESS!.trim() as Address;
    let pk = process.env.KEEPER_PRIVATE_KEY!.trim();
    if (!pk.startsWith("0x")) pk = `0x${pk}`;

    const account = privateKeyToAccount(pk as Hex);
    const chain = {
      ...anvil,
      id: Number(process.env.ORACLE_CHAIN_ID ?? anvil.id),
    };

    const walletClient = createWalletClient({
      account,
      chain,
      transport: http(rpcUrl),
    });
    const publicClient = createPublicClient({
      chain,
      transport: http(rpcUrl),
    });

    const hash = await walletClient.writeContract({
      address: oracleAddress,
      abi: complianceOracleAbi,
      functionName: "updateScore",
      args: [
        wallet.address as Address,
        score.finalScore,
        hopDistance,
        origin,
        feeBps,
        "0x",
      ],
      chain,
      account,
    });

    await publicClient.waitForTransactionReceipt({ hash });

    const result: ScorePublishResult = {
      ...base,
      mode: "rpc",
      status: "submitted",
      txHash: hash,
    };
    publishes.push(result);
    return result;
  } catch (err) {
    const result: ScorePublishResult = {
      ...base,
      mode: "rpc",
      status: "failed",
      error: err instanceof Error ? err.message : String(err),
    };
    publishes.push(result);
    return result;
  }
}
