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
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IMintable is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256);
}

/// @notice Adds more MockWETH/MockUSDC liquidity to the already-initialized Sepolia pool.
/// @dev The first add was 0.1 WETH + 100 USDC — too thin for $500 / $1,000 Wallet E fills.
///      LIQ_ROUTER already has a published 0–30 score (docs/Sepolia.md).
///
///      Usage (from `contracts/`, `.env` loaded by Foundry):
///        forge script script/AddLiquidity.s.sol:AddLiquidity --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
contract AddLiquidity is Script {
    using StateLibrary for IPoolManager;

    address public constant HOOK = 0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7;
    address public constant MOCK_WETH = 0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a;
    address public constant MOCK_USDC = 0xa95c6057B2Bf93476590D93539dC5beB53549684;

    IPoolManager public constant POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPoolModifyLiquidityTest public constant LIQ_ROUTER =
        IPoolModifyLiquidityTest(0x0C478023803a644c94c4CE1C1e7b9A087e411B0A);

    uint24 public constant FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 public constant TICK_SPACING = 60;

    uint256 public constant MINT_WETH = 50 ether;
    uint256 public constant MINT_USDC = 50_000 * 1e6;
    uint256 public constant DEPOSIT_WETH = 40 ether;
    uint256 public constant DEPOSIT_USDC = 40_000 * 1e6;

    function run() external {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(MOCK_WETH),
            currency1: Currency.wrap(MOCK_USDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        require(sqrtPriceX96 != 0, "pool not initialized");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        IMintable(MOCK_WETH).mint(msg.sender, MINT_WETH);
        IMintable(MOCK_USDC).mint(msg.sender, MINT_USDC);
        IERC20(MOCK_WETH).approve(address(LIQ_ROUTER), type(uint256).max);
        IERC20(MOCK_USDC).approve(address(LIQ_ROUTER), type(uint256).max);

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
                salt: bytes32(uint256(1))
            }),
            ""
        );
        console2.log("liquidity added");

        vm.stopBroadcast();
    }
}
