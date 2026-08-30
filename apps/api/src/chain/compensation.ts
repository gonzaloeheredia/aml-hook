/**
 * LpCompensationVault adapter: accrue, close epoch (merkle), claim.
 */

import type { Address, Hex } from "viem";
import { erc20Abi, vaultAbi } from "./abi.js";
import { keeperWallet, publicClient, requireChain } from "./clients.js";
import { getChainConfig } from "./config.js";
import { weiToUsdc } from "./units.js";
import { buildMerkle, compensationLeaf, splitPot } from "./merkle.js";

export type ClaimLeaf = {
  account: Address;
  amount: string;
  amountUsdc: number;
  proof: Hex[];
  claimed: boolean;
};

export type EpochView = {
  id: number;
  openedAt: number;
  closedAt: number;
  claimUntil: number;
  merkleRoot: Hex;
  endBlock: number;
  pot: string;
  potUsdc: number;
  open: boolean;
  leaves: ClaimLeaf[];
};

const epochLeaves = new Map<number, { token: Address; leaves: Omit<ClaimLeaf, "claimed">[] }>();

function vaultAddress(): Address {
  const cfg = getChainConfig();
  if (cfg.lpCompensationVault === "0x0000000000000000000000000000000000000000") {
    throw new Error("LpCompensationVault is not configured");
  }
  return cfg.lpCompensationVault;
}

export async function compensationOverview(account?: Address) {
  await requireChain();
  const cfg = getChainConfig();
  const vault = vaultAddress();
  const client = publicClient();
  const openId = Number(
    await client.readContract({ address: vault, abi: vaultAbi, functionName: "epochId" }),
  );
  const accounted = await client.readContract({
    address: vault,
    abi: vaultAbi,
    functionName: "accounted",
    args: [cfg.feeToken],
  });
  const tokenBal = await client.readContract({
    address: cfg.feeToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
  });

  const epochs: EpochView[] = [];
  for (let id = 1; id <= openId; id++) {
    epochs.push(await readEpoch(id, account));
  }

  return {
    vault,
    feeToken: cfg.feeToken,
    recipients: cfg.compensationLps,
    accounted: accounted.toString(),
    accountedUsdc: weiToUsdc(accounted),
    balance: tokenBal.toString(),
    balanceUsdc: weiToUsdc(tokenBal),
    openEpochId: openId,
    epochs,
  };
}

async function readEpoch(id: number, account?: Address): Promise<EpochView> {
  const cfg = getChainConfig();
  const vault = vaultAddress();
  const client = publicClient();
  const [info, pot] = await Promise.all([
    client.readContract({ address: vault, abi: vaultAbi, functionName: "epochInfo", args: [BigInt(id)] }),
    client.readContract({
      address: vault,
      abi: vaultAbi,
      functionName: "epochPot",
      args: [BigInt(id), cfg.feeToken],
    }),
  ]);
  const stored = epochLeaves.get(id);
  const leaves: ClaimLeaf[] = [];
  for (const leaf of stored?.leaves ?? []) {
    const claimed = await client.readContract({
      address: vault,
      abi: vaultAbi,
      functionName: "claimed",
      args: [BigInt(id), cfg.feeToken, leaf.account],
    });
    if (account && leaf.account.toLowerCase() !== account.toLowerCase()) continue;
    leaves.push({ ...leaf, claimed });
  }
  return {
    id,
    openedAt: Number(info[0]),
    closedAt: Number(info[1]),
    claimUntil: Number(info[2]),
    merkleRoot: info[3],
    endBlock: Number(info[4]),
    pot: pot.toString(),
    potUsdc: weiToUsdc(pot),
    open: Number(info[1]) === 0,
    leaves,
  };
}

export async function accrueOpenEpoch(): Promise<Hex | null> {
  await requireChain();
  const cfg = getChainConfig();
  const vault = vaultAddress();
  const { account, client } = keeperWallet();
  try {
    const hash = await client.writeContract({
      address: vault,
      abi: vaultAbi,
      functionName: "accrue",
      args: [cfg.feeToken],
      account,
      chain: client.chain,
    });
    await publicClient().waitForTransactionReceipt({ hash });
    return hash;
  } catch {
    return null;
  }
}

export async function accrueFromEscrow(escrowId: number): Promise<Hex> {
  await requireChain();
  const vault = vaultAddress();
  const { account, client } = keeperWallet();
  const hash = await client.writeContract({
    address: vault,
    abi: vaultAbi,
    functionName: "accrueFromEscrow",
    args: [BigInt(escrowId)],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function closeCompensationEpoch() {
  await requireChain();
  const cfg = getChainConfig();
  const vault = vaultAddress();
  const { account, client } = keeperWallet();
  const publicC = publicClient();

  await accrueOpenEpoch();

  const openId = Number(
    await publicC.readContract({ address: vault, abi: vaultAbi, functionName: "epochId" }),
  );
  const pot = await publicC.readContract({
    address: vault,
    abi: vaultAbi,
    functionName: "epochPot",
    args: [BigInt(openId), cfg.feeToken],
  });
  if (pot === 0n) {
    throw new Error("open epoch pot is zero: release a clean RiskFee first");
  }

  const recipients = cfg.compensationLps;
  if (recipients.length === 0) throw new Error("COMPENSATION_LPS is empty");
  const amounts = splitPot(pot, recipients);
  const hashed = recipients.map((addr, i) => compensationLeaf(addr, cfg.feeToken, amounts[i]));
  const { root, proofs } = buildMerkle(hashed);
  const block = await publicC.getBlockNumber();

  const hash = await client.writeContract({
    address: vault,
    abi: vaultAbi,
    functionName: "closeEpoch",
    args: [root, block],
    account,
    chain: client.chain,
  });
  await publicC.waitForTransactionReceipt({ hash });

  epochLeaves.set(openId, {
    token: cfg.feeToken,
    leaves: recipients.map((addr, i) => ({
      account: addr,
      amount: amounts[i].toString(),
      amountUsdc: weiToUsdc(amounts[i]),
      proof: proofs[i],
    })),
  });

  return { txHash: hash, epochId: openId, root, overview: await compensationOverview() };
}

export async function claimCompensation(epochId: number, account: Address): Promise<Hex> {
  await requireChain();
  const cfg = getChainConfig();
  const vault = vaultAddress();
  const stored = epochLeaves.get(epochId);
  const leaf = stored?.leaves.find((l) => l.account.toLowerCase() === account.toLowerCase());
  if (!leaf) throw new Error("no merkle leaf for that account in this epoch");
  const { account: signer, client } = keeperWallet();
  const hash = await client.writeContract({
    address: vault,
    abi: vaultAbi,
    functionName: "claim",
    args: [BigInt(epochId), account, cfg.feeToken, BigInt(leaf.amount), leaf.proof],
    account: signer,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}
