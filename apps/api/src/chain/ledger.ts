/**
 * On-chain demo ledger: mint / transfer / observe / warp / price feed.
 * P2P is ERC-20 transfer. A "swap" is preview + observeSwap + optional FeeEscrow.deposit.
 * Not a Uniswap PoolManager swap.
 */

import { keccak256, toBytes, type Address, type Hex } from "viem";
import { DEMO_WALLETS, POOL_SINK, WALLET_IDS, bindOfacDemoWallet, hasSigner } from "./accounts.js";
import { erc20Abi, hookAbi, registryAbi } from "./abi.js";
import { anvilRpc, keeperWallet, publicClient, requireChain, walletClient } from "./clients.js";
import { getChainConfig } from "./config.js";
import { previewSwap, type PreviewResult } from "./evaluate.js";
import { depositFee } from "./escrow.js";
import { usdcToWei, weiToUsdc } from "./units.js";
import type { WalletId } from "../types.js";

const ethCredit: Record<WalletId, number> = {
  A: DEMO_WALLETS.A.eth,
  B: DEMO_WALLETS.B.eth,
  C: DEMO_WALLETS.C.eth,
  D: DEMO_WALLETS.D.eth,
  E: DEMO_WALLETS.E.eth,
  F: DEMO_WALLETS.F.eth,
};

export { usdcToWei, weiToUsdc };

export async function balanceUsdc(address: Address): Promise<number> {
  const cfg = getChainConfig();
  const bal = await publicClient().readContract({
    address: cfg.feeToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [address],
  });
  return weiToUsdc(bal);
}

export function ethDisplay(id: WalletId): number {
  return ethCredit[id];
}

export function resetEthCredits(): void {
  for (const id of WALLET_IDS) ethCredit[id] = DEMO_WALLETS[id].eth;
}

async function writeAsKeeper(
  address: Address,
  abi: typeof hookAbi | typeof erc20Abi | typeof registryAbi,
  functionName: string,
  args: readonly unknown[],
): Promise<Hex> {
  const { account, client } = keeperWallet();
  const hash = await client.writeContract({
    address,
    abi,
    functionName,
    args,
    account,
    chain: client.chain,
  } as never);
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function setTokenBalance(address: Address, usdc: number): Promise<void> {
  const cfg = getChainConfig();
  const target = usdcToWei(usdc);
  const current = await publicClient().readContract({
    address: cfg.feeToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [address],
  });
  if (current < target) {
    await writeAsKeeper(cfg.feeToken, erc20Abi, "mint", [address, target - current]);
    return;
  }
  if (current > target) {
    const id = Object.entries(DEMO_WALLETS).find(
      ([, w]) => w.address.toLowerCase() === address.toLowerCase(),
    )?.[0] as WalletId | undefined;
    if (!id || !hasSigner(id)) return;
    const { account, client } = walletClient(DEMO_WALLETS[id].key!);
    const hash = await client.writeContract({
      address: cfg.feeToken,
      abi: erc20Abi,
      functionName: "transfer",
      args: [POOL_SINK, current - target],
      account,
      chain: client.chain,
    });
    await publicClient().waitForTransactionReceipt({ hash });
  }
}

const ZERO = "0x0000000000000000000000000000000000000000";

/** Demo Wallet A is score-100 exploit, not OFAC. Clear a leftover listing from older deploys. */
async function clearWalletASanction(): Promise<void> {
  const cfg = getChainConfig();
  if (!cfg.sanctionRegistry || cfg.sanctionRegistry === ZERO) return;
  const listed = await publicClient().readContract({
    address: cfg.sanctionRegistry,
    abi: registryAbi,
    functionName: "isSanctioned",
    args: [DEMO_WALLETS.A.address],
  });
  if (!listed) return;
  await writeAsKeeper(cfg.sanctionRegistry, registryAbi, "setSanctioned", [
    DEMO_WALLETS.A.address,
    false,
  ]);
}

export async function seedBalances(): Promise<void> {
  await requireChain();
  await bindOfacDemoWallet();
  resetEthCredits();
  await clearWalletASanction();
  for (const id of WALLET_IDS) {
    await setTokenBalance(DEMO_WALLETS[id].address, DEMO_WALLETS[id].usdc);
  }
  const cfg = getChainConfig();
  const { account, client } = keeperWallet();
  for (const id of WALLET_IDS) {
    const hash = await client.writeContract({
      address: cfg.hook,
      abi: hookAbi,
      functionName: "syncBaseline",
      args: [DEMO_WALLETS[id].address, cfg.feeToken],
      account,
      chain: client.chain,
    });
    await publicClient().waitForTransactionReceipt({ hash });
  }
}

export async function transferUsdc(
  from: WalletId,
  to: WalletId,
  usdc: number,
): Promise<Hex> {
  if (!hasSigner(from) || !hasSigner(to)) {
    throw new Error("Wallet F cannot send or receive P2P — OFAC SDN subject has no demo key");
  }
  await requireChain();
  const cfg = getChainConfig();
  const amount = usdcToWei(usdc);
  const { account, client } = walletClient(DEMO_WALLETS[from].key!);
  const hash = await client.writeContract({
    address: cfg.feeToken,
    abi: erc20Abi,
    functionName: "transfer",
    args: [DEMO_WALLETS[to].address, amount],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function spendToSink(from: WalletId, usdc: number): Promise<Hex> {
  if (!hasSigner(from)) {
    throw new Error("Wallet F cannot spend — OFAC SDN subject has no demo key");
  }
  const cfg = getChainConfig();
  const { account, client } = walletClient(DEMO_WALLETS[from].key!);
  const hash = await client.writeContract({
    address: cfg.feeToken,
    abi: erc20Abi,
    functionName: "transfer",
    args: [POOL_SINK, usdcToWei(usdc)],
    account,
    chain: client.chain,
  });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

export async function observeSwap(
  wallet: Address,
  amountWei: bigint,
): Promise<Hex> {
  const cfg = getChainConfig();
  return writeAsKeeper(cfg.hook, hookAbi, "observeSwap", [
    wallet,
    cfg.feeToken,
    amountWei,
  ]);
}

export async function settleObservedSwap(input: {
  walletId: WalletId;
  usdc: number;
  preview: Pick<PreviewResult, "decision" | "feeBps">;
}): Promise<{
  observeTx: Hex | null;
  spendTx: Hex | null;
  escrowTx: Hex | null;
  escrowId: number | null;
}> {
  const { walletId, usdc, preview } = input;
  const wallet = DEMO_WALLETS[walletId].address;
  const amountWei = usdcToWei(usdc);

  if (preview.decision === "block") {
    return { observeTx: null, spendTx: null, escrowTx: null, escrowId: null };
  }

  const observeTx = await observeSwap(wallet, amountWei);
  const spendTx = await spendToSink(walletId, usdc);

  const extraBps = Math.max(0, preview.feeBps - 30);
  const extraWei = extraBps > 0 ? (amountWei * BigInt(extraBps)) / 10_000n : 0n;
  let escrowTx: Hex | null = null;
  let escrowId: number | null = null;
  if (preview.decision === "fee_override" && extraWei > 0n) {
    const fingerprint = keccak256(toBytes(`${observeTx}:${walletId}:${usdc}`));
    const deposited = await depositFee(wallet, extraWei, fingerprint);
    escrowTx = deposited.tx;
    escrowId = deposited.id;
  }

  const ethOut = usdc / 1000;
  ethCredit[walletId] = Math.round((ethCredit[walletId] + ethOut) * 10_000) / 10_000;

  return { observeTx, spendTx, escrowTx, escrowId };
}

export async function warpSeconds(seconds: number): Promise<number> {
  await requireChain();
  const client = publicClient();
  await anvilRpc("evm_increaseTime", [Math.max(1, Math.round(seconds))]);
  await anvilRpc("evm_mine", []);
  const block = await client.getBlock({ blockTag: "latest" });
  return Number(block.timestamp);
}

export async function setPriceFeedBound(bound: boolean): Promise<boolean> {
  await requireChain();
  const cfg = getChainConfig();
  const feed = bound
    ? cfg.usdFeed
    : ("0x0000000000000000000000000000000000000000" as Address);
  await writeAsKeeper(cfg.hook, hookAbi, "setPriceFeed", [cfg.feeToken, feed]);
  return bound;
}

export async function isPriceFeedBound(): Promise<boolean> {
  const cfg = getChainConfig();
  const feed = await publicClient().readContract({
    address: cfg.hook,
    abi: hookAbi,
    functionName: "priceFeeds",
    args: [cfg.feeToken],
  });
  return feed !== "0x0000000000000000000000000000000000000000";
}

export { previewSwap };
