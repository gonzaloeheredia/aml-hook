/**
 * ComplianceTreasury adapter: ledgers + delayed allowlisted payouts.
 */

import { getAddress, isAddress, keccak256, toBytes, type Address, type Hex } from "viem";
import { treasuryAbi } from "./abi.js";
import { keeperWallet, publicClient, requireChain } from "./clients.js";
import { getChainConfig } from "./config.js";
import { weiToUsdc } from "./units.js";

const ACCOUNT = ["LP_PRINCIPAL", "ILLICIT_RISK_FEE"] as const;
const STATUS = ["Pending", "Executed", "Cancelled"] as const;

export type TreasuryPayout = {
  id: number;
  account: (typeof ACCOUNT)[number];
  token: Address;
  amount: string;
  amountUsdc: number;
  to: Address;
  fileHash: Hex;
  memo: string;
  proposedAt: number;
  escrowId: number;
  fingerprint: Hex;
  status: (typeof STATUS)[number];
};

function treasuryAddress(): Address {
  const cfg = getChainConfig();
  if (cfg.complianceReserve === "0x0000000000000000000000000000000000000000") {
    throw new Error("ComplianceTreasury is not configured");
  }
  return cfg.complianceReserve;
}

export async function treasuryOverview() {
  await requireChain();
  const cfg = getChainConfig();
  const treasury = treasuryAddress();
  const client = publicClient();
  const [principal, fee, nextId, delay] = await Promise.all([
    client.readContract({
      address: treasury,
      abi: treasuryAbi,
      functionName: "balances",
      args: [0, cfg.feeToken],
    }),
    client.readContract({
      address: treasury,
      abi: treasuryAbi,
      functionName: "balances",
      args: [1, cfg.feeToken],
    }),
    client.readContract({ address: treasury, abi: treasuryAbi, functionName: "nextPayoutId" }),
    client.readContract({ address: treasury, abi: treasuryAbi, functionName: "PAYOUT_DELAY" }),
  ]);

  const payouts: TreasuryPayout[] = [];
  for (let id = 1; id < Number(nextId); id++) {
    payouts.push(await readPayout(id));
  }

  return {
    treasury,
    feeToken: cfg.feeToken,
    payoutDelaySec: Number(delay),
    lpPrincipal: principal.toString(),
    lpPrincipalUsdc: weiToUsdc(principal),
    illicitRiskFee: fee.toString(),
    illicitRiskFeeUsdc: weiToUsdc(fee),
    payouts,
  };
}

async function readPayout(id: number): Promise<TreasuryPayout> {
  const treasury = treasuryAddress();
  const rec = await publicClient().readContract({
    address: treasury,
    abi: treasuryAbi,
    functionName: "getPayout",
    args: [BigInt(id)],
  });
  return {
    id,
    account: ACCOUNT[Number(rec.account)] ?? "ILLICIT_RISK_FEE",
    token: rec.token,
    amount: rec.amount.toString(),
    amountUsdc: weiToUsdc(rec.amount),
    to: rec.to,
    fileHash: rec.fileHash,
    memo: rec.memo,
    proposedAt: Number(rec.proposedAt),
    escrowId: Number(rec.escrowId),
    fingerprint: rec.fingerprint,
    status: STATUS[Number(rec.status)] ?? "Pending",
  };
}

export async function setTreasuryDestination(dest: Address, allowed: boolean): Promise<Hex> {
  await requireChain();
  const treasury = treasuryAddress();
  const { account, client } = keeperWallet();
  const hash = await client.writeContract({
    address: treasury,
    abi: treasuryAbi,
    functionName: "setDestination",
    args: [dest, allowed],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function proposeTreasuryPayout(input: {
  account: "LP_PRINCIPAL" | "ILLICIT_RISK_FEE";
  amountWei?: bigint;
  amountUsdc?: number;
  to: string;
  memo?: string;
  fileHash?: Hex;
  escrowId?: number;
  fingerprint?: Hex;
}): Promise<{ txHash: Hex; payoutId: number }> {
  await requireChain();
  if (!isAddress(input.to)) throw new Error("invalid payout destination");
  const cfg = getChainConfig();
  const treasury = treasuryAddress();
  const { account, client } = keeperWallet();
  const publicC = publicClient();
  const amount =
    input.amountWei ??
    (input.amountUsdc != null ? BigInt(Math.round(input.amountUsdc)) * 10n ** 6n : 0n);
  if (amount <= 0n) throw new Error("amount required");
  const fileHash =
    input.fileHash ??
    keccak256(toBytes(input.memo?.trim() || `payout:${Date.now()}`));
  const nextId = await publicC.readContract({
    address: treasury,
    abi: treasuryAbi,
    functionName: "nextPayoutId",
  });
  const hash = await client.writeContract({
    address: treasury,
    abi: treasuryAbi,
    functionName: "proposePayout",
    args: [
      input.account === "LP_PRINCIPAL" ? 0 : 1,
      cfg.feeToken,
      amount,
      getAddress(input.to),
      fileHash,
      input.memo ?? "",
      BigInt(input.escrowId ?? 0),
      (input.fingerprint ??
        "0x0000000000000000000000000000000000000000000000000000000000000000") as Hex,
    ],
    account,
    chain: client.chain,
  });
  await publicC.waitForTransactionReceipt({ hash });
  return { txHash: hash, payoutId: Number(nextId) };
}

export async function executeTreasuryPayout(payoutId: number): Promise<Hex> {
  await requireChain();
  const treasury = treasuryAddress();
  const { account, client } = keeperWallet();
  const hash = await client.writeContract({
    address: treasury,
    abi: treasuryAbi,
    functionName: "executePayout",
    args: [BigInt(payoutId)],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function cancelTreasuryPayout(payoutId: number): Promise<Hex> {
  await requireChain();
  const treasury = treasuryAddress();
  const { account, client } = keeperWallet();
  const hash = await client.writeContract({
    address: treasury,
    abi: treasuryAbi,
    functionName: "cancelPayout",
    args: [BigInt(payoutId)],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}
