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
  "error UnscoredMagnitudeBlocked()",
  "error DailyAggregationBlocked()",
  "error UnscoredPoolImpactBlocked()",
  "error MagnitudeQuoteFailed()",
  "error MissingSwapSubject()",
  "error SanctionHit(address wallet)",
  "error WalletBlocked(address wallet)",
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

function encodeExactIn(amountIn: bigint): Hex {
  return encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          {
            name: "poolKey",
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ],
          },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "minHopPriceX36", type: "uint256" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    [
      {
        poolKey: POOL_KEY,
        zeroForOne: false,
        amountIn,
        amountOutMinimum: BigInt(0),
        minHopPriceX36: BigInt(0),
        hookData: "0x",
      },
    ],
  );
}

function encodeV4Swap(amountIn: bigint): Hex {
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
    [actions, [encodeExactIn(amountIn), settle, take]],
  );
}

function decodeHookRevert(err: unknown): string {
  const raw =
    err && typeof err === "object" && "shortMessage" in err
      ? String((err as { shortMessage: unknown }).shortMessage)
      : err instanceof Error
        ? err.message
        : String(err ?? "Swap failed");
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
  try {
    const hash = await wallet.writeContract({
      address: SEPOLIA_UNIVERSAL_ROUTER,
      abi: UR_ABI,
      functionName: "execute",
      args: [V4_SWAP, [encodeV4Swap(amountIn)], deadline],
      account,
      chain: wallet.chain,
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
