// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {IComplianceOracle} from "../src/interfaces/IComplianceOracle.sol";

contract ComplianceOracleTest is Test {
    ComplianceOracle oracle;
    address owner = address(this);
    address keeper = address(0xBEEF);
    address stranger = address(0xBAD);
    address wallet = address(0xA11CE);
    address origin = address(0x1111);

    event ScoreUpdated(
        address indexed wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        uint64 updatedAt
    );
    event KeeperUpdated(address indexed keeper, bool allowed);

    function setUp() public {
        oracle = new ComplianceOracle(owner);
        oracle.setKeeper(keeper, true);
    }

    function test_OwnerIsKeeperByDefault() public view {
        assertTrue(oracle.keepers(owner));
    }

    function test_UnsetRiskIsZero() public view {
        // Storage defaults only. Hook treats updatedAt==0 as unknown (FEE_OVERRIDE), not ALLOW —
        // see OracleLatency.t.sol and whitepaper §3.8 Mitigation A.
        IComplianceOracle.WalletRisk memory risk = oracle.getRisk(wallet);
        assertEq(risk.score, 0);
        assertEq(risk.hopDistance, 0);
        assertEq(risk.origin, address(0));
        assertEq(risk.feeBps, 0);
        assertEq(risk.updatedAt, 0);
        assertEq(oracle.getScore(wallet), 0);
    }

    function test_KeeperCanUpdateScoreWithFee() public {
        vm.warp(1_700_000_000);
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ScoreUpdated(wallet, 65, 1, origin, 800, uint64(block.timestamp));
        oracle.updateScore(wallet, 65, 1, origin, 800, "");

        IComplianceOracle.WalletRisk memory risk = oracle.getRisk(wallet);
        assertEq(risk.score, 65);
        assertEq(risk.hopDistance, 1);
        assertEq(risk.origin, origin);
        assertEq(risk.feeBps, 800);
        assertEq(risk.updatedAt, uint64(block.timestamp));
        assertEq(oracle.getScore(wallet), 65);
    }

    function test_NonKeeperCannotUpdate() public {
        vm.prank(stranger);
        vm.expectRevert(ComplianceOracle.NotKeeper.selector);
        oracle.updateScore(wallet, 50, 1, origin, 300, "");
    }

    function test_ScoreAbove100Reverts() public {
        vm.prank(keeper);
        vm.expectRevert(ComplianceOracle.ScoreOutOfRange.selector);
        oracle.updateScore(wallet, 101, 0, origin, 0, "");
    }

    function test_Score100Allowed() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 100, 0, wallet, 0, "");
        assertEq(oracle.getScore(wallet), 100);
    }

    function test_SetKeeperAndRevoke() public {
        address extra = address(0xC0);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit KeeperUpdated(extra, true);
        oracle.setKeeper(extra, true);
        assertTrue(oracle.keepers(extra));

        vm.prank(extra);
        oracle.updateScore(wallet, 42, 2, origin, 300, "");
        assertEq(oracle.getScore(wallet), 42);

        oracle.setKeeper(extra, false);
        assertFalse(oracle.keepers(extra));
        vm.prank(extra);
        vm.expectRevert(ComplianceOracle.NotKeeper.selector);
        oracle.updateScore(wallet, 10, 0, origin, 0, "");
    }

    function test_NonOwnerCannotSetKeeper() public {
        vm.prank(stranger);
        vm.expectRevert(ComplianceOracle.NotOwner.selector);
        oracle.setKeeper(stranger, true);
    }

    function test_OverwriteRisk() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 65, 1, origin, 800, "");
        vm.prank(keeper);
        oracle.updateScore(wallet, 42, 2, origin, 300, "");
        IComplianceOracle.WalletRisk memory risk = oracle.getRisk(wallet);
        assertEq(risk.score, 42);
        assertEq(risk.feeBps, 300);
        assertEq(risk.hopDistance, 2);
    }
}
