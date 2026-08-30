// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LpCompensationVault} from "contracts/compensation/LpCompensationVault.sol";
import {FeeEscrow} from "contracts/escrow/FeeEscrow.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {ISanctionRegistry} from "interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "interfaces/oracles/IComplianceOracle.sol";
import {HelpersCore} from "test/utils/HelpersCore.t.sol";

contract VaultToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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

contract VaultListMock is ISanctionRegistry {
    mapping(address => bool) public listed;

    function isSanctioned(address account) external view returns (bool) {
        return listed[account];
    }

    function setSanctioned(address account, bool sanctioned) external {
        listed[account] = sanctioned;
    }
}

contract VaultOracleMock {
    mapping(address => uint8) public scoreOf;

    function getScore(address account) external view returns (uint8) {
        return scoreOf[account];
    }

    function setScore(address account, uint8 score) external {
        scoreOf[account] = score;
    }
}

contract UnitLpCompensationVaultTest is HelpersCore {
    LpCompensationVault vault;
    VaultToken token;
    FeeEscrow escrow;
    VaultListMock list;
    VaultOracleMock oracle;
    address treasury = address(0xC0DE);
    address lp = address(0x1A11);

    function setUp() public {
        token = new VaultToken();
        list = new VaultListMock();
        oracle = new VaultOracleMock();
        vault = new LpCompensationVault(owner, owner, treasury);
        escrow = new FeeEscrow(owner, address(token), address(vault), treasury, owner);

        vm.startPrank(owner);
        vault.setEscrow(address(escrow));
        vault.setComplianceSources(ISanctionRegistry(address(list)), IComplianceOracle(address(oracle)));
        escrow.setComplianceSources(ISanctionRegistry(address(list)), IComplianceOracle(address(oracle)));
        escrow.setKeeper(keeper, true);
        escrow.setDepositor(address(this), true);
        vm.warp(block.timestamp + escrow.KEEPER_TIMELOCK());
        escrow.applyKeeper();
        escrow.applyDepositor();
        escrow.setAuditor(address(this), true);
        vm.stopPrank();

        token.mint(address(this), 1_000 ether);
        token.approve(address(escrow), type(uint256).max);
    }

    function _leaf(address account, address tok, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, tok, amount))));
    }

    function test_Accrue_BooksOpenEpoch() external {
        token.mint(address(vault), 10 ether);
        vault.accrue(address(token));
        assertEq(vault.epochPot(1, address(token)), 10 ether);
        assertEq(vault.accounted(address(token)), 10 ether);
    }

    function test_AccrueFromEscrow_AfterCleanRelease() external {
        uint256 id = escrow.deposit(walletA, address(token), bytes32(uint256(1)), 4 ether);
        vm.warp(block.timestamp + escrow.ESCROW_WINDOW());
        vm.prank(keeper);
        escrow.releaseDefault(id);

        vault.accrueFromEscrow(id);
        assertTrue(vault.escrowAccrued(id));
        assertEq(vault.epochPot(1, address(token)), 4 ether);
        assertEq(token.balanceOf(address(vault)), 4 ether);
    }

    function test_CloseAndClaim_SingleLeaf() external {
        token.mint(address(vault), 8 ether);
        vault.accrue(address(token));
        bytes32 root = _leaf(lp, address(token), 8 ether);
        vm.prank(owner);
        vault.closeEpoch(root, uint64(block.number));

        bytes32[] memory proof;
        vault.claim(1, lp, address(token), 8 ether, proof);
        assertEq(token.balanceOf(lp), 8 ether);
        assertTrue(vault.claimed(1, address(token), lp));
        assertEq(vault.epochId(), 2);
    }

    function test_Claim_RevertsIfIllicit() external {
        token.mint(address(vault), 1 ether);
        vault.accrue(address(token));
        bytes32 root = _leaf(lp, address(token), 1 ether);
        vm.prank(owner);
        vault.closeEpoch(root, 1);
        list.setSanctioned(lp, true);
        bytes32[] memory proof;
        vm.expectRevert(abi.encodeWithSelector(LpCompensationVault.IllicitOnChain.selector, lp));
        vault.claim(1, lp, address(token), 1 ether, proof);
    }

    function test_Claim_RevertsBadProof() external {
        token.mint(address(vault), 1 ether);
        vault.accrue(address(token));
        vm.prank(owner);
        vault.closeEpoch(_leaf(lp, address(token), 1 ether), 1);
        bytes32[] memory proof;
        vm.expectRevert(LpCompensationVault.InvalidProof.selector);
        vault.claim(1, stranger, address(token), 1 ether, proof);
    }

    function test_RecycleUnclaimed_MovesToOpenEpoch() external {
        token.mint(address(vault), 6 ether);
        vault.accrue(address(token));
        vm.prank(owner);
        vault.closeEpoch(_leaf(lp, address(token), 6 ether), 1);
        vm.warp(block.timestamp + vault.CLAIM_WINDOW() + 1);
        vault.recycleUnclaimed(1, address(token));
        assertEq(vault.epochPot(1, address(token)), 0);
        assertEq(vault.epochPot(2, address(token)), 6 ether);
    }

    function test_Constructor_RejectsSelfAsTreasury() external {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(LpCompensationVault.DestinationsMustDiffer.selector);
        new LpCompensationVault(owner, owner, predicted);
    }

    function test_AccrueFromEscrow_RejectsActiveRow() external {
        uint256 id = escrow.deposit(walletA, address(token), bytes32(uint256(2)), 1 ether);
        vm.expectRevert(LpCompensationVault.EscrowNotReleased.selector);
        vault.accrueFromEscrow(id);
    }
}
