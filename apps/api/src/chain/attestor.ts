/**
 * ECDSA attestor for ComplianceOracle.updateScore (C-01).
 * Signs attestationHash(wallet, score, hop, origin, feeBps, updatedAt, chainid)
 * as an Ethereum signed message — same payload the contract recovers.
 */

import type { Address, Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { oracleAbi } from "./abi.js";
import { anvilRpc, publicClient, walletClient } from "./clients.js";
import { getChainConfig } from "./config.js";

export async function signAttestation(input: {
  wallet: Address;
  score: number;
  hopDistance: number;
  origin: Address;
  feeBps: number;
  updatedAt: bigint;
}): Promise<Hex> {
  const cfg = getChainConfig();
  const client = publicClient();
  const hash = await client.readContract({
    address: cfg.oracle,
    abi: oracleAbi,
    functionName: "attestationHash",
    args: [
      input.wallet,
      input.score,
      input.hopDistance,
      input.origin,
      input.feeBps,
      input.updatedAt,
    ],
  });
  const account = privateKeyToAccount(cfg.attestorKey);
  return account.signMessage({ message: { raw: hash } });
}

/**
 * Pin the next Anvil block timestamp, sign over that time, then updateScore.
 */
export async function publishScore(input: {
  wallet: Address;
  score: number;
  hopDistance: number;
  origin: Address;
  feeBps: number;
}): Promise<Hex> {
  const cfg = getChainConfig();
  const client = publicClient();
  const { account, client: wallet } = walletClient(cfg.keeperKey);

  const latest = await client.getBlock({ blockTag: "latest" });
  const updatedAt = latest.timestamp + 1n;
  await anvilRpc("evm_setNextBlockTimestamp", [Number(updatedAt)]);

  const signature = await signAttestation({ ...input, updatedAt });
  const hash = await wallet.writeContract({
    address: cfg.oracle,
    abi: oracleAbi,
    functionName: "updateScore",
    args: [
      input.wallet,
      input.score,
      input.hopDistance,
      input.origin,
      input.feeBps,
      signature,
    ],
    account,
    chain: wallet.chain,
  });
  await client.waitForTransactionReceipt({ hash });
  return hash;
}
