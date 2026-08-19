// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeEscrow} from "contracts/escrow/FeeEscrow.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

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

contract UnitFeeEscrowTest is Helpers {
    FeeEscrow escrow;
    FeeToken token;

    address depositor = address(0xDE90);
    address pool = address(0x1001);
    address fund = address(0xF11D);

    bytes32 constant ORIGIN_TX = bytes32(uint256(0xabc123));

    event FeeDeposited(
        uint256 indexed escrowId,
        address indexed wallet,
        uint256 amount,
        uint64 depositedAt,
        bytes32 swapFingerprint
    );
    event FeeReleasedEarly(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );
    event FeeBlocked(uint256 indexed escrowId, address indexed wallet, uint256 amount);
    event FeeReleasedDefault(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    function setUp() public {
        token = new FeeToken();
        escrow = new FeeEscrow(owner, address(token), fund);

        vm.startPrank(owner);
        escrow.setKeeper(keeper, true);
        escrow.setDepositor(depositor, true);
        vm.stopPrank();

        token.mint(depositor, 1_000_000 ether);
        vm.prank(depositor);
        token.approve(address(escrow), type(uint256).max);
    }

    function _deposit(uint256 amount) internal returns (uint256 id) {
        vm.prank(depositor);
        id = escrow.deposit(walletA, ORIGIN_TX, amount);
    }

    function test_ConstructorSetsRolesAndRecipients() external view {
        assertEq(escrow.owner(), owner);
        assertTrue(escrow.keepers(owner));
        assertTrue(escrow.keepers(keeper));
        assertTrue(escrow.depositors(depositor));
        assertEq(address(escrow.feeToken()), address(token));
        assertEq(escrow.lpCompensationFund(), fund);
        assertEq(escrow.ESCROW_WINDOW(), 48 hours);
        assertEq(escrow.CHECKPOINT1_MIN_AGE(), 24 hours);
    }

    function test_DepositRecordsWalletAmountTimestampAndOriginTx() external {
        uint256 amount = 100 ether;
        uint64 t0 = uint64(block.timestamp);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit FeeDeposited(1, walletA, amount, t0, ORIGIN_TX);

        uint256 id = _deposit(amount);
        assertEq(id, 1);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(rec.wallet, walletA);
        assertEq(rec.amount, amount);
        assertEq(rec.depositedAt, t0);
        assertEq(rec.swapFingerprint, ORIGIN_TX);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Active));
        assertEq(token.balanceOf(address(escrow)), amount);
        assertEq(token.balanceOf(depositor), 1_000_000 ether - amount);
    }

    function test_ReleaseEarly_After24h_SendsToLpFund_NotPool() external {
        uint256 amount = 50 ether;
        uint256 id = _deposit(amount);

        vm.warp(block.timestamp + 24 hours);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeReleasedEarly(id, walletA, amount, fund);

        vm.prank(keeper);
        escrow.releaseEarly(id);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.ReleasedEarly));
        assertEq(token.balanceOf(fund), amount);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(pool), 0);
    }

    function test_ReleaseEarly_RevertsBefore24h() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 24 hours - 1);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.Checkpoint1TooEarly.selector);
        escrow.releaseEarly(id);
    }

    function test_ReleaseEarly_RevertsAfter48hWindow() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.Checkpoint1WindowClosed.selector);
        escrow.releaseEarly(id);
    }

    function test_ResolveCheckpoint2_BlocksFeeOnSanction_DoesNotTransfer() external {
        uint256 amount = 75 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit FeeBlocked(id, walletA, amount);

        vm.prank(keeper);
        escrow.resolveCheckpoint2(id, true);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Blocked));
        // Sanción confirmada → el fee queda bloqueado en el escrow; nadie recibe transfer.
        assertEq(token.balanceOf(address(escrow)), amount);
        assertEq(token.balanceOf(fund), 0);
        assertEq(token.balanceOf(pool), 0);
        assertTrue(fund != pool);
    }

    function test_ResolveCheckpoint2_BlockedCannotBeReleasedLater() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(keeper);
        escrow.resolveCheckpoint2(id, true);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.NotActive.selector);
        escrow.releaseDefault(id);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.NotActive.selector);
        escrow.resolveCheckpoint2(id, false);
    }

    function test_ResolveCheckpoint2_CleanReleasesToLpFund_NotPool() external {
        uint256 amount = 40 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeReleasedDefault(id, walletA, amount, fund);

        vm.prank(keeper);
        escrow.resolveCheckpoint2(id, false);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.ReleasedDefault));
        assertEq(token.balanceOf(fund), amount);
        assertEq(token.balanceOf(pool), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ReleaseDefault_AfterWindow_SendsToLpFund_NotPool() external {
        uint256 amount = 33 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeReleasedDefault(id, walletA, amount, fund);

        vm.prank(keeper);
        escrow.releaseDefault(id);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.ReleasedDefault));
        assertEq(token.balanceOf(fund), amount);
        assertEq(token.balanceOf(pool), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ResolveCheckpoint2_RevertsWhileWindowOpen() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours - 1);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.EscrowWindowOpen.selector);
        escrow.resolveCheckpoint2(id, true);
    }

    function test_ReleaseDefault_RevertsWhileWindowOpen() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 47 hours);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.EscrowWindowOpen.selector);
        escrow.releaseDefault(id);
    }

    function test_NonKeeperCannotReleaseEarly() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 24 hours);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotKeeper.selector);
        escrow.releaseEarly(id);
    }

    function test_NonKeeperCannotResolveCheckpoint2() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotKeeper.selector);
        escrow.resolveCheckpoint2(id, true);
    }

    function test_NonKeeperCannotReleaseDefault() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 48 hours);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotKeeper.selector);
        escrow.releaseDefault(id);
    }

    function test_NonDepositorCannotDeposit() external {
        token.mint(stranger, 10 ether);
        vm.startPrank(stranger);
        token.approve(address(escrow), 10 ether);
        vm.expectRevert(FeeEscrow.NotDepositor.selector);
        escrow.deposit(walletA, ORIGIN_TX, 10 ether);
        vm.stopPrank();
    }

    function test_CannotDoubleResolve() external {
        uint256 id = _deposit(10 ether);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        escrow.releaseEarly(id);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.NotActive.selector);
        escrow.resolveCheckpoint2(id, true);
    }

    function test_ReleaseEarlyNeverSendsToPool() external {
        uint256 amount = 20 ether;
        uint256 id = _deposit(amount);
        vm.warp(block.timestamp + 30 hours);

        vm.prank(keeper);
        escrow.releaseEarly(id);

        assertEq(token.balanceOf(fund), amount);
        assertEq(token.balanceOf(pool), 0);
    }

    /*///////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_RevertsOnZeroAddress() external {
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        new FeeEscrow(address(0), address(token), fund);

        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        new FeeEscrow(owner, address(0), fund);

        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        new FeeEscrow(owner, address(token), address(0));
    }

    function test_Deposit_RevertsOnZeroWalletOrAmount() external {
        vm.startPrank(depositor);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.deposit(address(0), ORIGIN_TX, 1 ether);

        vm.expectRevert(FeeEscrow.ZeroAmount.selector);
        escrow.deposit(walletA, ORIGIN_TX, 0);
        vm.stopPrank();
    }

    function test_GetEscrow_RevertsOnUnknownId() external {
        vm.expectRevert(FeeEscrow.UnknownEscrow.selector);
        escrow.getEscrow(0);

        vm.expectRevert(FeeEscrow.UnknownEscrow.selector);
        escrow.getEscrow(1);
    }

    function test_SetKeeper_OwnerCanGrantAndRevoke() external {
        address extra = makeAddr("extraKeeper");
        vm.prank(owner);
        escrow.setKeeper(extra, true);
        assertTrue(escrow.keepers(extra));

        vm.prank(owner);
        escrow.setKeeper(extra, false);
        assertFalse(escrow.keepers(extra));
    }

    function test_SetKeeper_RevertsForNonOwnerAndZero() external {
        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.setKeeper(stranger, true);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.setKeeper(address(0), true);
    }

    function test_SetDepositor_OwnerCanGrantAndRevoke() external {
        address extra = makeAddr("extraDepositor");
        vm.prank(owner);
        escrow.setDepositor(extra, true);
        assertTrue(escrow.depositors(extra));

        vm.prank(owner);
        escrow.setDepositor(extra, false);
        assertFalse(escrow.depositors(extra));
    }

    function test_SetDepositor_RevertsForNonOwnerAndZero() external {
        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.setDepositor(stranger, true);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.setDepositor(address(0), true);
    }

    function test_SetLpCompensationFund() external {
        address nextFund = makeAddr("nextFund");
        vm.prank(owner);
        escrow.setLpCompensationFund(nextFund);
        assertEq(escrow.lpCompensationFund(), nextFund);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.setLpCompensationFund(fund);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.setLpCompensationFund(address(0));
    }

    function test_TransferOwnership_TwoStep() external {
        address nextOwner = makeAddr("nextOwner");
        vm.prank(owner);
        escrow.transferOwnership(nextOwner);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), nextOwner);

        // Propose does not transfer admin yet.
        vm.prank(nextOwner);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.setLpCompensationFund(fund);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotPendingOwner.selector);
        escrow.acceptOwnership();

        vm.prank(nextOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), nextOwner);
        assertEq(escrow.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.setLpCompensationFund(fund);

        vm.prank(nextOwner);
        escrow.setLpCompensationFund(fund);
        assertEq(escrow.lpCompensationFund(), fund);

        vm.prank(nextOwner);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.transferOwnership(address(0));
    }

    function test_BatchReleaseEarly() external {
        uint256 a = _deposit(10 ether);
        uint256 b = _deposit(20 ether);
        vm.warp(block.timestamp + 24 hours);

        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        vm.prank(keeper);
        escrow.batchReleaseEarly(ids);

        assertEq(token.balanceOf(fund), 30 ether);
        assertEq(token.balanceOf(pool), 0);
        assertEq(uint8(escrow.getEscrow(a).status), uint8(IFeeEscrow.EscrowStatus.ReleasedEarly));
        assertEq(uint8(escrow.getEscrow(b).status), uint8(IFeeEscrow.EscrowStatus.ReleasedEarly));
    }

    function test_BatchResolveCheckpoint2() external {
        uint256 cleanId = _deposit(5 ether);
        uint256 illicitId = _deposit(7 ether);
        vm.warp(block.timestamp + 48 hours);

        uint256[] memory ids = new uint256[](2);
        ids[0] = cleanId;
        ids[1] = illicitId;
        bool[] memory flags = new bool[](2);
        flags[0] = false;
        flags[1] = true;

        vm.prank(keeper);
        escrow.batchResolveCheckpoint2(ids, flags);

        assertEq(token.balanceOf(pool), 0);
        assertEq(token.balanceOf(fund), 5 ether);
        assertEq(token.balanceOf(address(escrow)), 7 ether);
        assertEq(uint8(escrow.getEscrow(cleanId).status), uint8(IFeeEscrow.EscrowStatus.ReleasedDefault));
        assertEq(uint8(escrow.getEscrow(illicitId).status), uint8(IFeeEscrow.EscrowStatus.Blocked));
    }

    function test_BatchResolveCheckpoint2_RevertsOnLengthMismatch() external {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        bool[] memory flags = new bool[](2);
        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.LengthMismatch.selector);
        escrow.batchResolveCheckpoint2(ids, flags);
    }

    function test_BatchReleaseDefault() external {
        uint256 a = _deposit(3 ether);
        uint256 b = _deposit(4 ether);
        vm.warp(block.timestamp + 48 hours);

        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        vm.prank(keeper);
        escrow.batchReleaseDefault(ids);

        assertEq(token.balanceOf(fund), 7 ether);
        assertEq(token.balanceOf(pool), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_UpdatedLpFund_UsedOnReleaseEarly() external {
        address nextFund = makeAddr("routingPool");
        uint256 amount = 15 ether;
        uint256 id = _deposit(amount);

        vm.prank(owner);
        escrow.setLpCompensationFund(nextFund);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        escrow.releaseEarly(id);

        assertEq(token.balanceOf(nextFund), amount);
        assertEq(token.balanceOf(fund), 0);
        assertEq(token.balanceOf(pool), 0);
    }

    function test_UpdatedLpFund_UsedOnReleaseDefault() external {
        address nextFund = makeAddr("routingFund");
        uint256 amount = 12 ether;
        uint256 id = _deposit(amount);

        vm.prank(owner);
        escrow.setLpCompensationFund(nextFund);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(keeper);
        escrow.releaseDefault(id);

        assertEq(token.balanceOf(nextFund), amount);
        assertEq(token.balanceOf(fund), 0);
        assertEq(token.balanceOf(pool), 0);
    }

    /*///////////////////////////////////////////////////////////////
                            RECOVER BLOCKED (I-3)
    //////////////////////////////////////////////////////////////*/

    function _blockedEscrow(uint256 amount) internal returns (uint256 id) {
        id = _deposit(amount);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(keeper);
        escrow.resolveCheckpoint2(id, true);
    }

    event FeeRecovered(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    function test_RecoverBlocked_OwnerCanRecoverToLpFund() external {
        uint256 amount = 30 ether;
        uint256 id = _blockedEscrow(amount);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeRecovered(id, walletA, amount, fund);

        vm.prank(owner);
        escrow.recoverBlocked(id, fund);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Recovered));
        assertEq(token.balanceOf(fund), amount);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    /// @dev I-3: recoverBlocked no longer accepts an arbitrary destination. Only the current
    ///      lpCompensationFund is a valid `to`, closing the owner-key single-point-of-failure
    ///      that let a compromised owner redirect a confiscated, sanctioned fee anywhere.
    function test_RecoverBlocked_RevertsOnArbitraryDestination() external {
        uint256 id = _blockedEscrow(10 ether);
        address arbitrary = makeAddr("attacker");

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.InvalidRecoveryDestination.selector);
        escrow.recoverBlocked(id, arbitrary);
    }

    function test_RecoverBlocked_RevertsOnZeroAddress() external {
        uint256 id = _blockedEscrow(10 ether);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.InvalidRecoveryDestination.selector);
        escrow.recoverBlocked(id, address(0));
    }

    function test_RecoverBlocked_RevertsForNonOwner() external {
        uint256 id = _blockedEscrow(10 ether);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.recoverBlocked(id, fund);
    }

    function test_RecoverBlocked_RevertsIfNotBlocked() external {
        uint256 id = _deposit(10 ether);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.NotBlocked.selector);
        escrow.recoverBlocked(id, fund);
    }

    function test_RecoverBlocked_CannotBeCalledTwice() external {
        uint256 id = _blockedEscrow(10 ether);

        vm.prank(owner);
        escrow.recoverBlocked(id, fund);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.NotBlocked.selector);
        escrow.recoverBlocked(id, fund);
    }

    /*///////////////////////////////////////////////////////////////
                        BATCH SIZE LIMIT (L-2)
    //////////////////////////////////////////////////////////////*/

    function test_BatchReleaseEarly_RevertsAboveMaxBatchSize() external {
        uint256 max = escrow.MAX_BATCH_SIZE();
        uint256[] memory ids = new uint256[](max + 1);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.BatchTooLarge.selector);
        escrow.batchReleaseEarly(ids);
    }

    function test_BatchResolveCheckpoint2_RevertsAboveMaxBatchSize() external {
        uint256 max = escrow.MAX_BATCH_SIZE();
        uint256[] memory ids = new uint256[](max + 1);
        bool[] memory flags = new bool[](max + 1);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.BatchTooLarge.selector);
        escrow.batchResolveCheckpoint2(ids, flags);
    }

    function test_BatchReleaseDefault_RevertsAboveMaxBatchSize() external {
        uint256 max = escrow.MAX_BATCH_SIZE();
        uint256[] memory ids = new uint256[](max + 1);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.BatchTooLarge.selector);
        escrow.batchReleaseDefault(ids);
    }
}
