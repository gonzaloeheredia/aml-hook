/**
 * Oracle Keeper → ComplianceOracle.updateScore
 *
 * Signs with the distinct attestor key, then the keeper submits the tx.
 * No invented receipts. If Anvil is down the write fails closed.
 */

import type { Address, Hex } from "viem";
import { publishScore } from "../chain/attestor.js";
import { requireChain } from "../chain/clients.js";
import { getWallet } from "../store.js";
import type { Wallet } from "../types.js";
import type { ScorePublishResult, ScoreResult } from "./types.js";

export type PublishMode = "rpc";

/** On-chain FeeBps.MAX_OVERRIDE is 1_000. Keeper writes cannot exceed that. */
export function capPublishedFeeBps(recommendedFeeBps: number): number {
  return Math.min(1_000, Math.max(0, Math.round(recommendedFeeBps)));
}

const publishes: ScorePublishResult[] = [];

export function getPublishMode(): PublishMode {
  return "rpc";
}

export function getPublisherStatus() {
  return {
    mode: "rpc" as const,
    channel: "compliance-oracle-rpc",
    agent: "Compliance Officer Agent",
    oracleAddress: process.env.COMPLIANCE_ORACLE_ADDRESS ?? null,
    rpcConfigured: Boolean(process.env.ORACLE_RPC_URL?.trim()),
    publishCount: publishes.length,
  };
}

export function listScorePublishes(limit = 50): ScorePublishResult[] {
  return publishes.slice(-limit);
}

export function clearScorePublishes(): void {
  publishes.length = 0;
}

function resolveOriginAddress(wallet: Wallet): Address {
  if (wallet.exploitConfirmed) return wallet.address as Address;
  if (!wallet.originId) return "0x0000000000000000000000000000000000000000";
  const origin = getWallet(wallet.originId);
  return (origin?.address ??
    "0x0000000000000000000000000000000000000000") as Address;
}

export async function publishScoreToChain(
  wallet: Wallet,
  score: ScoreResult,
): Promise<ScorePublishResult> {
  const hopDistance =
    wallet.hopDistance == null ? 0 : Math.min(255, Math.max(0, wallet.hopDistance));
  const origin = resolveOriginAddress(wallet);
  const feeBps = capPublishedFeeBps(score.recommendedFeeBps);
  const base = {
    walletId: wallet.id,
    address: wallet.address,
    score: score.finalScore,
    hopDistance,
    origin,
    feeBps,
    at: new Date().toISOString(),
  };

  try {
    await requireChain();
    const hash: Hex = await publishScore({
      wallet: wallet.address as Address,
      score: score.finalScore,
      hopDistance,
      origin,
      feeBps,
    });
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
