// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {AmlHook} from "contracts/hooks/AmlHook.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {Roles} from "libraries/Roles.sol";
import {MockTrustedRouter} from "../../script/mocks/MockTrustedRouter.sol";

/// @notice Stand-in PoolManager so `AmlHook.onlyPoolManager` can be exercised in hook tests.
/// @dev `take` forwards ERC-20 from this stub to `to` (mint tokens here before FEE_OVERRIDE afterSwap tests).
contract HookPoolManagerStub {
    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "stub: take transfer failed");
    }

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

    function callBeforeAddLiquidity(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return hook.beforeAddLiquidity(sender, key, params, hookData);
    }

    function callBeforeRemoveLiquidity(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return hook.beforeRemoveLiquidity(sender, key, params, hookData);
    }
}

/**
 * @title Helpers
 * @notice Shared fixtures and utilities for the AML stack's unit tests.
 */
contract Helpers is Test {
    using LPFeeLibrary for uint24;

    /// Contracts
    HookPoolManagerStub public manager;
    AccessManager public accessManager;
    SanctionRegistry public sanctionRegistry;
    ComplianceOracle public complianceOracle;
    RiskPolicy public riskPolicy;
    AmlHook public hook;

    /// EOAs
    address public owner = makeAddr("owner");
    address public stranger = makeAddr("stranger");
    address public keeper = makeAddr("keeper");
    address public router = makeAddr("router");
    address public registryKeeper = makeAddr("registryKeeper");
    address public oracleKeeper = makeAddr("oracleKeeper");
    address public hookGovernor = makeAddr("hookGovernor");
    address public walletA = address(0xA11CE);
    address public walletB = address(0xB0B);
    address public walletC = address(0xC0FFEE);

    /// @dev Trusted IMsgSender stand-in used by hook lifecycle tests (hookData is ignored).
    MockTrustedRouter public trustedRouter;

    function _wireRole(
        AccessManager _manager,
        address _admin,
        address _target,
        bytes4[] memory _selectors,
        uint64 _role,
        address _account
    ) internal {
        vm.startPrank(_admin);
        _manager.setTargetFunctionRole(_target, _selectors, _role);
        _manager.grantRole(_role, _account, 0);
        vm.stopPrank();
    }

    /// @dev Wires `_HOOK_GOVERNOR` so tests can `setTrustedRouter`.
    function _wireHookGovernor() internal {
        bytes4[] memory hookSelectors = new bytes4[](5);
        hookSelectors[0] = AmlHookLogic.setStalenessThreshold.selector;
        hookSelectors[1] = AmlHookLogic.setInflowThresholdBps.selector;
        hookSelectors[2] = AmlHookLogic.setTrustedRouter.selector;
        hookSelectors[3] = AmlHookLogic.pause.selector;
        hookSelectors[4] = AmlHookLogic.unpause.selector;
        _wireRole(accessManager, owner, address(hook), hookSelectors, Roles._HOOK_GOVERNOR, hookGovernor);
    }

    /// @dev Helper to list an account. Uses commit-reveal (production path). Tests that
    ///      specifically cover the emergency `setSanctioned(..., true)` path call it directly.
    function _sanction(SanctionRegistry _registry, address _caller, address _account) internal {
        bytes32 salt = keccak256(abi.encode(_account, block.number, address(_registry)));
        bytes32 commitHash = keccak256(abi.encode(_account, true, salt));

        vm.prank(_caller);
        _registry.commitSanction(commitHash);

        vm.roll(block.number + _registry.REVEAL_DELAY() + 1);

        vm.prank(_caller);
        _registry.revealSanction(_account, true, salt);
    }

    /// @dev Register a MockTrustedRouter (once) and set the end-user it reports via `msgSender()`.
    function _bindTrustedSubject(address subject) internal returns (address sender) {
        if (address(trustedRouter) == address(0)) {
            trustedRouter = new MockTrustedRouter();
            vm.prank(hookGovernor);
            hook.setTrustedRouter(address(trustedRouter), true);
        }
        trustedRouter.setMsgSender(subject);
        return address(trustedRouter);
    }

    /**
     * @notice Deploys `AmlHook` at an address whose low bits already carry its permission flags.
     * @param _feeEscrow FeeEscrow for afterSwap deposits, or address(0) to disable escrow path.
     */
    function _deployHook(
        AccessManager _accessManager,
        SanctionRegistry _registry,
        ComplianceOracle _oracle,
        RiskPolicy _policy,
        IFeeEscrow _feeEscrow
    ) internal returns (AmlHook _hook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );
        deployCodeTo(
            "AmlHook.sol:AmlHook",
            abi.encode(
                IPoolManager(address(manager)),
                address(_accessManager),
                _registry,
                _oracle,
                _policy,
                _feeEscrow,
                uint256(300),
                uint64(3600),
                uint32(3)
            ),
            flags
        );
        _hook = AmlHook(flags);
    }

    /// @dev Convenience: deploy hook with FeeEscrow disabled.
    function _deployHook(
        AccessManager _accessManager,
        SanctionRegistry _registry,
        ComplianceOracle _oracle,
        RiskPolicy _policy
    ) internal returns (AmlHook _hook) {
        return _deployHook(_accessManager, _registry, _oracle, _policy, IFeeEscrow(address(0)));
    }

    function _buildKey(address _hook) internal pure returns (PoolKey memory _key) {
        _key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(_hook)
        });
    }

    function _buildParams() internal pure returns (SwapParams memory _params) {
        _params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    /// @dev `liquidityDelta` sign only matters to v4-core's own dispatch (add vs remove); the hook
    ///      callbacks under test are called directly, so either sign exercises the same gate.
    function _buildLiquidityParams(int256 _liquidityDelta)
        internal
        pure
        returns (ModifyLiquidityParams memory _params)
    {
        _params = ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: _liquidityDelta,
            salt: bytes32(0)
        });
    }
}
