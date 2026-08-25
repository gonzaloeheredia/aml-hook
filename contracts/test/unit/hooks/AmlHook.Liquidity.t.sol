// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {Roles} from "libraries/Roles.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice AmlHook liquidity gate: sanctions + pause block new LP positions (`_beforeAddLiquidity`).
///         LP exit (`_beforeRemoveLiquidity`) is sanctions-only: a listed wallet cannot extract
///         capital; pause does not freeze a clean LP. The LP subject is `sender` (no trusted router).
contract UnitAmlHookLiquidityTest is Helpers {
    PoolKey key;
    ModifyLiquidityParams addParams;
    ModifyLiquidityParams removeParams;

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory registrySelectors = new bytes4[](3);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        registrySelectors[1] = SanctionRegistry.commitSanction.selector;
        registrySelectors[2] = SanctionRegistry.revealSanction.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), registrySelectors, Roles._REGISTRY_KEEPER, keeper);

        _wireHookGovernor();

        key = _buildKey(address(hook));
        addParams = _buildLiquidityParams(int256(1e18));
        removeParams = _buildLiquidityParams(-int256(1e18));
    }

    /*///////////////////////////////////////////////////////////////
                        BEFORE ADD LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_CleanWalletCanAddLiquidity() external {
        bytes4 sel =
            manager.callBeforeAddLiquidity(IHooks(address(hook)), walletC, key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);
    }

    function test_SanctionedWalletCannotAddLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletA);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletA));
        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletA, key, addParams, "");
    }

    /// @dev M-1: liquidity `sender` is the LP. A direct caller does not need a trusted router.
    function test_DirectSenderCanAddLiquidityWithoutTrustedRouter() external {
        bytes4 sel =
            manager.callBeforeAddLiquidity(IHooks(address(hook)), router, key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);
    }

    /*///////////////////////////////////////////////////////////////
                       BEFORE REMOVE LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_CleanWalletCanRemoveLiquidity() external {
        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletC, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    /// @dev A listed wallet cannot extract LP capital (`SanctionHit`). Same Layer 1 as add.
    function test_SanctionedWalletCannotRemoveLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletB);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletB, key, removeParams, "");
    }

    function test_DirectSenderCanRemoveLiquidityWithoutTrustedRouter() external {
        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), router, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    /// @dev Score is swap-only. Wallet A (100, not OFAC-listed) can still extract LP.
    function test_HighScoreWalletCanRemoveLiquidity() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, _scoreSig(walletA, 100, 0, walletA, 0));

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletA, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    /// @dev Delist is the unlock. Positions are not burned while the hit stands.
    function test_DelistedWalletCanRemoveLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletB);

        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletB, false);

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletB, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    /*///////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @dev Pause stops new exposure: swaps and new LP deposits.
    function test_PausedHookBlocksAddLiquidity() external {
        vm.prank(hookGovernor);
        hook.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletC, key, addParams, "");
    }

    /// @dev H-1: a pause must never trap capital LPs already committed.
    function test_PausedHookStillAllowsCleanRemoveLiquidity() external {
        vm.prank(hookGovernor);
        hook.pause();

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletC, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    /// @dev Pause does not lift an OFAC/list hit. Remove still reverts `SanctionHit`.
    function test_PausedHookStillBlocksSanctionedRemoveLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletB);

        vm.prank(hookGovernor);
        hook.pause();

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletB, key, removeParams, "");
    }

    /// @dev pause() still stops the swap path.
    function test_PausedHookStillBlocksSwaps() external {
        address sender = _bindTrustedSubject(walletC);

        vm.prank(hookGovernor);
        hook.pause();

        vm.expectRevert();
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, _buildParams(), "");
    }
}
