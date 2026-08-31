/**
 * Wallet E exact-in MockUSDC → MockWETH on the live Sepolia v4 pool.
 * Path: user → Permit2 → Universal Router (trusted) → PoolManager → AmlHook.
 */

import {
  encodeAbiParameters,
  encodePacked,
  erc20Abi,
  formatUnits,
  parseAbi,
  parseUnits,
  type Address,
  type Hex,
} from "viem";
import {
  PERMIT2,
  SEPOLIA_HOOK,
  SEPOLIA_MOCK_USDC,
  SEPOLIA_MOCK_WETH,
  SEPOLIA_POOL_FEE,
  SEPOLIA_TICK_SPACING,
  SEPOLIA_UNIVERSAL_ROUTER,
  USDC_DECIMALS,
} from "@/lib/sepoliaPool";
import {
  assertSepoliaChain,
  sepoliaPublicClient,
  sepoliaWalletClient,
} from "@/lib/sepoliaWallet";

const V4_SWAP = "0x10";
const SWAP_EXACT_IN_SINGLE = "0x06";
const SETTLE_ALL = "0x0c";
const TAKE_ALL = "0x0f";

const UR_ABI = parseAbi([
  "function execute(bytes commands, bytes[] inputs, uint256 deadline)",
]);

const PERMIT2_ABI = parseAbi([
  "function approve(address token, address spender, uint160 amount, uint48 expiration)",
  "function allowance(address user, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
]);

const HOOK_ERRORS = parseAbi([
  "error UnscoredMagnitudeBlocked(address wallet, uint256 assessedUsd, uint256 threshold)",
  "error DailyAggregationBlocked(address wallet, uint256 assessedUsd, uint256 threshold)",
  "error UnscoredPoolImpactBlocked(address wallet, uint256 poolImpactBps, uint256 threshold)",
  "error MagnitudeQuoteFailed(address token, bytes32 reason)",
  "error MissingSwapSubject()",
  "error SanctionHit(address wallet)",
  "error WalletBlocked(address wallet, uint8 score, string reason)",
]);

const POOL_KEY = {
  currency0: SEPOLIA_MOCK_WETH,
  currency1: SEPOLIA_MOCK_USDC,
  fee: SEPOLIA_POOL_FEE,
  tickSpacing: SEPOLIA_TICK_SPACING,
  hooks: SEPOLIA_HOOK,
} as const;

const MAX_UINT160 = (BigInt(1) << BigInt(160)) - BigInt(1);
const MAX_UINT256 = (BigInt(1) << BigInt(256)) - BigInt(1);
const PERMIT_TTL_SEC = 30 * 24 * 60 * 60;
/** Infura Sepolia rejects eth_sendRawTransaction above 2^24 (16_777_216). */
const GAS_CAP = BigInt(8_000_000);
const APPROVE_GAS = BigInt(80_000);

const POOL_KEY_COMPONENTS = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

/** Official app.uniswap.org UR on Sepolia predates minHopPriceX36. */
function encodeExactIn(amountIn: bigint, withMinHop: boolean): Hex {
  const components = [
    { name: "poolKey", type: "tuple", components: [...POOL_KEY_COMPONENTS] },
    { name: "zeroForOne", type: "bool" },
    { name: "amountIn", type: "uint128" },
    { name: "amountOutMinimum", type: "uint128" },
    ...(withMinHop ? [{ name: "minHopPriceX36", type: "uint256" }] : []),
    { name: "hookData", type: "bytes" },
  ];
  const value: Record<string, unknown> = {
    poolKey: POOL_KEY,
    zeroForOne: false,
    amountIn,
    amountOutMinimum: BigInt(0),
    hookData: "0x",
  };
  if (withMinHop) value.minHopPriceX36 = BigInt(0);
  return encodeAbiParameters([{ type: "tuple", components }], [value]);
}

function encodeV4Swap(amountIn: bigint, withMinHop: boolean): Hex {
  const actions = encodePacked(
    ["bytes1", "bytes1", "bytes1"],
    [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL],
  );
  const settle = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    [SEPOLIA_MOCK_USDC, MAX_UINT256],
  );
  const take = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    [SEPOLIA_MOCK_WETH, BigInt(0)],
  );
  return encodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes[]" }],
    [actions, [encodeExactIn(amountIn, withMinHop), settle, take]],
  );
}

function flattenRevert(err: unknown): string {
  const parts: string[] = [];
  const seen = new Set<unknown>();
  const visit = (value: unknown) => {
    if (!value || seen.has(value)) return;
    seen.add(value);
    if (typeof value === "string") {
      parts.push(value);
      return;
    }
    if (typeof value !== "object") return;
    const o = value as Record<string, unknown>;
    if (typeof o.errorName === "string") parts.push(o.errorName);
    if (typeof o.shortMessage === "string") parts.push(o.shortMessage);
    if (typeof o.message === "string") parts.push(o.message);
    if (typeof o.details === "string") parts.push(o.details);
    if (Array.isArray(o.metaMessages)) {
      for (const m of o.metaMessages) visit(m);
    }
    if (o.data !== undefined) visit(o.data);
    if (o.cause) visit(o.cause);
  };
  visit(err);
  return parts.join(" | ");
}

function decodeHookRevert(err: unknown): string {
  const raw = flattenRevert(err);
  const data =
    err && typeof err === "object" && "data" in err
      ? String((err as { data: unknown }).data)
      : raw;
  for (const name of [
    "UnscoredMagnitudeBlocked",
    "DailyAggregationBlocked",
    "UnscoredPoolImpactBlocked",
    "MagnitudeQuoteFailed",
    "MissingSwapSubject",
    "SanctionHit",
    "WalletBlocked",
  ] as const) {
    if (data.includes(name) || raw.includes(name)) {
      if (name === "MagnitudeQuoteFailed") {
        return "Hook reverted: MagnitudeQuoteFailed. Bind demo FX (1 MockETH = 1,000 MockUSD) with BindDemoFx.s.sol.";
      }
      return `Hook reverted: ${name}`;
    }
  }
  void HOOK_ERRORS;
  if (/insufficient|liquidity|TooLittle/i.test(raw)) {
    return "Pool liquidity is too thin for this size. Add liquidity or swap a smaller amount.";
  }
  if (/user rejected|denied|rejected/i.test(raw)) {
    return "Wallet rejected the transaction.";
  }
  if (/gas limit too high|16777216|20999980/i.test(raw)) {
    return "Sepolia RPC rejected the gas limit. Retry the swap — the app now caps gas under Infura’s 16.7M ceiling.";
  }
  return raw;
}

async function ensurePermit2Allowance(
  account: Address,
  amountIn: bigint,
): Promise<void> {
  const publicClient = sepoliaPublicClient();
  const wallet = sepoliaWalletClient(account);

  const erc20Allowance = await publicClient.readContract({
    address: SEPOLIA_MOCK_USDC,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account, PERMIT2],
  });
  if (erc20Allowance < amountIn) {
    const hash = await wallet.writeContract({
      address: SEPOLIA_MOCK_USDC,
      abi: erc20Abi,
      functionName: "approve",
      args: [PERMIT2, MAX_UINT256],
      account,
      chain: wallet.chain,
      gas: APPROVE_GAS,
    });
    await publicClient.waitForTransactionReceipt({ hash });
  }

  const now = Math.floor(Date.now() / 1000);
  const permit = await publicClient.readContract({
    address: PERMIT2,
    abi: PERMIT2_ABI,
    functionName: "allowance",
    args: [account, SEPOLIA_MOCK_USDC, SEPOLIA_UNIVERSAL_ROUTER],
  });
  if (permit[0] < amountIn || Number(permit[1]) <= now + 60) {
    const hash = await wallet.writeContract({
      address: PERMIT2,
      abi: PERMIT2_ABI,
      functionName: "approve",
      args: [
        SEPOLIA_MOCK_USDC,
        SEPOLIA_UNIVERSAL_ROUTER,
        MAX_UINT160,
        now + PERMIT_TTL_SEC,
      ],
      account,
      chain: wallet.chain,
      gas: APPROVE_GAS,
    });
    await publicClient.waitForTransactionReceipt({ hash });
  }
}

export async function swapUsdcForWeth(account: Address, usdc: number): Promise<Hex> {
  if (!Number.isFinite(usdc) || usdc <= 0) {
    throw new Error("Enter a USDC amount greater than 0.");
  }
  const publicClient = sepoliaPublicClient();
  const chainId = await publicClient.getChainId();
  assertSepoliaChain(chainId);

  const amountIn = parseUnits(String(Math.floor(usdc)), USDC_DECIMALS);
  const [usdcBal, native] = await Promise.all([
    publicClient.readContract({
      address: SEPOLIA_MOCK_USDC,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    }),
    publicClient.getBalance({ address: account }),
  ]);
  if (usdcBal < amountIn) {
    throw new Error(
      `Not enough MockUSDC (${formatUnits(usdcBal, USDC_DECIMALS)}). Mint from the faucet first.`,
    );
  }
  if (native === BigInt(0)) {
    throw new Error("This wallet needs Sepolia ETH for gas. The faucet only mints MockUSDC / MockWETH.");
  }

  await ensurePermit2Allowance(account, amountIn);

  const wallet = sepoliaWalletClient(account);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 180);
  const encodings = [false, true] as const;
  let args: readonly [Hex, Hex[], bigint] | null = null;
  let lastSimErr: unknown;
  for (const withMinHop of encodings) {
    const candidate = [V4_SWAP, [encodeV4Swap(amountIn, withMinHop)], deadline] as const;
    try {
      await publicClient.simulateContract({
        address: SEPOLIA_UNIVERSAL_ROUTER,
        abi: UR_ABI,
        functionName: "execute",
        args: candidate,
        account,
        gas: GAS_CAP,
      });
      args = candidate;
      break;
    } catch (err) {
      lastSimErr = err;
    }
  }
  if (!args) {
    throw new Error(decodeHookRevert(lastSimErr));
  }

  let gas = GAS_CAP;
  try {
    const estimated = await publicClient.estimateContractGas({
      address: SEPOLIA_UNIVERSAL_ROUTER,
      abi: UR_ABI,
      functionName: "execute",
      args,
      account,
    });
    const padded = estimated + estimated / BigInt(5);
    gas = padded < GAS_CAP ? padded : GAS_CAP;
  } catch {
    gas = GAS_CAP;
  }

  try {
    const hash = await wallet.writeContract({
      address: SEPOLIA_UNIVERSAL_ROUTER,
      abi: UR_ABI,
      functionName: "execute",
      args,
      account,
      chain: wallet.chain,
      gas,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") {
      throw new Error("Swap transaction reverted.");
    }
    return hash;
  } catch (err) {
    throw new Error(decodeHookRevert(err));
  }
}
