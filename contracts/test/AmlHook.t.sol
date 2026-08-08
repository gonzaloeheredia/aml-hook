// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {AmlHook} from "../src/hooks/AmlHook.sol";
import {BaseHook} from "../src/hooks/BaseHook.sol";
import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {HookDecision} from "../src/libraries/HookDecision.sol";

/// @notice Stand-in PoolManager so AmlHook.onlyPoolManager can be exercised.
contract MockPoolManager {
    function callBeforeSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return hook.beforeSwap(sender, key, params, hookData);
    }

    function callAfterSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return hook.afterSwap(sender, key, params, delta, hookData);
    }
}

contract AmlHookTest is Test {
    using LPFeeLibrary for uint24;

    MockPoolManager manager;
    SanctionRegistry registry;
    ComplianceOracle oracle;
    RiskPolicy policy;
    AmlHook hook;

    address walletA = address(0xA11CE);
    address walletB = address(0xB0B);
    address walletC = address(0xC0FFEE);
    address router = address(0xBEEF);

    PoolKey key;
    SwapParams params;

    event SwapObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        uint24 feeBps,
        uint8 hopDistance,
        address origin
    );

    function setUp() public {
        manager = new MockPoolManager();
        registry = new SanctionRegistry(address(this));
        oracle = new ComplianceOracle(address(this));
        policy = new RiskPolicy();

        // Address low bits must encode beforeSwap | afterSwap (BaseHook constructor checks this).
        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo(
            "AmlHook.sol:AmlHook",
            abi.encode(
                IPoolManager(address(manager)),
                registry,
                oracle,
                policy,
                uint256(300),
                uint64(3600),
                uint32(3)
            ),
            flags
        );
        hook = AmlHook(flags);

        key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function test_PermissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
    }

    function test_CleanSwapAllowThenObserve() public {
        // Keeper must write score (even 0) so unset mitigation does not elevate.
        oracle.updateScore(walletC, 0, 0, address(0), 0, "");
        bytes memory data = abi.encode(walletC);

        (bytes4 sel,, uint24 fee) =
            manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertEq(sel, hook.beforeSwap.selector);
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletC, 0, HookDecision.ALLOW, 0, 0, address(0));

        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }

    function test_UnsetScoreElevatesInBeforeSwap() public {
        bytes memory data = abi.encode(walletC);
        (,, uint24 fee) = manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertTrue(fee.isOverride());
        assertEq(fee.removeOverrideFlag(), 80_000); // LATENCY_FEE_BPS 800 → v4 units
    }

    function test_FeeOverrideReturnsV4FeeWithFlag() public {
        oracle.updateScore(walletB, 65, 1, walletA, 800, "");
        bytes memory data = abi.encode(walletB);

        (,, uint24 fee) = manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertTrue(fee.isOverride());
        assertEq(fee.removeOverrideFlag(), 80_000); // 8% in hundredths of a bip
    }

    function test_TwoHopProportionalFee() public {
        oracle.updateScore(walletC, 42, 2, walletA, 300, "");
        bytes memory data = abi.encode(walletC);

        (,, uint24 fee) = manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertTrue(fee.isOverride());
        assertEq(fee.removeOverrideFlag(), 30_000); // 3%
    }

    function test_RevertBandRevertsInBeforeSwap() public {
        oracle.updateScore(walletA, 100, 0, walletA, 0, "");
        bytes memory data = abi.encode(walletA);

        vm.expectRevert();
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
    }

    function test_SanctionRevertsBeforeScore() public {
        registry.setSanctioned(walletB, true);
        oracle.updateScore(walletB, 0, 0, address(0), 0, "");
        bytes memory data = abi.encode(walletB);

        vm.expectRevert();
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
    }

    function test_EmptyHookDataRevertsNotRouter() public {
        // Without end-user in hookData, must NOT evaluate the router — fail closed.
        vm.expectRevert(AmlHook.MissingSwapSubject.selector);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, "");
    }

    function test_ZeroAddressHookDataReverts() public {
        bytes memory data = abi.encode(address(0));
        vm.expectRevert(AmlHook.MissingSwapSubject.selector);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
    }

    function test_NonPoolManagerCannotCallBeforeSwap() public {
        bytes memory data = abi.encode(walletC);
        vm.prank(router);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(router, key, params, data);
    }

    function test_AfterSwapEmitsCachedDecision() public {
        oracle.updateScore(walletB, 65, 1, walletA, 800, "");
        bytes memory data = abi.encode(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletB, 65, HookDecision.FEE_OVERRIDE, 800, 1, walletA);
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }
}
