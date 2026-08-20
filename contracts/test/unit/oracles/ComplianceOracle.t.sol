// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {IComplianceOracle} from "interfaces/oracles/IComplianceOracle.sol";
import {Roles} from "libraries/Roles.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice Unit coverage for `ComplianceOracle` (incl. portable assertions from aml-hook-dev suite).
contract UnitComplianceOracleTest is Helpers {
    address origin = address(0x1111);

    function setUp() public {
        vm.warp(1_700_000_000);
        accessManager = new AccessManager(owner);
        complianceOracle = new ComplianceOracle(address(accessManager));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), selectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory govSelectors = new bytes4[](1);
        govSelectors[0] = ComplianceOracle.setRateLimit.selector;
        _wireRole(accessManager, owner, address(complianceOracle), govSelectors, Roles._HOOK_GOVERNOR, hookGovernor);
    }

    function test_ConstructorSetsAuthority(address initialAuthority) external {
        assertEq(new ComplianceOracle(initialAuthority).authority(), initialAuthority);
    }

    /// @dev Mitigation A: unknown wallet is score 0 with updatedAt 0.
    function test_GetRiskWhenWalletWasNeverPublished(address wallet) external view {
        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(wallet);
        assertEq(risk.score, 0);
        assertEq(risk.updatedAt, 0);
        assertEq(risk.origin, address(0));
        assertEq(complianceOracle.getScore(wallet), 0);
    }

    /// @dev Confirmed-clean: score 0 with non-zero updatedAt.
    function test_GetRiskWhenWalletIsPublishedClean(address wallet) external {
        vm.prank(keeper);
        complianceOracle.updateScore(wallet, 0, 0, address(0), 0, "");

        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(wallet);
        assertEq(risk.score, 0);
        assertEq(risk.updatedAt, uint64(block.timestamp));
    }

    function test_UpdateScoreWhenCallerHasTheRole(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address originAddr,
        uint24 feeBps
    ) external {
        score = uint8(bound(score, 0, 100));
        feeBps = uint24(bound(feeBps, 0, 1000));

        vm.expectEmit(true, false, false, true, address(complianceOracle));
        emit IComplianceOracle.ScoreUpdated(
            wallet, score, hopDistance, originAddr, feeBps, uint64(block.timestamp)
        );

        vm.prank(keeper);
        complianceOracle.updateScore(wallet, score, hopDistance, originAddr, feeBps, "");

        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(wallet);
        assertEq(risk.score, score);
        assertEq(risk.hopDistance, hopDistance);
        assertEq(risk.origin, originAddr);
        assertEq(risk.feeBps, feeBps);
        assertEq(risk.updatedAt, uint64(block.timestamp));
    }

    /// @dev Packing guard: WalletRisk spans two slots; the per-wallet rate-limit tracker
    ///      writes a third. Fail if an accidental extra slot is written.
    function test_UpdateScoreWhenCallerHasTheRoleWritesPackedSlots(address wallet) external {
        vm.record();
        vm.prank(keeper);
        complianceOracle.updateScore(wallet, 100, 3, address(0xBEEF), 800, "");

        (, bytes32[] memory writes) = vm.accesses(address(complianceOracle));
        assertEq(_countDistinct(writes), 3);
    }

    function test_KeeperCanUpdateScoreWithFee() external {
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

    function test_UpdateScoreWhenScoreIsAboveOneHundred(address wallet, uint8 score) external {
        score = uint8(bound(score, 101, type(uint8).max));
        vm.prank(keeper);
        vm.expectRevert(ComplianceOracle.ScoreOutOfRange.selector);
        complianceOracle.updateScore(wallet, score, 0, origin, 0, "");
    }

    function test_Score100Allowed() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, "");
        assertEq(complianceOracle.getScore(walletA), 100);
    }

    function test_UpdateScoreWhenPublishedTwice(address wallet) external {
        vm.prank(keeper);
        complianceOracle.updateScore(wallet, 65, 1, origin, 800, "");

        vm.warp(block.timestamp + 1 days);

        vm.prank(keeper);
        complianceOracle.updateScore(wallet, 42, 2, origin, 300, "");

        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(wallet);
        assertEq(risk.score, 42);
        assertEq(risk.hopDistance, 2);
        assertEq(risk.feeBps, 300);
        assertEq(risk.updatedAt, uint64(block.timestamp));
    }

    function test_RevokeRoleWhenKeeperIsCompromised(address wallet) external {
        vm.prank(keeper);
        complianceOracle.updateScore(wallet, 65, 1, origin, 800, "");

        vm.prank(owner);
        accessManager.revokeRole(Roles._ORACLE_KEEPER, keeper);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        complianceOracle.updateScore(wallet, 0, 0, address(0), 0, "");

        assertEq(complianceOracle.getScore(wallet), 65);
    }

    /// @dev Sanctions role and scoring role must not be interchangeable.
    function test_UpdateScoreWhenCallerHoldsTheSanctionsRole(address wallet) external {
        vm.prank(owner);
        accessManager.grantRole(Roles._REGISTRY_KEEPER, stranger, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        complianceOracle.updateScore(wallet, 50, 1, address(0), 0, "");
    }

    /// @dev Unwired target stays admin-only (forgotten deploy step fails closed).
    function test_UpdateScoreWhenTargetIsUnwired(address wallet) external {
        ComplianceOracle unwired = new ComplianceOracle(address(accessManager));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        unwired.updateScore(wallet, 50, 1, address(0), 0, "");
    }

    function _countDistinct(bytes32[] memory slots) internal pure returns (uint256 count) {
        for (uint256 i; i < slots.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (slots[j] == slots[i]) seen = true;
            }
            if (!seen) ++count;
        }
    }

    /*///////////////////////////////////////////////////////////////
                            RATE LIMIT (I-2)
    //////////////////////////////////////////////////////////////*/

    function test_UpdateScore_RevertsWhenWindowExceeded(address wallet) external {
        for (uint256 i; i < 5; ++i) {
            vm.prank(keeper);
            complianceOracle.updateScore(wallet, 1, 0, origin, 0, "");
        }

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ComplianceOracle.UpdateRateLimited.selector, wallet));
        complianceOracle.updateScore(wallet, 1, 0, origin, 0, "");
    }

    function test_UpdateScore_ResetsAfterWindow(address wallet) external {
        for (uint256 i; i < 5; ++i) {
            vm.prank(keeper);
            complianceOracle.updateScore(wallet, 1, 0, origin, 0, "");
        }

        vm.warp(block.timestamp + complianceOracle.updateWindow());

        vm.prank(keeper);
        complianceOracle.updateScore(wallet, 2, 0, origin, 0, "");
        assertEq(complianceOracle.getScore(wallet), 2);
    }

    function test_SetRateLimit_GovernorCanRetune() external {
        vm.expectEmit(false, false, false, true, address(complianceOracle));
        emit ComplianceOracle.RateLimitUpdated(3, 30 minutes);

        vm.prank(hookGovernor);
        complianceOracle.setRateLimit(3, 30 minutes);

        assertEq(complianceOracle.maxUpdatesPerWindow(), 3);
        assertEq(complianceOracle.updateWindow(), 30 minutes);
    }

    function test_SetRateLimit_RevertsOnZero() external {
        vm.prank(hookGovernor);
        vm.expectRevert(ComplianceOracle.InvalidRateLimit.selector);
        complianceOracle.setRateLimit(0, 1 hours);

        vm.prank(hookGovernor);
        vm.expectRevert(ComplianceOracle.InvalidRateLimit.selector);
        complianceOracle.setRateLimit(5, 0);
    }

    function test_SetRateLimit_RevertsForNonGovernor() external {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        complianceOracle.setRateLimit(3, 1 hours);
    }
}
