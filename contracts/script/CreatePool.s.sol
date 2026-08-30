// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IImmutableState} from "v4-periphery/src/interfaces/IImmutableState.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IAggregatorV3} from "../src/interfaces/external/IAggregatorV3.sol";
import {ChainlinkFeeds} from "../src/libraries/ChainlinkFeeds.sol";

interface IMintable is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256);
}

/// @notice Initializes the Sepolia v4 pool for the already-deployed AmlHook + MockWETH/MockUSDC,
///         then mints both tokens to the LP wallet, approves, and deposits initial liquidity.
/// @dev Addresses come from `deployments/11155111.json` (last successful broadcast).
///      Fee / tick spacing match the in-repo PoolKey (`DYNAMIC_FEE_FLAG`, 60).
///
///      The hook's immutable `poolManager` must be the official Sepolia PoolManager
///      (`0xE03A1074…3543`). If it is not, add-liquidity is skipped.
///
///      `LIQ_ROUTER` (PoolModifyLiquidityTest) is not a trusted router, so the
///      hook scores that address as the LP. A never-scored first mint on an
///      empty pool is 100% impact → 8% take while the manager holds 0 of the
///      new token → revert. Publish a 0–30 oracle row for `LIQ_ROUTER` first
///      (`docs/Sepolia.md`).
///
///      Usage (from `contracts/`, `.env` loaded by Foundry):
///        forge script script/CreatePool.s.sol:CreatePool --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
contract CreatePool is Script {
    using StateLibrary for IPoolManager;

    /// @dev Last successful Sepolia broadcast (`contracts/deployments/11155111.json`).
    address public constant HOOK = 0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7;
    address public constant MOCK_WETH = 0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a;
    address public constant MOCK_USDC = 0xa95c6057B2Bf93476590D93539dC5beB53549684;
    address public constant LP = 0x01C67DDF409e70A03342854d9F22278A2aaf87d4;

    /// @dev Official Uniswap v4 on Ethereum Sepolia.
    IPoolManager public constant POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPoolModifyLiquidityTest public constant LIQ_ROUTER =
        IPoolModifyLiquidityTest(0x0C478023803a644c94c4CE1C1e7b9A087e411B0A);

    uint24 public constant FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 public constant TICK_SPACING = 60;

    /// @notice Minted to `LP` (MockWETH 18 dec, MockUSDC 6 dec).
    uint256 public constant MINT_WETH = 10 ether;
    uint256 public constant MINT_USDC = 10_000 * 1e6;

    /// @notice First-add size. Kept under $1,000 USD so a never-scored LP does not
    ///         hit Floor A revert / 20% pool-impact revert on an empty pool.
    uint256 public constant DEPOSIT_WETH = 0.1 ether;
    uint256 public constant DEPOSIT_USDC = 100 * 1e6;

    error CreatePool_TokenOrder();
    error CreatePool_HookBoundToWrongManager(address hookManager, address expected);
    error CreatePool_BadEthUsd(int256 answer);

    function run() external {
        PoolKey memory key = _poolKey();
        uint160 sqrtPriceX96 = _sqrtPriceFromEthUsd();

        console2.log("currency0 (WETH)", Currency.unwrap(key.currency0));
        console2.log("currency1 (USDC)", Currency.unwrap(key.currency1));
        console2.log("hook", address(key.hooks));
        console2.log("fee", key.fee);
        console2.log("tickSpacing", uint256(int256(key.tickSpacing)));
        console2.log("sqrtPriceX96", uint256(sqrtPriceX96));
        console2.log("poolManager", address(POOL_MANAGER));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        (uint160 existing,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (existing == 0) {
            int24 tick = POOL_MANAGER.initialize(key, sqrtPriceX96);
            console2.log("initialized tick", uint256(int256(tick)));
        } else {
            sqrtPriceX96 = existing;
            console2.log("pool already initialized");
        }

        IMintable(MOCK_WETH).mint(LP, MINT_WETH);
        IMintable(MOCK_USDC).mint(LP, MINT_USDC);
        console2.log("minted WETH", MINT_WETH);
        console2.log("minted USDC", MINT_USDC);

        address hookManager = address(IImmutableState(HOOK).poolManager());
        if (hookManager != address(POOL_MANAGER)) {
            console2.log("skip liquidity: hook.poolManager is", hookManager);
            console2.log("official PoolManager is", address(POOL_MANAGER));
        } else {
            IERC20(MOCK_WETH).approve(address(LIQ_ROUTER), type(uint256).max);
            IERC20(MOCK_USDC).approve(address(LIQ_ROUTER), type(uint256).max);
            _addLiquidity(key, sqrtPriceX96);
            console2.log("liquidity added");
        }

        vm.stopBroadcast();

        _writePoolJson(key, sqrtPriceX96);
    }

    function _poolKey() internal pure returns (PoolKey memory key) {
        if (MOCK_WETH >= MOCK_USDC) revert CreatePool_TokenOrder();
        key = PoolKey({
            currency0: Currency.wrap(MOCK_WETH),
            currency1: Currency.wrap(MOCK_USDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _addLiquidity(PoolKey memory key, uint160 sqrtPriceX96) internal {
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            DEPOSIT_WETH,
            DEPOSIT_USDC
        );
        console2.log("liquidityDelta", uint256(liquidity));
        LIQ_ROUTER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev 1 MockWETH ≈ live Sepolia ETH/USD, quoted in MockUSDC (6 dec).
    function _sqrtPriceFromEthUsd() internal view returns (uint160) {
        address feed = ChainlinkFeeds.ethUsd(block.chainid);
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert CreatePool_BadEthUsd(answer);
        // price1/0 = answer / 1e20   (ETH/USD-8 × USDC-6 / WETH-18)
        // sqrtPriceX96 = sqrt(answer) * 2^96 / 1e10
        uint256 root = _sqrt(uint256(answer));
        return uint160((root << 96) / 1e10);
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    function _writePoolJson(PoolKey memory key, uint160 sqrtPriceX96) internal {
        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "poolManager": "',
            vm.toString(address(POOL_MANAGER)),
            '",\n',
            '  "hooks": "',
            vm.toString(address(key.hooks)),
            '",\n',
            '  "currency0": "',
            vm.toString(Currency.unwrap(key.currency0)),
            '",\n',
            '  "currency1": "',
            vm.toString(Currency.unwrap(key.currency1)),
            '",\n',
            '  "fee": ',
            vm.toString(key.fee),
            ",\n",
            '  "tickSpacing": ',
            vm.toString(uint256(int256(key.tickSpacing))),
            ",\n",
            '  "sqrtPriceX96": "',
            vm.toString(uint256(sqrtPriceX96)),
            '",\n',
            '  "lp": "',
            vm.toString(LP),
            '"\n',
            "}\n"
        );
        vm.writeFile("deployments/11155111-pool.json", json);
        console2.log("Wrote deployments/11155111-pool.json");
    }
}
