// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeEscrow} from "../src/escrow/FeeEscrow.sol";
import {IFeeEscrow} from "../src/interfaces/IFeeEscrow.sol";

/// @dev Transferable mintable ERC-20 for FeeEscrow custody tests.
contract FeeToken {
    string public name = "Fee";
    string public symbol = "FEE";
    uint8 public decimals = 18;

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
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FeeEscrowTest is Test {
    FeeEscrow escrow;
    FeeToken token;

    address owner = address(this);
    address keeper = address(0xBEE1);
    address depositor = address(0xDE90);
    address stranger = address(0xBAD);
    address pool = address(0x1001);
    address fund = address(0xF11D);
    address wallet = address(0xA11CE);

    bytes32 constant ORIGIN_TX = bytes32(uint256(0xabc123));

    event FeeDeposited(
        uint256 indexed escrowId,
        address indexed wallet,
        uint256 amount,
        uint64 depositedAt,
        bytes32 originTxHash
    );
    event FeeReleasedEarly(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );
    event FeeConfiscated(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );
    event FeeReleasedDefault(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    function setUp() public {
        token = new FeeToken();
        escrow = new FeeEscrow(owner, address(token), pool, fund);
        escrow.setKeeper(keeper, true);
        escrow.setDepositor(depositor, true);

        token.mint(depositor, 1_000_000 ether);
        vm.prank(depositor);
        token.approve(address(escrow), type(uint256).max);
    }

    function _deposit(uint256 amount) internal returns (uint256 id) {
        vm.prank(depositor);
        id = escrow.deposit(wallet, ORIGIN_TX, amount);
    }

    function test_ConstructorSetsRolesAndRecipients() public view {
        assertEq(escrow.owner(), owner);
        assertTrue(escrow.keepers(owner));
        assertTrue(escrow.keepers(keeper));
        assertTrue(escrow.depositors(depositor));
        assertEq(address(escrow.feeToken()), address(token));
        assertEq(escrow.poolRecipient(), pool);
        assertEq(escrow.lpCompensationFund(), fund);
        assertEq(escrow.ESCROW_WINDOW(), 48 hours);
        assertEq(escrow.CHECKPOINT1_MIN_AGE(), 24 hours);
    }

    function test_DepositRecordsWalletAmountTimestampAndOriginTx() public {
        uint256 amount = 100 ether;
        uint64 t0 = uint64(block.timestamp);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit FeeDeposited(1, wallet, amount, t0, ORIGIN_TX);

        uint256 id = _deposit(amount);
        assertEq(id, 1);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(rec.wallet, wallet);
        assertEq(rec.amount, amount);
        assertEq(rec.depositedAt, t0);
        assertEq(rec.originTxHash, ORIGIN_TX);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Active));
        assertEq(token.balanceOf(address(escrow)), amount);
        assertEq(token.balanceOf(depositor), 1_000_000 ether - amount);
    }

    function test_ReleaseEarly_After24h_SendsToPool() public {
        uint256 amount = 50 ether;
        uint256 id = _deposit(amount);

        vm.warp(block.timestamp + 24 hours);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeReleasedEarly(id, wallet, amount, pool);

        vm.prank(keeper);
        escrow.releaseEarly(id);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.ReleasedEarly));
        assertEq(token.balanceOf(pool), amount);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(fund), 0);
    }

    function test_ReleaseEarly_RevertsBefore24h() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 24 hours - 1);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.Checkpoint1TooEarly.selector);
        escrow.releaseEarly(id);
    }

    function test_ReleaseEarly_RevertsAfter48hWindow() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.Checkpoint1WindowClosed.selector);
        escrow.releaseEarly(id);
    }

    function test_ResolveCheckpoint2_ConfiscatesToLpCompensation_NotPool() public {
        uint256 amount = 75 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeConfiscated(id, wallet, amount, fund);

        vm.prank(keeper);
        escrow.resolveCheckpoint2(id, true);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Confiscated));
        // Incautación → compensación a LPs; el pool no recibe nada.
        assertEq(token.balanceOf(fund), amount);
        assertEq(token.balanceOf(pool), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertTrue(fund != pool);
    }

    function test_ResolveCheckpoint2_NonIllicit_ReleasesToPool() public {
        uint256 amount = 40 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeReleasedDefault(id, wallet, amount, pool);

        vm.prank(keeper);
        escrow.resolveCheckpoint2(id, false);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.ReleasedDefault));
        assertEq(token.balanceOf(pool), amount);
        assertEq(token.balanceOf(fund), 0);
    }

    function test_ReleaseDefault_AfterWindow_SendsToPool() public {
        uint256 amount = 33 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeReleasedDefault(id, wallet, amount, pool);

        vm.prank(keeper);
        escrow.releaseDefault(id);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.ReleasedDefault));
        assertEq(token.balanceOf(pool), amount);
    }

    function test_ResolveCheckpoint2_RevertsWhileWindowOpen() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours - 1);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.EscrowWindowOpen.selector);
        escrow.resolveCheckpoint2(id, true);
    }

    function test_ReleaseDefault_RevertsWhileWindowOpen() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 47 hours);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.EscrowWindowOpen.selector);
        escrow.releaseDefault(id);
    }

    function test_NonKeeperCannotReleaseEarly() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 24 hours);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotKeeper.selector);
        escrow.releaseEarly(id);
    }

    function test_NonKeeperCannotResolveCheckpoint2() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotKeeper.selector);
        escrow.resolveCheckpoint2(id, true);
    }

    function test_NonKeeperCannotReleaseDefault() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotKeeper.selector);
        escrow.releaseDefault(id);
    }

    function test_NonDepositorCannotDeposit() public {
        token.mint(stranger, 10 ether);
        vm.startPrank(stranger);
        token.approve(address(escrow), 10 ether);
        vm.expectRevert(FeeEscrow.NotDepositor.selector);
        escrow.deposit(wallet, ORIGIN_TX, 10 ether);
        vm.stopPrank();
    }

    function test_CannotDoubleResolve() public {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        escrow.releaseEarly(id);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.NotActive.selector);
        escrow.resolveCheckpoint2(id, true);
    }

    function test_ReleaseEarlyNeverSendsToLpCompensationFund() public {
        uint256 amount = 20 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 30 hours);

        vm.prank(keeper);
        escrow.releaseEarly(id);

        assertEq(token.balanceOf(fund), 0);
        assertEq(token.balanceOf(pool), amount);
    }
}
