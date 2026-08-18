// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {SanctionRegistry} from "../src/contracts/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "../src/contracts/policies/RiskPolicy.sol";
import {FeeEscrow} from "../src/contracts/escrow/FeeEscrow.sol";
import {AmlHook} from "../src/contracts/hooks/AmlHook.sol";
import {AmlHookLogic} from "../src/contracts/hooks/AmlHookLogic.sol";
import {IFeeEscrow} from "../src/interfaces/escrow/IFeeEscrow.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {UniversalRouters} from "../src/libraries/UniversalRouters.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockTrustedRouter} from "./mocks/MockTrustedRouter.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";

/// @notice Deploys the REAL on-chain AML stack (manager, registry, oracle, policy, hook) and wires
///         its access manager.
/// @dev Once authorization moved to a shared `AccessManager`, no contract states who may call it, so
///      the wiring here is the only place that decides. That makes a silent misconfiguration the main
///      risk of this script, and `_verify` exists to make it loud: it re-reads every rule from the
///      manager after applying it and reverts on the first mismatch.
///
///      A `restricted` function nobody wires defaults to admin-only, so an omission fails closed
///      rather than open. The dangerous direction is the opposite one, granting a role to the wrong
///      key, which is what the role assertions catch.
///
///      What is real vs mock in this script:
///      - REAL: AccessManager, SanctionRegistry, ComplianceOracle, RiskPolicy, FeeEscrow, AmlHook (CREATE2).
///      - MOCK: PoolManager defaults to MockPoolManager (no live Uniswap swaps).
///      - MOCK: MockTrustedRouter only when the chain has no canonical Universal Router
///        (Anvil). On Uniswap-supported chains, Deploy registers the app.uniswap.org
///        Universal Router (+ 2.1.1 when distinct) via setTrustedRouter.
///      - MOCK: MockFeeToken if FEE_TOKEN unset (FeeEscrow custody asset).
///      Optional env:
///      - POOL_MANAGER: real PoolManager address (else MockPoolManager)
///      - FEE_TOKEN / LP_COMPENSATION_FUND: FeeEscrow wiring
///      - TRUSTED_ROUTER: extra router to trust in addition to the canonical Universal Router
///      - PRIVATE_KEY: broadcaster (defaults to Anvil account #0)
///      - ADMIN / REGISTRY_KEEPER / ORACLE_KEEPER / HOOK_GOVERNOR: default to the deployer for a
///        frictionless local run; a real deploy should set all four explicitly and to distinct keys.
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Anvil account #0
    uint256 constant ANVIL_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @notice Thrown when a function ended up behind a different role than intended
    error Deploy_WrongFunctionRole(address target, bytes4 selector, uint64 expected, uint64 actual);

    /// @notice Thrown when a key did not end up holding the role it was meant to hold
    error Deploy_MissingRole(address account, uint64 role);

    /// @notice Thrown when a key holds a role it was never meant to hold
    error Deploy_UnexpectedRole(address account, uint64 role);

    /// @notice Thrown when the address that configured the manager is still an admin
    error Deploy_ConfigurerStillAdmin(address configurer);

    /// @notice The deployed access manager, the single authority over the registry, the oracle and
    ///         the hook's governable thresholds.
    AccessManager public accessManager;

    /// @notice The deployed sanctions list, Layer 1
    SanctionRegistry public sanctionRegistry;

    /// @notice The deployed behavioral score store, Layer 2
    ComplianceOracle public complianceOracle;

    /// @notice The deployed ternary decision mapping, Layer 3 (no access control: a pure function)
    RiskPolicy public riskPolicy;

    /// @notice The deployed hook
    AmlHook public hook;

    /// @notice 48h differential-fee escrow (§3.7) — hook deposits risk fees on FEE_OVERRIDE
    FeeEscrow public feeEscrow;

    /// @notice PoolManager used by the hook (real or MockPoolManager)
    address public poolManager;

    /// @notice Primary trusted router (canonical Universal Router, env override, or local mock)
    address public trustedRouter;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", ANVIL_PK);
        address deployer = vm.addr(pk);

        address admin = vm.envOr("ADMIN", deployer);
        address registryKeeper = vm.envOr("REGISTRY_KEEPER", deployer);
        address oracleKeeper = vm.envOr("ORACLE_KEEPER", deployer);
        address hookGovernor = vm.envOr("HOOK_GOVERNOR", deployer);

        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0));
        address trustedRouterOverride = vm.envOr("TRUSTED_ROUTER", address(0));

        uint256 stalenessThreshold = vm.envOr("MAX_SCORE_AGE", uint256(5 minutes));
        uint64 activityWindow = uint64(vm.envOr("ACTIVITY_WINDOW", uint256(1 hours)));
        uint32 maxOpsInWindow = uint32(vm.envOr("MAX_OPS_IN_WINDOW", uint256(3)));

        vm.startBroadcast(pk);
        _deploy(
            deployer,
            admin,
            registryKeeper,
            oracleKeeper,
            hookGovernor,
            poolManagerAddr,
            trustedRouterOverride,
            stalenessThreshold,
            activityWindow,
            maxOpsInWindow
        );
        vm.stopBroadcast();

        _writeDeploymentJson(deployer, admin, registryKeeper, oracleKeeper, hookGovernor);
    }

    /// @notice Deploys the stack, wires the roles, hands over the admin role and verifies the result
    /// @dev The manager starts under `configurer`, because only an admin can wire it and the wiring
    ///      happens here. It ends under `admin`, with the configurer renouncing both the admin role
    ///      and the temporary hook-governor grant it needed to seed the trusted router. Skipping the
    ///      admin handover is the easy mistake: everything works, and the deploying key stays a
    ///      permanent admin of the whole stack.
    ///
    ///      The configurer is a parameter rather than `msg.sender` or `address(this)` because those
    ///      differ between a broadcast, where calls originate from the deploying account, and a test,
    ///      where they originate from this contract. Each caller passes what is true for it.
    /// @param configurer The address that applies the wiring, and holds admin (and, briefly, the
    ///        hook-governor role) only while it does
    /// @param admin The address that will hold the manager's admin role afterwards
    /// @param registryKeeper The key the sanctions pipeline writes with
    /// @param oracleKeeper The key the scoring engine publishes with
    /// @param hookGovernor The key that retunes the hook's thresholds and trusted-router list
    /// @param poolManagerOverride A real `IPoolManager`, or zero to deploy `MockPoolManager`
    /// @param trustedRouterOverride Extra router to trust (in addition to the canonical Universal Router)
    /// @param stalenessThreshold Seconds before a published score counts as stale (Mitigation B)
    /// @param activityWindow Seconds a burst of swaps is counted together (Mitigation C)
    /// @param maxOpsInWindow Ops inside `activityWindow` that force `FEE_OVERRIDE`
    function _deploy(
        address configurer,
        address admin,
        address registryKeeper,
        address oracleKeeper,
        address hookGovernor,
        address poolManagerOverride,
        address trustedRouterOverride,
        uint256 stalenessThreshold,
        uint64 activityWindow,
        uint32 maxOpsInWindow
    ) internal {
        _deployContracts(
            configurer, poolManagerOverride, stalenessThreshold, activityWindow, maxOpsInWindow
        );
        _configureAccess(
            configurer, admin, registryKeeper, oracleKeeper, hookGovernor, trustedRouterOverride
        );
    }

    function _deployContracts(
        address configurer,
        address poolManagerOverride,
        uint256 stalenessThreshold,
        uint64 activityWindow,
        uint32 maxOpsInWindow
    ) private {
        accessManager = new AccessManager(configurer);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager));
        riskPolicy = new RiskPolicy();

        address poolManagerAddr = poolManagerOverride;
        if (poolManagerAddr == address(0)) {
            poolManagerAddr = address(new MockPoolManager());
            console2.log("MockPoolManager", poolManagerAddr);
        }
        poolManager = poolManagerAddr;

        address feeTokenAddr = vm.envOr("FEE_TOKEN", address(0));
        if (feeTokenAddr == address(0)) {
            feeTokenAddr = address(new MockFeeToken());
            console2.log("MockFeeToken", feeTokenAddr);
        }
        address lpFund = vm.envOr("LP_COMPENSATION_FUND", configurer);
        feeEscrow = new FeeEscrow(configurer, feeTokenAddr, lpFund);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddr),
            address(accessManager),
            address(sanctionRegistry),
            address(complianceOracle),
            address(riskPolicy),
            address(feeEscrow),
            stalenessThreshold,
            activityWindow,
            maxOpsInWindow
        );
        // Broadcast scripts rewrite `new {salt}` through the deterministic CREATE2 factory; unit
        // tests that call `_deploy` from a harness use that harness as the CREATE2 origin.
        address create2Origin = configurer == address(this) ? address(this) : CREATE2_DEPLOYER;
        (address hookAddr, bytes32 salt) =
            HookMiner.find(create2Origin, flags, type(AmlHook).creationCode, constructorArgs);

        hook = new AmlHook{salt: salt}(
            IPoolManager(poolManagerAddr),
            address(accessManager),
            sanctionRegistry,
            complianceOracle,
            riskPolicy,
            IFeeEscrow(address(feeEscrow)),
            stalenessThreshold,
            activityWindow,
            maxOpsInWindow
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        feeEscrow.setDepositor(address(hook), true);
    }

    function _configureAccess(
        address configurer,
        address admin,
        address registryKeeper,
        address oracleKeeper,
        address hookGovernor,
        address trustedRouterOverride
    ) private {
        accessManager.setTargetFunctionRole(
            address(sanctionRegistry), _registrySelectors(), Roles._REGISTRY_KEEPER
        );
        accessManager.setTargetFunctionRole(
            address(complianceOracle), _oracleSelectors(), Roles._ORACLE_KEEPER
        );
        accessManager.setTargetFunctionRole(address(hook), _hookSelectors(), Roles._HOOK_GOVERNOR);

        accessManager.grantRole(Roles._REGISTRY_KEEPER, registryKeeper, 0);
        accessManager.grantRole(Roles._ORACLE_KEEPER, oracleKeeper, 0);
        accessManager.grantRole(Roles._HOOK_GOVERNOR, hookGovernor, 0);

        // Configurer needs governor for the trusted-router seed, then gives it up.
        accessManager.grantRole(Roles._HOOK_GOVERNOR, configurer, 0);

        address canonical = UniversalRouters.appRouter(block.chainid);
        trustedRouter = trustedRouterOverride;
        if (trustedRouter == address(0)) trustedRouter = canonical;
        if (trustedRouter == address(0)) {
            MockTrustedRouter mockRouter = new MockTrustedRouter();
            mockRouter.setMsgSender(configurer);
            trustedRouter = address(mockRouter);
            console2.log("MockTrustedRouter", trustedRouter);
        }
        hook.setTrustedRouter(trustedRouter, true);
        if (canonical != address(0) && canonical != trustedRouter) {
            hook.setTrustedRouter(canonical, true);
            console2.log("UniversalRouter", canonical);
        } else if (canonical != address(0)) {
            console2.log("UniversalRouter", canonical);
        }
        address v211 = UniversalRouters.appRouterV211(block.chainid);
        if (v211 != address(0) && v211 != trustedRouter) {
            hook.setTrustedRouter(v211, true);
            console2.log("UniversalRouterV211", v211);
        }

        if (configurer != hookGovernor) {
            accessManager.revokeRole(Roles._HOOK_GOVERNOR, configurer);
        }

        accessManager.grantRole(accessManager.ADMIN_ROLE(), admin, 0);
        if (configurer != admin) accessManager.renounceRole(accessManager.ADMIN_ROLE(), configurer);

        _verify(configurer, admin, registryKeeper, oracleKeeper, hookGovernor);

        console2.log("AccessManager", address(accessManager));
        console2.log("SanctionRegistry", address(sanctionRegistry));
        console2.log("ComplianceOracle", address(complianceOracle));
        console2.log("RiskPolicy", address(riskPolicy));
        console2.log("FeeEscrow", address(feeEscrow));
        console2.log("AmlHook", address(hook));
        console2.log("TrustedRouter", trustedRouter);
        console2.log("PoolManager", poolManager);
    }

    /// @notice Re-reads the wiring from the manager and reverts on the first mismatch
    /// @dev Asserts the negatives as much as the positives: no keeper may hold another keeper's role
    ///      or the governor role, and the configurer must no longer be an admin or a governor. Every
    ///      one of these is a configuration that looks healthy from the outside while having quietly
    ///      undone what the wiring was for
    function _verify(
        address configurer,
        address admin,
        address registryKeeper,
        address oracleKeeper,
        address hookGovernor
    ) internal view {
        _requireFunctionRole(address(sanctionRegistry), _registrySelectors(), Roles._REGISTRY_KEEPER);
        _requireFunctionRole(address(complianceOracle), _oracleSelectors(), Roles._ORACLE_KEEPER);
        _requireFunctionRole(address(hook), _hookSelectors(), Roles._HOOK_GOVERNOR);

        _requireRole(registryKeeper, Roles._REGISTRY_KEEPER, true);
        _requireRole(oracleKeeper, Roles._ORACLE_KEEPER, true);
        _requireRole(hookGovernor, Roles._HOOK_GOVERNOR, true);

        _requireRole(registryKeeper, Roles._ORACLE_KEEPER, false);
        _requireRole(registryKeeper, Roles._HOOK_GOVERNOR, false);
        _requireRole(oracleKeeper, Roles._REGISTRY_KEEPER, false);
        _requireRole(oracleKeeper, Roles._HOOK_GOVERNOR, false);
        _requireRole(hookGovernor, Roles._REGISTRY_KEEPER, false);
        _requireRole(hookGovernor, Roles._ORACLE_KEEPER, false);

        if (configurer != hookGovernor) {
            _requireRole(configurer, Roles._HOOK_GOVERNOR, false);
        }

        _requireRole(admin, accessManager.ADMIN_ROLE(), true);
        (bool stillAdmin,) = accessManager.hasRole(accessManager.ADMIN_ROLE(), configurer);
        if (stillAdmin && configurer != admin) revert Deploy_ConfigurerStillAdmin(configurer);
    }

    /// @notice Reverts unless every selector sits behind the expected role
    function _requireFunctionRole(address target, bytes4[] memory selectors, uint64 expected) internal view {
        for (uint256 i; i < selectors.length; ++i) {
            uint64 actual = accessManager.getTargetFunctionRole(target, selectors[i]);
            if (actual != expected) revert Deploy_WrongFunctionRole(target, selectors[i], expected, actual);
        }
    }

    /// @notice Reverts unless an account holds, or does not hold, a role
    function _requireRole(address account, uint64 role, bool shouldHold) internal view {
        (bool holds,) = accessManager.hasRole(role, account);
        if (shouldHold && !holds) revert Deploy_MissingRole(account, role);
        if (!shouldHold && holds) revert Deploy_UnexpectedRole(account, role);
    }

    /// @notice The sanctions registry functions that require a role
    function _registrySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = SanctionRegistry.setSanctioned.selector;
    }

    /// @notice The compliance oracle functions that require a role
    function _oracleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = ComplianceOracle.updateScore.selector;
    }

    /// @notice The hook functions that require the governor role
    function _hookSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = AmlHookLogic.setStalenessThreshold.selector;
        selectors[1] = AmlHookLogic.setInflowThresholdBps.selector;
        selectors[2] = AmlHookLogic.setTrustedRouter.selector;
    }

    function _writeDeploymentJson(
        address deployer,
        address admin,
        address registryKeeper,
        address oracleKeeper,
        address hookGovernor
    ) internal {
        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "deployer": "',
            vm.toString(deployer),
            '",\n',
            '  "admin": "',
            vm.toString(admin),
            '",\n',
            '  "registryKeeper": "',
            vm.toString(registryKeeper),
            '",\n',
            '  "oracleKeeper": "',
            vm.toString(oracleKeeper),
            '",\n',
            '  "hookGovernor": "',
            vm.toString(hookGovernor),
            '",\n',
            '  "AccessManager": "',
            vm.toString(address(accessManager)),
            '",\n',
            '  "SanctionRegistry": "',
            vm.toString(address(sanctionRegistry)),
            '",\n',
            '  "ComplianceOracle": "',
            vm.toString(address(complianceOracle)),
            '",\n',
            '  "RiskPolicy": "',
            vm.toString(address(riskPolicy)),
            '",\n',
            '  "FeeEscrow": "',
            vm.toString(address(feeEscrow)),
            '",\n',
            '  "AmlHook": "',
            vm.toString(address(hook)),
            '",\n',
            '  "trustedRouter": "',
            vm.toString(trustedRouter),
            '",\n',
            '  "poolManager": "',
            vm.toString(poolManager),
            '"\n',
            "}\n"
        );

        vm.writeFile("deployments/31337.json", json);
        console2.log("Wrote deployments/31337.json");
    }
}
