// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ComplianceTreasury} from "contracts/treasury/ComplianceTreasury.sol";
import {IComplianceTreasury} from "interfaces/treasury/IComplianceTreasury.sol";
import {HelpersCore} from "test/utils/HelpersCore.t.sol";

contract TreasuryToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UnitComplianceTreasuryTest is HelpersCore {
    ComplianceTreasury treasury;
    TreasuryToken token;

    function setUp() public {
        treasury = new ComplianceTreasury(owner, owner);
        token = new TreasuryToken();
        vm.startPrank(owner);
        treasury.setHook(address(this));
        treasury.setEscrow(address(this));
        vm.stopPrank();
        token.mint(address(this), 1_000 ether);
        token.approve(address(treasury), type(uint256).max);
    }

    function test_CreditPrincipal_BooksLpPrincipalOnly() external {
        treasury.creditPrincipal(walletA, address(token), 10 ether, 1, bytes32(uint256(2)), bytes32(uint256(3)));
        assertEq(treasury.balances(IComplianceTreasury.Account.LP_PRINCIPAL, address(token)), 10 ether);
        assertEq(treasury.balances(IComplianceTreasury.Account.ILLICIT_RISK_FEE, address(token)), 0);
        assertEq(token.balanceOf(address(treasury)), 10 ether);
    }

    function test_RecordIllicitFee_BooksFeeAccountOnly() external {
        token.mint(address(treasury), 4 ether);
        treasury.recordIllicitFee(walletB, address(token), 4 ether, 9, bytes32(uint256(11)));
        assertEq(treasury.balances(IComplianceTreasury.Account.ILLICIT_RISK_FEE, address(token)), 4 ether);
        assertEq(treasury.balances(IComplianceTreasury.Account.LP_PRINCIPAL, address(token)), 0);
    }

    function test_NonHookCannotCreditPrincipal() external {
        vm.prank(stranger);
        vm.expectRevert(ComplianceTreasury.NotHook.selector);
        treasury.creditPrincipal(walletA, address(token), 1, 1, bytes32(0), bytes32(0));
    }

    function test_NonEscrowCannotRecordFee() external {
        vm.prank(stranger);
        vm.expectRevert(ComplianceTreasury.NotEscrow.selector);
        treasury.recordIllicitFee(walletA, address(token), 1, 1, bytes32(0));
    }

    function test_RecordSeizedPrincipal_BooksLpPrincipalOnly() external {
        token.mint(address(treasury), 3 ether);
        treasury.recordSeizedPrincipal(walletA, address(token), 3 ether, 4, bytes32(uint256(5)));
        assertEq(treasury.balances(IComplianceTreasury.Account.LP_PRINCIPAL, address(token)), 3 ether);
        assertEq(treasury.balances(IComplianceTreasury.Account.ILLICIT_RISK_FEE, address(token)), 0);
    }
}
