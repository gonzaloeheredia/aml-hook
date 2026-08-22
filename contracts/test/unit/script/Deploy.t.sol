// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {FeeEscrow} from "contracts/escrow/FeeEscrow.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {Roles} from "libraries/Roles.sol";
import {Deploy} from "script/Deploy.sol";
import {UniversalRouters} from "libraries/UniversalRouters.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @dev Exposes the script's internal entry points so the wiring can be exercised without broadcasting.
contract DeployHarness is Deploy {
    function deploy(
        address admin_,
        address registryKeeper_,
        address oracleKeeper_,
        address hookGovernor_,
        address attestor_
    ) external {
        _deploy(
            address(this),
            admin_,
            registryKeeper_,
            oracleKeeper_,
            hookGovernor_,
            attestor_,
            address(0), // MockPoolManager
            address(0), // MockTrustedRouter
            300,
            3600,
            3
        );
    }

    function verify(
        address configurer_,
        address admin_,
        address registryKeeper_,
        address oracleKeeper_,
        address hookGovernor_
    ) external view {
        _verify(configurer_, admin_, registryKeeper_, oracleKeeper_, hookGovernor_);
    }
}

contract UnitDeployTest is Helpers {
    DeployHarness public deployment;

    function setUp() public {
        deployment = new DeployHarness();
        deployment.deploy(owner, registryKeeper, oracleKeeper, hookGovernor, _attestor());

        // Cached, so a `vm.prank` is never consumed by the getter instead of the call under test.
        accessManager = deployment.accessManager();
        sanctionRegistry = deployment.sanctionRegistry();
        complianceOracle = deployment.complianceOracle();
        riskPolicy = deployment.riskPolicy();
        hook = deployment.hook();
    }

    /*///////////////////////////////////////////////////////////////
                            WIRING
    //////////////////////////////////////////////////////////////*/

    function test_DeployWhenRunLeavesEachKeeperAbleToWriteItsOwnContract(address account) external {
        // Deploy.sol wires registryKeeper for setSanctioned + commitSanction + revealSanction
        // (see `_registrySelectors`). Emergency listings still use setSanctioned; production
        // listings should use commit-reveal.
        _sanction(sanctionRegistry, registryKeeper, account);

        vm.prank(oracleKeeper);
        complianceOracle.updateScore(account, 65, 1, address(0), 0, _scoreSig(account, 65, 1, address(0), 0));

        vm.startPrank(hookGovernor);
        hook.setStalenessThreshold(120);
        hook.setActivityWindow(2 hours, 5);
        vm.stopPrank();

        // It grants each role exactly the writes it needs
        assertTrue(sanctionRegistry.isSanctioned(account));
        assertEq(complianceOracle.getScore(account), 65);
        assertEq(hook.stalenessThreshold(), 120);
        assertEq(hook.activityWindow(), 2 hours);
        assertEq(hook.maxOpsInWindow(), 5);
    }

    /// @dev The separation only holds if the wiring made it hold; this is the assertion the script encodes.
    function test_DeployWhenRunKeepsTheKeepersOutOfEachOthersContracts(address account) external {
        vm.prank(oracleKeeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, oracleKeeper));
        sanctionRegistry.setSanctioned(account, true);

        vm.prank(registryKeeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, registryKeeper));
        complianceOracle.updateScore(account, 65, 1, address(0), 0, _scoreSig(account, 65, 1, address(0), 0));

        vm.prank(oracleKeeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, oracleKeeper));
        hook.setStalenessThreshold(1);
    }

    /// @dev The admin governs roles and is granted none of them, so it cannot write any contract.
    function test_DeployWhenRunLeavesTheAdminUnableToWrite(address account) external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        sanctionRegistry.setSanctioned(account, true);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        complianceOracle.updateScore(account, 65, 1, address(0), 0, _scoreSig(account, 65, 1, address(0), 0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        hook.setStalenessThreshold(1);
    }

    /// @dev The step that is easy to skip: without it the deploying key stays a permanent admin.
    function test_DeployWhenRunRenouncesTheConfigurersAdminRole() external view {
        (bool configurerIsAdmin,) = accessManager.hasRole(0, address(deployment));
        (bool adminIsAdmin,) = accessManager.hasRole(0, owner);

        // It hands the admin role over and keeps none of it
        assertFalse(configurerIsAdmin);
        assertTrue(adminIsAdmin);
    }

    /// @dev The configurer needed the governor role for exactly one call — seeding the trusted
    ///      router — and the script has to give that access back up afterward, same as admin.
    function test_DeployWhenRunRevokesTheConfigurersTemporaryHookGovernorRole() external view {
        (bool configurerIsGovernor,) = accessManager.hasRole(Roles._HOOK_GOVERNOR, address(deployment));
        (bool hookGovernorIsGovernor,) = accessManager.hasRole(Roles._HOOK_GOVERNOR, hookGovernor);

        assertFalse(configurerIsGovernor);
        assertTrue(hookGovernorIsGovernor);
    }

    function test_DeployWhenRunPointsAllThreeContractsAtOneManager() external view {
        address manager_ = address(accessManager);

        // It leaves a single place to revoke a compromised key
        assertEq(sanctionRegistry.authority(), manager_);
        assertEq(complianceOracle.authority(), manager_);
        assertEq(hook.authority(), manager_);
    }

    function test_DeployWhenRunSeedsATrustedRouter() external view {
        // Anvil has no canonical Universal Router, so Deploy seeds MockTrustedRouter.
        assertTrue(hook.trustedRouters(deployment.trustedRouter()));
        assertTrue(deployment.trustedRouter() != address(0));
    }

    function test_DeployWhenRunOnEthereum_TrustsAppUniswapUniversalRouter() external {
        DeployHarness live = new DeployHarness();
        vm.chainId(1);
        live.deploy(owner, registryKeeper, oracleKeeper, hookGovernor, _attestor());

        address ur = UniversalRouters.appRouter(1);
        address v211 = UniversalRouters.appRouterV211(1);
        assertTrue(live.hook().trustedRouters(ur));
        assertTrue(live.hook().trustedRouters(v211));
        assertEq(live.trustedRouter(), ur);
        // No local mock on a chain that already has the Uniswap app router.
        assertFalse(live.hook().trustedRouters(address(0)));
    }

    function test_DeployWhenRunOnUnichain_TrustsAppUniswapUniversalRouter() external {
        DeployHarness live = new DeployHarness();
        vm.chainId(130);
        live.deploy(owner, registryKeeper, oracleKeeper, hookGovernor, _attestor());

        assertTrue(live.hook().trustedRouters(UniversalRouters.appRouter(130)));
        assertTrue(live.hook().trustedRouters(UniversalRouters.appRouterV211(130)));
        assertEq(live.trustedRouter(), UniversalRouters.appRouter(130));
    }

    function test_DeployWhenRunWiresFeeEscrowAsHookDepositor() external view {
        FeeEscrow escrow = deployment.feeEscrow();
        assertEq(address(hook.feeEscrow()), address(escrow));
        assertTrue(escrow.depositors(address(hook)));
        assertTrue(escrow.depositorBootstrapped());
        assertEq(escrow.pendingDepositor(), address(0));
        assertTrue(escrow.feeToken() != address(0));
        assertTrue(escrow.allowedFeeTokens(escrow.feeToken()));
    }

    function test_DeployWhenRunHandsFeeEscrowToAdminNotConfigurer() external view {
        FeeEscrow escrow = deployment.feeEscrow();
        address configurer = address(deployment);

        assertEq(escrow.owner(), owner);
        assertEq(escrow.lpCompensationFund(), owner);
        assertEq(escrow.bootstrapper(), address(0));
        assertFalse(escrow.keepers(configurer));
        assertFalse(escrow.depositors(configurer));
        assertTrue(escrow.keepers(owner));
        assertTrue(configurer != owner);
    }

    function test_DeployWhenRunSetsDistinctAttestor() external {
        address attestor = _attestor();
        assertEq(complianceOracle.attestor(), attestor);
        assertTrue(attestor != hookGovernor);
        assertTrue(attestor != oracleKeeper);
    }

    function test_DeployWhenAttestorCollidesWithGovernor() external {
        DeployHarness harness = new DeployHarness();
        vm.expectRevert(abi.encodeWithSelector(Deploy.Deploy_AttestorNotDistinct.selector, hookGovernor));
        harness.deploy(owner, registryKeeper, oracleKeeper, hookGovernor, hookGovernor);
    }

    /*///////////////////////////////////////////////////////////////
                          VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Passing one key for two roles is a valid configuration that quietly undoes the split, so
    ///      the script refuses it rather than deploying something that looks correct.
    function test_DeployWhenTwoRolesGoToOneKey() external {
        DeployHarness harness = new DeployHarness();

        vm.expectRevert(
            abi.encodeWithSelector(Deploy.Deploy_UnexpectedRole.selector, registryKeeper, Roles._ORACLE_KEEPER)
        );
        harness.deploy(owner, registryKeeper, registryKeeper, hookGovernor, _attestor());
    }

    /// @dev The wiring is only as good as what it catches, so each failure mode is driven directly: the
    ///      manager is pushed into the bad state after a healthy deploy and the check is asked again.
    function test_VerifyWhenAFunctionSitsBehindTheWrongRole() external {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SanctionRegistry.setSanctioned.selector;

        vm.prank(owner);
        accessManager.setTargetFunctionRole(address(sanctionRegistry), selectors, Roles._ORACLE_KEEPER);

        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.Deploy_WrongFunctionRole.selector,
                address(sanctionRegistry),
                SanctionRegistry.setSanctioned.selector,
                Roles._REGISTRY_KEEPER,
                Roles._ORACLE_KEEPER
            )
        );
        deployment.verify(address(deployment), owner, registryKeeper, oracleKeeper, hookGovernor);
    }

    function test_VerifyWhenAKeeperLostItsRole() external {
        vm.prank(owner);
        accessManager.revokeRole(Roles._ORACLE_KEEPER, oracleKeeper);

        vm.expectRevert(abi.encodeWithSelector(Deploy.Deploy_MissingRole.selector, oracleKeeper, Roles._ORACLE_KEEPER));
        deployment.verify(address(deployment), owner, registryKeeper, oracleKeeper, hookGovernor);
    }

    function test_VerifyWhenTheConfigurerIsStillAdmin() external {
        vm.prank(owner);
        accessManager.grantRole(0, address(deployment), 0);

        vm.expectRevert(abi.encodeWithSelector(Deploy.Deploy_ConfigurerStillAdmin.selector, address(deployment)));
        deployment.verify(address(deployment), owner, registryKeeper, oracleKeeper, hookGovernor);
    }

    function test_VerifyWhenTheAdminNeverGotTheRole() external {
        vm.prank(owner);
        accessManager.revokeRole(0, owner);

        vm.expectRevert(abi.encodeWithSelector(Deploy.Deploy_MissingRole.selector, owner, uint64(0)));
        deployment.verify(address(deployment), owner, registryKeeper, oracleKeeper, hookGovernor);
    }
}
