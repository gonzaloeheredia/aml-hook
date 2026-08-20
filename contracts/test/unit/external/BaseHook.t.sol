// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";
import {BareBaseHook} from "test/mocks/BareBaseHook.sol";

/// @notice Unit coverage for official `v4-periphery/src/utils/BaseHook.sol`.
contract UnitBaseHookTest is Helpers {
    BareBaseHook bare;
    PoolKey key;
    SwapParams swapParams;
    ModifyLiquidityParams liqParams;

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager));
        riskPolicy = new RiskPolicy();

        // Concrete AmlHook: PoolManager gating + unimplemented lifecycle stubs
        // (liquidity callbacks ARE implemented: add screens sender, remove always succeeds).
        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);

        // Bare hook: default `_beforeSwap` / `_afterSwap` → HookNotImplemented.
        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("BareBaseHook.sol:BareBaseHook", abi.encode(IPoolManager(address(manager))), flags);
        bare = BareBaseHook(flags);

        key = _buildKey(address(hook));
        swapParams = _buildParams();
        liqParams = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 0, salt: bytes32(0)});
    }

    function test_PoolManagerIsImmutable_OnAmlHook() external view {
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_NonPoolManagerCannotCallAfterSwap() external {
        bytes memory data = abi.encode(walletC);
        vm.prank(router);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(router, key, swapParams, BalanceDelta.wrap(0), data);
    }

    function test_AmlHook_UnimplementedLifecycleCallbacks_Revert() external {
        vm.startPrank(address(manager));

        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeInitialize(router, key, 0);

        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterInitialize(router, key, 0, 0);

        // Liquidity callbacks are implemented: add screens `sender`; remove always succeeds.
        hook.beforeAddLiquidity(router, key, liqParams, "");
        hook.beforeRemoveLiquidity(router, key, liqParams, "");

        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(router, key, liqParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(router, key, liqParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeDonate(router, key, 0, 0, "");

        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterDonate(router, key, 0, 0, "");

        vm.stopPrank();
    }

    function test_NonPoolManagerCannotCallUnimplementedCallbacks() external {
        vm.prank(stranger);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(router, key, 0);
    }

    function test_BareHook_DefaultBeforeSwap_RevertsHookNotImplemented() external {
        PoolKey memory bareKey = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(bare))
        });
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        bare.beforeSwap(router, bareKey, swapParams, "");
    }

    function test_BareHook_DefaultAfterSwap_RevertsHookNotImplemented() external {
        PoolKey memory bareKey = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(bare))
        });
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        bare.afterSwap(router, bareKey, swapParams, BalanceDelta.wrap(0), "");
    }

    function test_BareHook_NonPoolManagerReverts() external {
        PoolKey memory bareKey = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(bare))
        });
        vm.prank(stranger);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        bare.beforeSwap(router, bareKey, swapParams, "");
    }
}
