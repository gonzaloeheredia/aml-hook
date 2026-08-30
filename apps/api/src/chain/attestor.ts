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
 * Sign over `updatedAt` and submit `updateScore`. The contract hashes
 * `block.timestamp` at inclusion, so the signed time must match the mined block.
 */
async function submitScore(
  input: {
    wallet: Address;
    score: number;
    hopDistance: number;
    origin: Address;
    feeBps: number;
  },
  updatedAt: bigint,
): Promise<Hex> {
  const cfg = getChainConfig();
  const client = publicClient();
  const { account, client: wallet } = walletClient(cfg.keeperKey);
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
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status === "reverted") {
    throw new Error("ComplianceOracle.updateScore reverted (attestation or role)");
  }
  return hash;
}

/**
 * Pin the next Anvil block timestamp, or predict Sepolia slots, then updateScore.
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
  const latest = await client.getBlock({ blockTag: "latest" });

  if (cfg.chainId === 31337) {
    const updatedAt = latest.timestamp + 1n;
    await anvilRpc("evm_setNextBlockTimestamp", [Number(updatedAt)]);
    return submitScore(input, updatedAt);
  }

  // Sepolia slots are 12s. Sign the next few slot times and retry if inclusion misses.
  const slot = 12n;
  let lastErr: unknown;
  for (const n of [1n, 2n, 3n]) {
    try {
      return await submitScore(input, latest.timestamp + n * slot);
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr instanceof Error
    ? lastErr
    : new Error("ComplianceOracle.updateScore failed on a live chain");
}
