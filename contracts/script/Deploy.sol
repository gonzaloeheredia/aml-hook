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
import {AmlHookGovernance} from "../src/contracts/hooks/AmlHookGovernance.sol";
import {AmlHookLogic} from "../src/contracts/hooks/AmlHookLogic.sol";
import {IFeeEscrow} from "../src/interfaces/escrow/IFeeEscrow.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {ChainlinkFeeds} from "../src/libraries/ChainlinkFeeds.sol";
import {UniversalRouters} from "../src/libraries/UniversalRouters.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockTrustedRouter} from "./mocks/MockTrustedRouter.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockUsdFeed} from "./mocks/MockUsdFeed.sol";

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
///        AmlHook also gates beforeAddLiquidity / beforeRemoveLiquidity: a sanctioned wallet
///        cannot enter or exit as a liquidity provider (sanctions only, no RiskPolicy consulted).
///      - MOCK: PoolManager defaults to MockPoolManager (no live Uniswap swaps).
///      - MOCK: MockTrustedRouter only when the chain has no canonical Universal Router
///        (Anvil). On Uniswap-supported chains, Deploy registers the app.uniswap.org
///        Universal Router (+ 2.1.1 when distinct) via setTrustedRouter.
    ///      - MOCK: MockFeeToken if FEE_TOKEN unset (FeeEscrow custody asset).
    ///      - REAL: Chainlink AggregatorV3 ETH/USD + USDC/USD + WETH on known chains.
    ///        MOCK: MockUsdFeed only on Anvil (31337) or when no official feed exists.
    ///      Optional env:
    ///      - POOL_MANAGER: real PoolManager address (else MockPoolManager)
    ///      - FEE_TOKEN: FeeEscrow custody asset (else MockFeeToken)
    ///      - LP_COMPENSATION_FUND: where a clean extra fee goes (early / clean / default). Defaults
    ///        to FEE_ESCROW_OWNER / ADMIN, never to the deploying key when those differ.
    ///      - COMPLIANCE_RESERVE: where a confirmed-illicit extra fee goes after recovery. Production
    ///        must set the authority wallet. Local Anvil uses a labeled placeholder, never the LP fund.
    ///      - FEE_ESCROW_OWNER: FeeEscrow `owner` from genesis (defaults to ADMIN). Production MUST
    ///        be a Gnosis Safe; the deployer is only a one-shot `bootstrapper` for the hook depositor.
    ///      - ETH_USD_FEED / TOKEN_USD_FEED (alias USD_FEED): override Chainlink AggregatorV3
    ///        proxies. Unset → official Data Feed for the chain (ETH/USD, USDC/USD, WETH).
    ///        Anvil (31337) has no official feed and falls back to MockUsdFeed ($1 USDC, $1000 ETH).
    ///      - TRUSTED_ROUTER: extra router to trust in addition to the canonical Universal Router
    ///      - PRIVATE_KEY: broadcaster (defaults to Anvil account #0)
    ///      - ADMIN / REGISTRY_KEEPER / ORACLE_KEEPER / HOOK_GOVERNOR / COMPLIANCE_OFFICER: default
    ///        to the deployer for a frictionless local run; a real deploy should set all five
    ///        explicitly and to distinct keys. COMPLIANCE_OFFICER is granted with a 48-hour delay.
    ///      - ATTESTOR: ECDSA attestor for ComplianceOracle.updateScore. Required and must be
    ///        distinct from HOOK_GOVERNOR and ORACLE_KEEPER (C-01). No default — a missing value
    ///        fails closed rather than aliasing the governor.
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Anvil account #0
    uint256 constant ANVIL_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    /// @dev Anvil account #9 — local-only attestor so keeper (#0) and attestor stay distinct.
    uint256 constant LOCAL_ATTESTOR_PK =
        0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;

    /// @dev Anvil accounts #1–#5. Demo wallets A–E. API holds the matching keys locally.
    ///      A is not listed: the keeper writes score 100 (`WalletBlocked`). E starts empty.
    address public constant DEMO_WALLET_A = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant DEMO_WALLET_B = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant DEMO_WALLET_C = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant DEMO_WALLET_D = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address constant DEMO_WALLET_E = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    /// @notice Thrown when a function ended up behind a different role than intended
    error Deploy_WrongFunctionRole(address target, bytes4 selector, uint64 expected, uint64 actual);

    /// @notice Thrown when a key did not end up holding the role it was meant to hold
    error Deploy_MissingRole(address account, uint64 role);

    /// @notice Thrown when a key holds a role it was never meant to hold
    error Deploy_UnexpectedRole(address account, uint64 role);

    /// @notice Thrown when the address that configured the manager is still an admin
    error Deploy_ConfigurerStillAdmin(address configurer);

    /// @notice Thrown when the oracle attestor is zero or collides with governor / oracle keeper
    error Deploy_AttestorNotDistinct(address attestor);

    /// @notice Thrown when the live oracle attestor does not match the key this script intended
    error Deploy_WrongAttestor(address expected, address actual);

    /// @notice Thrown when FeeEscrow owner is not the intended governance key
    error Deploy_WrongFeeEscrowOwner(address expected, address actual);

    /// @notice Thrown when the LP compensation fund would pay the deploying key
    error Deploy_LpFundIsConfigurer(address configurer);

    /// @notice Thrown when the compliance reserve would pay the deploying key
    error Deploy_ComplianceReserveIsConfigurer(address configurer);

    /// @notice Thrown when the LP compensation fund and the compliance reserve are the same address (whitepaper §8.3)
    error Deploy_DestinationsMustDiffer(address shared);

    /// @notice Thrown when the deploying key still holds FeeEscrow keeper / depositor / bootstrapper
    error Deploy_ConfigurerStillFeeEscrowPrivileged(address configurer);

    /// @notice Thrown when COMPLIANCE_OFFICER was left unset
    error Deploy_ComplianceOfficerRequired();

    /// @notice Thrown when the compliance officer grant does not carry a 48-hour execution delay
    error Deploy_WrongComplianceDelay(uint32 expected, uint32 actual);

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

    /// @notice 48-hour hold of the extra risk fee (whitepaper §8.3)
    FeeEscrow public feeEscrow;

    /// @notice PoolManager used by the hook (real or MockPoolManager)
    address public poolManager;

    /// @notice FeeEscrow custody token (MockFeeToken locally). Also the demo USDC.
    address public feeToken;

    /// @notice Bound USD feed for the fee token (Chainlink USDC/USD, env override, or Anvil mock).
    address public usdFeed;

    /// @notice Bound ETH/USD feed (Chainlink, env override, or Anvil mock). `setPriceFeed(address(0), …)`.
    address public ethUsdFeed;

    /// @notice Primary trusted router (canonical Universal Router, env override, or local mock)
    address public trustedRouter;

    /// @notice ECDSA attestor wired into ComplianceOracle at deploy (distinct from governor / keepers)
    address public oracleAttestor;

    /// @notice Intended FeeEscrow owner (ADMIN / FEE_ESCROW_OWNER). Not the deploying EOA when they differ.
    address public feeEscrowOwner;

    /// @notice Key that proposes / confirms policy knobs (USD floors, floor fees, pool-impact).
    /// @dev Granted `_COMPLIANCE_OFFICER` with a 48-hour execution delay.
    address public complianceOfficer;

    /// @notice Local Anvil stand-in for the compliance reserve. Production sets COMPLIANCE_RESERVE to the authority wallet.
    address public constant LOCAL_COMPLIANCE_RESERVE =
        address(uint160(uint256(keccak256("aml-hook.local.complianceReserve"))));

    /// @notice Broadcast entry: read env keys, deploy the stack, write `deployments/<chainId>.json`.
    /// @dev Production must set `ATTESTOR` and `ADMIN` / `FEE_ESCROW_OWNER`. Local Anvil may default
    ///      keepers to the deployer; attestor still cannot be left zero.
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", ANVIL_PK);
        address deployer = vm.addr(pk);

        address admin = vm.envOr("ADMIN", deployer);
        address registryKeeper = vm.envOr("REGISTRY_KEEPER", deployer);
        address oracleKeeper = vm.envOr("ORACLE_KEEPER", deployer);
        address hookGovernor = vm.envOr("HOOK_GOVERNOR", deployer);
        complianceOfficer = vm.envOr("COMPLIANCE_OFFICER", deployer);
        address attestor = vm.envOr("ATTESTOR", address(0));
        if (attestor == address(0) && block.chainid == 31337) {
            attestor = vm.addr(LOCAL_ATTESTOR_PK);
        }
        feeEscrowOwner = vm.envOr("FEE_ESCROW_OWNER", admin);

        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0));
        address trustedRouterOverride = vm.envOr("TRUSTED_ROUTER", address(0));

        uint256 stalenessThreshold = vm.envOr("MAX_SCORE_AGE", uint256(5 minutes));
        uint64 activityWindow = uint64(vm.envOr("ACTIVITY_WINDOW", uint256(1 hours)));

        vm.startBroadcast(pk);
        _deploy(
            deployer,
            admin,
            registryKeeper,
            oracleKeeper,
            hookGovernor,
            attestor,
            poolManagerAddr,
            trustedRouterOverride,
            stalenessThreshold,
            activityWindow
        );
        // Wallet A stays off SanctionRegistry. The demo API publishes score 100
        // (confirmed exploit) so pool swaps hit WalletBlocked / SCORE_REVERT_BAND.
        vm.stopBroadcast();

        _writeDeploymentJson(deployer, admin, registryKeeper, oracleKeeper, hookGovernor, complianceOfficer);
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
    /// @param hookGovernor The key that retunes operational hook thresholds and trusted routers
    /// @param attestor The ECDSA attestor for `updateScore` payloads (distinct from governor / keeper)
    /// @param poolManagerOverride A real `IPoolManager`, or zero to deploy `MockPoolManager`
    /// @param trustedRouterOverride Extra router to trust (in addition to the canonical Universal Router)
    /// @param stalenessThreshold Seconds before a published score counts as stale (Floor B; default 5 minutes)
    /// @param activityWindow Initial Floor B window in seconds (governor retunes via `setActivityWindow`)
    function _deploy(
        address configurer,
        address admin,
        address registryKeeper,
        address oracleKeeper,
        address hookGovernor,
        address attestor,
        address poolManagerOverride,
        address trustedRouterOverride,
        uint256 stalenessThreshold,
        uint64 activityWindow
    ) internal {
        if (
            attestor == address(0) || attestor == hookGovernor || attestor == oracleKeeper
                || attestor == registryKeeper
        ) {
            revert Deploy_AttestorNotDistinct(attestor);
        }
        if (feeEscrowOwner == address(0)) feeEscrowOwner = admin;
        oracleAttestor = attestor;
        _deployContracts(configurer, poolManagerOverride, stalenessThreshold, activityWindow, attestor);
        _configureAccess(
            configurer, admin, registryKeeper, oracleKeeper, hookGovernor, trustedRouterOverride
        );
    }

    /// @dev CREATE2-mine the hook, construct FeeEscrow under `feeEscrowOwner`, bootstrap the hook depositor.
    function _deployContracts(
        address configurer,
        address poolManagerOverride,
        uint256 stalenessThreshold,
        uint64 activityWindow,
        address attestor
    ) private {
        accessManager = new AccessManager(configurer);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), attestor);
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
        feeToken = feeTokenAddr;
        address lpFund = vm.envOr("LP_COMPENSATION_FUND", address(0));
        if (lpFund == address(0)) lpFund = feeEscrowOwner;
        if (lpFund == configurer && configurer != feeEscrowOwner) revert Deploy_LpFundIsConfigurer(configurer);
        address reserve = vm.envOr("COMPLIANCE_RESERVE", address(0));
        if (reserve == address(0)) reserve = LOCAL_COMPLIANCE_RESERVE;
        if (reserve == configurer && configurer != feeEscrowOwner) {
            revert Deploy_ComplianceReserveIsConfigurer(configurer);
        }
        if (reserve == lpFund) revert Deploy_DestinationsMustDiffer(reserve);
        feeEscrow = new FeeEscrow(feeEscrowOwner, feeTokenAddr, lpFund, reserve, configurer);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddr),
            address(accessManager),
            address(sanctionRegistry),
            address(complianceOracle),
            address(riskPolicy),
            address(feeEscrow),
            stalenessThreshold,
            activityWindow
        );
        // Broadcast scripts rewrite `new {salt}` through the deterministic CREATE2 factory; unit
        // tests that call `_deploy` from a harness use that harness as the CREATE2 origin.
        // Do not read `address(this)` here: recent Foundry reverts on ADDRESS in scripts.
        address create2Origin = configurer.code.length > 0 ? configurer : CREATE2_DEPLOYER;
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
            activityWindow
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        feeEscrow.bootstrapDepositor(address(hook));
    }

    /// @dev Wire selectors to roles, grant keepers / governor / compliance officer (48h),
    ///      seed trusted routers, hand admin to `admin`.
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
        accessManager.setTargetFunctionRole(address(hook), _complianceSelectors(), Roles._COMPLIANCE_OFFICER);
        accessManager.setTargetFunctionRole(
            address(complianceOracle), _oracleGovernorSelectors(), Roles._HOOK_GOVERNOR
        );
        accessManager.setTargetFunctionRole(
            address(sanctionRegistry), _registryGovernorSelectors(), Roles._HOOK_GOVERNOR
        );

        if (complianceOfficer == address(0)) revert Deploy_ComplianceOfficerRequired();

        accessManager.grantRole(Roles._REGISTRY_KEEPER, registryKeeper, 0);
        accessManager.grantRole(Roles._ORACLE_KEEPER, oracleKeeper, 0);
        accessManager.grantRole(Roles._HOOK_GOVERNOR, hookGovernor, 0);
        accessManager.grantRole(Roles._COMPLIANCE_OFFICER, complianceOfficer, uint32(48 hours));

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

        _bindPriceFeeds(feeToken);
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
        console2.log("FeeEscrowOwner", feeEscrowOwner);
        console2.log("LpCompensationFund", feeEscrow.lpCompensationFund());
        console2.log("ComplianceReserve", feeEscrow.complianceReserve());
        console2.log("AmlHook", address(hook));
        console2.log("Attestor", oracleAttestor);
        console2.log("ComplianceOfficer", complianceOfficer);
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
        _requireFunctionRole(address(hook), _complianceSelectors(), Roles._COMPLIANCE_OFFICER);
        _requireFunctionRole(address(complianceOracle), _oracleGovernorSelectors(), Roles._HOOK_GOVERNOR);
        _requireFunctionRole(address(sanctionRegistry), _registryGovernorSelectors(), Roles._HOOK_GOVERNOR);

        _requireRole(registryKeeper, Roles._REGISTRY_KEEPER, true);
        _requireRole(oracleKeeper, Roles._ORACLE_KEEPER, true);
        _requireRole(hookGovernor, Roles._HOOK_GOVERNOR, true);
        _requireRole(complianceOfficer, Roles._COMPLIANCE_OFFICER, true);
        (, uint32 complianceDelay) = accessManager.hasRole(Roles._COMPLIANCE_OFFICER, complianceOfficer);
        if (complianceDelay != uint32(48 hours)) {
            revert Deploy_WrongComplianceDelay(uint32(48 hours), complianceDelay);
        }

        _requireRole(registryKeeper, Roles._ORACLE_KEEPER, false);
        _requireRole(registryKeeper, Roles._HOOK_GOVERNOR, false);
        _requireRole(oracleKeeper, Roles._REGISTRY_KEEPER, false);
        _requireRole(oracleKeeper, Roles._HOOK_GOVERNOR, false);
        _requireRole(hookGovernor, Roles._REGISTRY_KEEPER, false);
        _requireRole(hookGovernor, Roles._ORACLE_KEEPER, false);
        if (registryKeeper != complianceOfficer) {
            _requireRole(registryKeeper, Roles._COMPLIANCE_OFFICER, false);
        }
        if (oracleKeeper != complianceOfficer) {
            _requireRole(oracleKeeper, Roles._COMPLIANCE_OFFICER, false);
        }
        if (hookGovernor != complianceOfficer) {
            _requireRole(hookGovernor, Roles._COMPLIANCE_OFFICER, false);
            _requireRole(complianceOfficer, Roles._HOOK_GOVERNOR, false);
        }

        if (configurer != hookGovernor) {
            _requireRole(configurer, Roles._HOOK_GOVERNOR, false);
        }

        _requireRole(admin, accessManager.ADMIN_ROLE(), true);
        (bool stillAdmin,) = accessManager.hasRole(accessManager.ADMIN_ROLE(), configurer);
        if (stillAdmin && configurer != admin) revert Deploy_ConfigurerStillAdmin(configurer);

        address attestor = oracleAttestor;
        if (
            attestor == address(0) || attestor == hookGovernor || attestor == oracleKeeper
                || attestor == registryKeeper
        ) {
            revert Deploy_AttestorNotDistinct(attestor);
        }
        address liveAttestor = complianceOracle.attestor();
        if (liveAttestor != attestor) revert Deploy_WrongAttestor(attestor, liveAttestor);

        if (feeEscrow.owner() != feeEscrowOwner) {
            revert Deploy_WrongFeeEscrowOwner(feeEscrowOwner, feeEscrow.owner());
        }
        if (feeEscrow.lpCompensationFund() == configurer && configurer != feeEscrowOwner) {
            revert Deploy_LpFundIsConfigurer(configurer);
        }
        if (feeEscrow.complianceReserve() == configurer && configurer != feeEscrowOwner) {
            revert Deploy_ComplianceReserveIsConfigurer(configurer);
        }
        if (feeEscrow.complianceReserve() == feeEscrow.lpCompensationFund()) {
            revert Deploy_DestinationsMustDiffer(feeEscrow.complianceReserve());
        }
        if (
            configurer != feeEscrowOwner
                && (
                    feeEscrow.keepers(configurer) || feeEscrow.depositors(configurer)
                        || feeEscrow.bootstrapper() != address(0)
                )
        ) {
            revert Deploy_ConfigurerStillFeeEscrowPrivileged(configurer);
        }
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
        selectors = new bytes4[](3);
        selectors[0] = SanctionRegistry.setSanctioned.selector;
        selectors[1] = SanctionRegistry.commitSanction.selector;
        selectors[2] = SanctionRegistry.revealSanction.selector;
    }

    /// @notice The compliance oracle functions that require a role
    function _oracleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = ComplianceOracle.updateScore.selector;
    }

    /// @notice Oracle governance (rate limit) — `_HOOK_GOVERNOR`, not the scoring keeper.
    function _oracleGovernorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = ComplianceOracle.setRateLimit.selector;
        selectors[1] = ComplianceOracle.setAttestor.selector;
    }

    /// @notice Registry governance (reveal delay) — `_HOOK_GOVERNOR`.
    function _registryGovernorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = SanctionRegistry.setRevealDelay.selector;
    }

    /// @notice The hook functions that require the governor role
    function _hookSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](14);
        selectors[0] = AmlHookGovernance.setStalenessThreshold.selector;
        selectors[1] = AmlHookGovernance.setInflowThresholdBps.selector;
        selectors[2] = AmlHookGovernance.setTrustedRouter.selector;
        selectors[3] = AmlHookGovernance.pause.selector;
        selectors[4] = AmlHookGovernance.unpause.selector;
        selectors[5] = AmlHookGovernance.setTrustedMultisig.selector;
        selectors[6] = AmlHookGovernance.setMultisigAggregation.selector;
        selectors[7] = AmlHookGovernance.setMinBaselineInterval.selector;
        selectors[8] = AmlHookGovernance.setPriceFeed.selector;
        selectors[9] = AmlHookGovernance.setPriceStalenessThreshold.selector;
        selectors[10] = AmlHookGovernance.setActivityWindow.selector;
        selectors[11] = AmlHookLogic.observeSwap.selector;
        selectors[12] = AmlHookLogic.syncBaseline.selector;
        selectors[13] = AmlHookGovernance.setDailyWindow.selector;
    }

    /// @dev Bind Chainlink AggregatorV3 proxies so USD floors use live prices.
    ///      Native ETH (`address(0)`) and canonical WETH share ETH/USD. Canonical USDC
    ///      gets USDC/USD. The FeeEscrow custody token uses TOKEN_USD_FEED, or the
    ///      matching official feed, or MockUsdFeed on Anvil only.
    function _bindPriceFeeds(address feeTokenAddr) private {
        address ethUsd = vm.envOr("ETH_USD_FEED", ChainlinkFeeds.ethUsd(block.chainid));
        address tokenUsd = vm.envOr("TOKEN_USD_FEED", address(0));
        if (tokenUsd == address(0)) tokenUsd = vm.envOr("USD_FEED", address(0));

        if (ethUsd == address(0) && block.chainid == 31337) {
            ethUsd = address(new MockUsdFeed(1_000e8));
            console2.log("MockEthUsdFeed", ethUsd);
        }
        if (ethUsd != address(0)) {
            hook.setPriceFeed(address(0), ethUsd);
            address weth = ChainlinkFeeds.weth(block.chainid);
            if (weth != address(0)) hook.setPriceFeed(weth, ethUsd);
            ethUsdFeed = ethUsd;
            console2.log("EthUsdFeed", ethUsd);
        }

        address usdc = ChainlinkFeeds.usdc(block.chainid);
        address usdcUsd = ChainlinkFeeds.usdcUsd(block.chainid);
        if (usdc != address(0) && usdcUsd != address(0)) {
            hook.setPriceFeed(usdc, usdcUsd);
            console2.log("UsdcUsdFeed", usdcUsd);
        }

        address feeFeed = tokenUsd;
        if (feeFeed == address(0) && feeTokenAddr != address(0) && feeTokenAddr == usdc && usdcUsd != address(0)) {
            feeFeed = usdcUsd;
        }
        if (
            feeFeed == address(0) && feeTokenAddr != address(0)
                && feeTokenAddr == ChainlinkFeeds.weth(block.chainid) && ethUsd != address(0)
        ) {
            feeFeed = ethUsd;
        }
        if (feeFeed == address(0) && block.chainid == 31337) {
            feeFeed = address(new MockUsdFeed(1e8));
            console2.log("MockUsdFeed", feeFeed);
        }
        if (feeFeed != address(0)) {
            hook.setPriceFeed(feeTokenAddr, feeFeed);
            usdFeed = feeFeed;
            console2.log("FeeTokenUsdFeed", feeFeed);
        }
    }

    /// @notice Policy-knob confirmations — `_COMPLIANCE_OFFICER` (48h grant delay), not the governor.
    function _complianceSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = AmlHookGovernance.applyUnscoredThresholds.selector;
        selectors[1] = AmlHookGovernance.applyPoolImpactThresholdBps.selector;
        selectors[2] = AmlHookGovernance.applyFloorFees.selector;
    }

    /// @dev Persist addresses and intended keys for the SDK / API sync.
    function _writeDeploymentJson(
        address deployer,
        address admin,
        address registryKeeper,
        address oracleKeeper,
        address hookGovernor,
        address complianceOfficer_
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
            '  "complianceOfficer": "',
            vm.toString(complianceOfficer_),
            '",\n',
            '  "attestor": "',
            vm.toString(oracleAttestor),
            '",\n'
        );
        json = string.concat(
            json,
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
            '  "feeEscrowOwner": "',
            vm.toString(feeEscrowOwner),
            '",\n',
            '  "lpCompensationFund": "',
            vm.toString(feeEscrow.lpCompensationFund()),
            '",\n',
            '  "complianceReserve": "',
            vm.toString(feeEscrow.complianceReserve()),
            '",\n',
            '  "AmlHook": "',
            vm.toString(address(hook)),
            '",\n',
            '  "trustedRouter": "',
            vm.toString(trustedRouter),
            '",\n',
            '  "poolManager": "',
            vm.toString(poolManager),
            '",\n',
            '  "feeToken": "',
            vm.toString(feeToken),
            '",\n',
            '  "usdFeed": "',
            vm.toString(usdFeed),
            '",\n',
            '  "ethUsdFeed": "',
            vm.toString(ethUsdFeed),
            '",\n',
            '  "wallets": {\n',
            '    "A": "',
            vm.toString(DEMO_WALLET_A),
            '",\n',
            '    "B": "',
            vm.toString(DEMO_WALLET_B),
            '",\n',
            '    "C": "',
            vm.toString(DEMO_WALLET_C),
            '",\n',
            '    "D": "',
            vm.toString(DEMO_WALLET_D),
            '",\n',
            '    "E": "',
            vm.toString(DEMO_WALLET_E),
            '"\n',
            "  }\n",
            "}\n"
        );

        string memory deployFile = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeFile(deployFile, json);
        console2.log(string.concat("Wrote ", deployFile));
    }
}
