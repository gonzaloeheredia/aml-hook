/**
 * Oracle Keeper → ComplianceOracle.updateScore
 *
 * Modes:
 * - mock (default): MOCK — record the intended write in memory only (no RPC / no tx)
 * - rpc: REAL — broadcast updateScore when ORACLE_RPC_URL + COMPLIANCE_ORACLE_ADDRESS +
 *   KEEPER_PRIVATE_KEY are set (e.g. after `npm run deploy:local` → apps/api/.env.local)
 */

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
  return {
    mode: getPublishMode(),
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
  const base = {
    walletId: wallet.id,
    address: wallet.address,
    score: score.finalScore,
    hopDistance,
    origin,
    at: new Date().toISOString(),
  };

  const mode = getPublishMode();
  if (mode === "mock") {
    const result: ScorePublishResult = {
      ...base,
      mode: "mock",
      status: "recorded",
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
