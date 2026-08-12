// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {AmlHook} from "contracts/hooks/AmlHook.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";

/// @notice Stand-in PoolManager so `AmlHook.onlyPoolManager` can be exercised in hook tests.
contract HookPoolManagerStub {
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

/**
 * @title Helpers
 * @notice Shared fixtures and utilities for the AML stack's unit tests.
 * @dev Deliberately narrower than a general-purpose test-support base: there is no permissions
 *      adapter to mock and nothing here fuzzes arbitrary addresses against a foreign contract, so
 *      this file carries only what the suite actually exercises — deployment fields, the
 *      `AccessManager` wiring helper every restricted-function test needs, and the pool-manager stub
 *      hook tests need. Individual test contracts still run their own `setUp()`; this file does not.
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

    /**
     * @notice Points a set of functions at a role and grants that role to an account
     * @dev Mirrors what the deploy script has to do for every `restricted` function. Without the
     *      target wiring the function stays admin-only, so a test that forgets this step fails
     *      closed rather than silently passing
     * @param _manager The access manager governing the target
     * @param _admin An address holding the manager's admin role
     * @param _target The contract whose functions are being wired
     * @param _selectors The functions to place behind the role
     * @param _role The role id to require
     * @param _account The address to grant the role to
     */
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

    /**
     * @notice Deploys `AmlHook` at an address whose low bits already carry its permission flags
     * @dev `deployCodeTo` sidesteps CREATE2 mining in tests: the flags are computed directly and the
     *      hook's runtime code is placed at that address, which is all `Hooks.validateHookPermissions`
     *      checks in the constructor
     * @param _accessManager The manager the hook's `restricted` setters answer to
     * @param _registry The sanctions registry the hook screens against
     * @param _oracle The behavioral score store the hook reads
     * @param _policy The ternary decision mapping the hook consults
     * @return _hook The deployed hook
     */
    function _deployHook(
        AccessManager _accessManager,
        SanctionRegistry _registry,
        ComplianceOracle _oracle,
        RiskPolicy _policy
    ) internal returns (AmlHook _hook) {
        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo(
            "AmlHook.sol:AmlHook",
            abi.encode(
                IPoolManager(address(manager)),
                address(_accessManager),
                _registry,
                _oracle,
                _policy,
                uint256(300),
                uint64(3600),
                uint32(3)
            ),
            flags
        );
        _hook = AmlHook(flags);
    }

    /**
     * @notice Builds a minimal dynamic-fee `PoolKey` pointed at the given hook
     * @param _hook The hook address the key should carry
     * @return _key The pool key
     */
    function _buildKey(address _hook) internal pure returns (PoolKey memory _key) {
        _key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(_hook)
        });
    }

    /// @notice A one-directional swap of arbitrary size, the shape every test in this suite reuses.
    function _buildParams() internal pure returns (SwapParams memory _params) {
        _params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }
}
