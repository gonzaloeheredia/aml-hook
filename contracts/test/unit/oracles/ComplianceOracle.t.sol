// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {IComplianceOracle} from "interfaces/oracles/IComplianceOracle.sol";
import {Roles} from "libraries/Roles.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

contract UnitComplianceOracleTest is Helpers {
    address origin = address(0x1111);

    function setUp() public {
        accessManager = new AccessManager(owner);
        complianceOracle = new ComplianceOracle(address(accessManager));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), selectors, Roles._ORACLE_KEEPER, keeper);
    }

    function test_ConstructorSetsAuthority(address initialAuthority) external {
        assertEq(new ComplianceOracle(initialAuthority).authority(), initialAuthority);
    }

    function test_UnsetRiskIsZero() external view {
        // Storage defaults only. The hook treats updatedAt == 0 as unknown (FEE_OVERRIDE), not ALLOW.
        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(walletA);
        assertEq(risk.score, 0);
        assertEq(risk.hopDistance, 0);
        assertEq(risk.origin, address(0));
        assertEq(risk.feeBps, 0);
        assertEq(risk.updatedAt, 0);
        assertEq(complianceOracle.getScore(walletA), 0);
    }

    function test_KeeperCanUpdateScoreWithFee() external {
        vm.warp(1_700_000_000);
        vm.expectEmit(true, false, false, true, address(complianceOracle));
        emit IComplianceOracle.ScoreUpdated(walletA, 65, 1, origin, 800, uint64(block.timestamp));
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 65, 1, origin, 800, "");

        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(walletA);
        assertEq(risk.score, 65);
        assertEq(risk.hopDistance, 1);
        assertEq(risk.origin, origin);
        assertEq(risk.feeBps, 800);
        assertEq(risk.updatedAt, uint64(block.timestamp));
        assertEq(complianceOracle.getScore(walletA), 65);
    }

    function test_NonKeeperCannotUpdate() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        complianceOracle.updateScore(walletA, 50, 1, origin, 300, "");
    }

    function test_ManagerAdminCannotUpdate() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        complianceOracle.updateScore(walletA, 50, 1, origin, 300, "");
    }

    function test_ScoreAbove100Reverts() external {
        vm.prank(keeper);
        vm.expectRevert(ComplianceOracle.ScoreOutOfRange.selector);
        complianceOracle.updateScore(walletA, 101, 0, origin, 0, "");
    }

    function test_Score100Allowed() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, "");
        assertEq(complianceOracle.getScore(walletA), 100);
    }

    function test_OverwriteRisk() external {
        vm.startPrank(keeper);
        complianceOracle.updateScore(walletA, 65, 1, origin, 800, "");
        complianceOracle.updateScore(walletA, 42, 2, origin, 300, "");
        vm.stopPrank();

        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(walletA);
        assertEq(risk.score, 42);
        assertEq(risk.feeBps, 300);
        assertEq(risk.hopDistance, 2);
    }

    /// @dev Revoking on the shared manager stops future writes; what was written stands until overwritten.
    function test_RevokeRoleWhenKeeperIsCompromised() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 65, 1, origin, 800, "");

        vm.prank(owner);
        accessManager.revokeRole(Roles._ORACLE_KEEPER, keeper);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, "");

        assertEq(complianceOracle.getScore(walletA), 65);
    }
}
