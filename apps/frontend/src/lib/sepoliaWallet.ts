/**
 * MetaMask (or any injected EIP-1193 wallet) on Ethereum Sepolia, used only by Wallet E.
 */

import {
  createPublicClient,
  createWalletClient,
  custom,
  formatEther,
  formatUnits,
  getAddress,
  type Address,
  type WalletClient,
} from "viem";
import { sepolia } from "viem/chains";
import {
  SEPOLIA_CHAIN_HEX,
  SEPOLIA_CHAIN_ID,
  SEPOLIA_MOCK_USDC,
  SEPOLIA_MOCK_WETH,
  USDC_DECIMALS,
} from "@/lib/sepoliaPool";

const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export type SepoliaBalances = {
  address: Address;
  usdc: number;
  weth: number;
  nativeEth: number;
};

export function injectedProvider(): EthereumProvider | undefined {
  return window.ethereum;
}

function requireInjected(): EthereumProvider {
  const ethereum = injectedProvider();
  if (!ethereum) {
    throw new Error("Install MetaMask (or another injected wallet) to swap Wallet E on Sepolia.");
  }
  return ethereum;
}

async function ensureSepolia(ethereum: EthereumProvider): Promise<void> {
  const chainId = await ethereum.request({ method: "eth_chainId" });
  if (String(chainId).toLowerCase() === SEPOLIA_CHAIN_HEX) return;
  try {
    await ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: SEPOLIA_CHAIN_HEX }],
    });
  } catch (err) {
    const code = (err as { code?: number }).code;
    if (code !== 4902) throw err;
    await ethereum.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: SEPOLIA_CHAIN_HEX,
          chainName: "Sepolia",
          nativeCurrency: { name: "Sepolia ETH", symbol: "ETH", decimals: 18 },
          rpcUrls: ["https://rpc.sepolia.org"],
          blockExplorerUrls: ["https://sepolia.etherscan.io"],
        },
      ],
    });
  }
}

export async function connectSepoliaAccount(): Promise<Address> {
  const ethereum = requireInjected();
  const accounts = (await ethereum.request({
    method: "eth_requestAccounts",
  })) as string[];
  const raw = accounts[0];
  if (!raw) throw new Error("No account selected in the wallet.");
  await ensureSepolia(ethereum);
  return getAddress(raw);
}

export async function silentSepoliaAccount(): Promise<Address | null> {
  const ethereum = injectedProvider();
  if (!ethereum) return null;
  const accounts = (await ethereum.request({ method: "eth_accounts" })) as string[];
  if (!accounts[0]) return null;
  return getAddress(accounts[0]);
}

export function sepoliaWalletClient(account: Address): WalletClient {
  return createWalletClient({
    account,
    chain: sepolia,
    transport: custom(requireInjected()),
  });
}

export function sepoliaPublicClient() {
  return createPublicClient({
    chain: sepolia,
    transport: custom(requireInjected()),
  });
}

export async function readSepoliaBalances(address: Address): Promise<SepoliaBalances> {
  const client = sepoliaPublicClient();
  const [usdc, weth, native] = await Promise.all([
    client.readContract({
      address: SEPOLIA_MOCK_USDC,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [address],
    }),
    client.readContract({
      address: SEPOLIA_MOCK_WETH,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [address],
    }),
    client.getBalance({ address }),
  ]);
  return {
    address,
    usdc: Number(formatUnits(usdc, USDC_DECIMALS)),
    weth: Number(formatEther(weth)),
    nativeEth: Number(formatEther(native)),
  };
}

export function assertSepoliaChain(chainId: number): void {
  if (chainId !== SEPOLIA_CHAIN_ID) {
    throw new Error("Switch the wallet to Ethereum Sepolia (11155111).");
  }
}
