/**
 * FeeEscrow adapter: deposit the extra slice, list rows, checkpoint 2, recover.
 * Confirmed-illicit recovery goes to complianceReserve only.
 */

import type { Address, Hex } from "viem";
import { erc20Abi, escrowAbi } from "./abi.js";
import { idFromAddress } from "./accounts.js";
import { keeperWallet, publicClient, requireChain } from "./clients.js";
import { getChainConfig } from "./config.js";
import { weiToUsdc } from "./units.js";
import type { WalletId } from "../types.js";

const STATUS = [
  "Active",
  "ReleasedEarly",
  "Blocked",
  "ReleasedDefault",
  "Recovered",
] as const;

export type EscrowRow = {
  id: number;
  wallet: Address;
  walletId: WalletId | null;
  token: Address;
  amount: string;
  amountUsdc: number;
  depositedAt: number;
  swapFingerprint: Hex;
  status: (typeof STATUS)[number];
  blockedAt: number;
};

export async function depositFee(
  wallet: Address,
  amountWei: bigint,
  fingerprint: Hex,
): Promise<{ tx: Hex; id: number }> {
  const cfg = getChainConfig();
  const { account, client } = keeperWallet();
  const publicC = publicClient();

  const mintHash = await client.writeContract({
    address: cfg.feeToken,
    abi: erc20Abi,
    functionName: "mint",
    args: [account.address, amountWei],
    account,
    chain: client.chain,
  });
  await publicC.waitForTransactionReceipt({ hash: mintHash });

  const approveHash = await client.writeContract({
    address: cfg.feeToken,
    abi: erc20Abi,
    functionName: "approve",
    args: [cfg.escrow, amountWei],
    account,
    chain: client.chain,
  });
  await publicC.waitForTransactionReceipt({ hash: approveHash });

  const nextId = await publicC.readContract({
    address: cfg.escrow,
    abi: escrowAbi,
    functionName: "nextEscrowId",
  });

  const hash = await client.writeContract({
    address: cfg.escrow,
    abi: escrowAbi,
    functionName: "deposit",
    args: [wallet, cfg.feeToken, fingerprint, amountWei],
    account,
    chain: client.chain,
  });
  await publicC.waitForTransactionReceipt({ hash });
  return { tx: hash, id: Number(nextId) };
}

export async function listEscrows(): Promise<EscrowRow[]> {
  await requireChain();
  const cfg = getChainConfig();
  const { account } = keeperWallet();
  const client = publicClient();
  const next = await client.readContract({
    address: cfg.escrow,
    abi: escrowAbi,
    functionName: "nextEscrowId",
  });
  const rows: EscrowRow[] = [];
  for (let id = 1; id < Number(next); id++) {
    const rec = await client.readContract({
      address: cfg.escrow,
      abi: escrowAbi,
      functionName: "getEscrow",
      args: [BigInt(id)],
      account,
    });
    rows.push({
      id,
      wallet: rec.wallet,
      walletId: idFromAddress(rec.wallet),
      token: rec.token,
      amount: rec.amount.toString(),
      amountUsdc: weiToUsdc(rec.amount),
      depositedAt: Number(rec.depositedAt),
      swapFingerprint: rec.swapFingerprint,
      status: STATUS[Number(rec.status)] ?? "Active",
      blockedAt: Number(rec.blockedAt),
    });
  }
  return rows;
}

export async function resolveCheckpoint2(escrowId: number): Promise<Hex> {
  await requireChain();
  const cfg = getChainConfig();
  const { account, client } = keeperWallet();
  const hash = await client.writeContract({
    address: cfg.escrow,
    abi: escrowAbi,
    functionName: "resolveCheckpoint2",
    args: [BigInt(escrowId)],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function recoverBlocked(escrowId: number): Promise<Hex> {
  await requireChain();
  const cfg = getChainConfig();
  const { account, client } = keeperWallet();
  const hash = await client.writeContract({
    address: cfg.escrow,
    abi: escrowAbi,
    functionName: "recoverBlocked",
    args: [BigInt(escrowId)],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function escrowDestinations() {
  const cfg = getChainConfig();
  const client = publicClient();
  const [reserve, lp] = await Promise.all([
    client.readContract({
      address: cfg.escrow,
      abi: escrowAbi,
      functionName: "complianceReserve",
    }),
    client.readContract({
      address: cfg.escrow,
      abi: escrowAbi,
      functionName: "lpCompensationFund",
    }),
  ]);
  return { complianceReserve: reserve, lpCompensationFund: lp };
}
