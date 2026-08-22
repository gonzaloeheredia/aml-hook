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
    address reserve = address(0xC0DE);

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
        escrow = new FeeEscrow(owner, address(token), fund, reserve, owner);

        vm.startPrank(owner);
        escrow.setKeeper(keeper, true);
        escrow.setAuditor(address(this), true);
        escrow.setDepositor(depositor, true);
        vm.warp(block.timestamp + escrow.KEEPER_TIMELOCK());
        escrow.applyKeeper();
        escrow.applyDepositor();
        vm.stopPrank();

        token.mint(depositor, 1_000_000 ether);
        vm.prank(depositor);
        token.approve(address(escrow), type(uint256).max);
    }

    function _deposit(uint256 amount) internal returns (uint256 id) {
        vm.prank(depositor);
        id = escrow.deposit(walletA, address(token), ORIGIN_TX, amount);
    }

    function test_ConstructorSetsRolesAndRecipients() external view {
        assertEq(escrow.owner(), owner);
        assertTrue(escrow.keepers(owner));
        assertTrue(escrow.keepers(keeper));
        assertTrue(escrow.depositors(depositor));
        assertEq(address(escrow.feeToken()), address(token));
        assertEq(escrow.lpCompensationFund(), fund);
        assertEq(escrow.complianceReserve(), reserve);
        assertTrue(escrow.complianceReserve() != escrow.lpCompensationFund());
        assertEq(escrow.bootstrapper(), owner);
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
        assertEq(rec.token, address(token));
        assertEq(rec.amount, amount);
        assertEq(rec.depositedAt, t0);
        assertEq(rec.swapFingerprint, ORIGIN_TX);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Active));
        assertEq(escrow.balances(walletA, address(token)), amount);
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
        assertEq(escrow.balances(walletA, address(token)), 0);
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
        escrow.deposit(walletA, address(token), ORIGIN_TX, 10 ether);
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
        new FeeEscrow(address(0), address(token), fund, reserve, owner);

        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        new FeeEscrow(owner, address(0), fund, reserve, owner);

        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        new FeeEscrow(owner, address(token), address(0), reserve, owner);

        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        new FeeEscrow(owner, address(token), fund, address(0), owner);

        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        new FeeEscrow(owner, address(token), fund, reserve, address(0));
    }

    function test_Constructor_RevertsWhenDestinationsCollide() external {
        vm.expectRevert(FeeEscrow.DestinationsMustDiffer.selector);
        new FeeEscrow(owner, address(token), fund, fund, owner);
    }

    function test_Deposit_RevertsOnZeroWalletOrAmount() external {
        vm.startPrank(depositor);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.deposit(address(0), address(token), ORIGIN_TX, 1 ether);

        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.deposit(walletA, address(0), ORIGIN_TX, 1 ether);

        vm.expectRevert(FeeEscrow.ZeroAmount.selector);
        escrow.deposit(walletA, address(token), ORIGIN_TX, 0);
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
        vm.startPrank(owner);
        escrow.setKeeper(extra, true);
        assertFalse(escrow.keepers(extra));
        vm.warp(block.timestamp + escrow.KEEPER_TIMELOCK());
        escrow.applyKeeper();
        assertTrue(escrow.keepers(extra));

        escrow.setKeeper(extra, false);
        vm.stopPrank();
        assertFalse(escrow.keepers(extra));
    }

    function test_ApplyKeeper_RevertsBeforeTimelock() external {
        vm.prank(owner);
        escrow.setKeeper(makeAddr("soonKeeper"), true);
        vm.prank(owner);
        vm.expectRevert(FeeEscrow.KeeperTimelockPending.selector);
        escrow.applyKeeper();
    }

    function test_SetKeeper_RevokeCancelsPendingGrant() external {
        address extra = makeAddr("pendingThenRevoked");
        vm.startPrank(owner);
        escrow.setKeeper(extra, true);
        escrow.setKeeper(extra, false);
        vm.warp(block.timestamp + escrow.KEEPER_TIMELOCK());
        vm.expectRevert(FeeEscrow.NoPendingKeeper.selector);
        escrow.applyKeeper();
        vm.stopPrank();
        assertFalse(escrow.keepers(extra));
    }

    function test_BootstrapDepositor_GrantsImmediatelyOnce() external {
        address hookAddr = makeAddr("hookDepositor");
        FeeEscrow fresh = new FeeEscrow(owner, address(token), fund, reserve, owner);

        vm.prank(owner);
        fresh.bootstrapDepositor(hookAddr);
        assertTrue(fresh.depositors(hookAddr));
        assertTrue(fresh.depositorBootstrapped());
        assertEq(fresh.bootstrapper(), address(0));

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.DepositorAlreadyBootstrapped.selector);
        fresh.bootstrapDepositor(makeAddr("second"));

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.bootstrapDepositor(stranger);
    }

    function test_BootstrapDepositor_DeployerEoaCannotKeepOwnerPowers() external {
        address gov = makeAddr("safe");
        address deployerEoa = makeAddr("deployerEoa");
        address hookAddr = makeAddr("hookDepositor");
        FeeEscrow fresh = new FeeEscrow(gov, address(token), fund, reserve, deployerEoa);

        assertEq(fresh.owner(), gov);
        assertEq(fresh.bootstrapper(), deployerEoa);
        assertFalse(fresh.keepers(deployerEoa));
        assertFalse(fresh.depositors(deployerEoa));

        vm.prank(deployerEoa);
        fresh.bootstrapDepositor(hookAddr);
        assertEq(fresh.bootstrapper(), address(0));
        assertTrue(fresh.depositors(hookAddr));

        vm.prank(deployerEoa);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        fresh.setLpCompensationFund(fund);

        vm.prank(deployerEoa);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        fresh.recoverBlocked(1);
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
        vm.startPrank(owner);
        escrow.setDepositor(extra, true);
        vm.warp(block.timestamp + escrow.DEPOSITOR_TIMELOCK());
        escrow.applyDepositor();
        assertTrue(escrow.depositors(extra));

        escrow.setDepositor(extra, false);
        vm.warp(block.timestamp + escrow.DEPOSITOR_TIMELOCK());
        escrow.applyDepositor();
        vm.stopPrank();
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

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.DestinationsMustDiffer.selector);
        escrow.setLpCompensationFund(reserve);
    }

    function test_SetComplianceReserve() external {
        address nextReserve = makeAddr("nextReserve");
        vm.prank(owner);
        escrow.setComplianceReserve(nextReserve);
        assertEq(escrow.complianceReserve(), nextReserve);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.setComplianceReserve(reserve);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.setComplianceReserve(address(0));

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.DestinationsMustDiffer.selector);
        escrow.setComplianceReserve(fund);
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
        uint256 indexed escrowId,
        address indexed wallet,
        address indexed to,
        address token,
        uint256 amount,
        bytes32 swapFingerprint
    );

    function test_RecoverBlocked_OwnerCanRecoverToComplianceReserve() external {
        uint256 amount = 30 ether;
        uint256 id = _blockedEscrow(amount);
        vm.warp(block.timestamp + escrow.OWNER_BLOCKED_RECOVERY_MIN_AGE());

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FeeRecovered(id, walletA, reserve, address(token), amount, ORIGIN_TX);

        vm.prank(owner);
        escrow.recoverBlocked(id);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(id);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Recovered));
        assertEq(token.balanceOf(reserve), amount);
        assertEq(token.balanceOf(fund), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_RecoverBlocked_RevertsBeforeMinDelay() external {
        uint256 id = _blockedEscrow(10 ether);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.BlockedRecoveryTooEarly.selector);
        escrow.recoverBlocked(id);

        vm.warp(block.timestamp + escrow.OWNER_BLOCKED_RECOVERY_MIN_AGE() - 1);
        vm.prank(owner);
        vm.expectRevert(FeeEscrow.BlockedRecoveryTooEarly.selector);
        escrow.recoverBlocked(id);
    }

    function test_RecoverBlocked_RevertsForNonOwner() external {
        uint256 id = _blockedEscrow(10 ether);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.NotOwner.selector);
        escrow.recoverBlocked(id);
    }

    function test_RecoverBlocked_RevertsIfNotBlocked() external {
        uint256 id = _deposit(10 ether);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.NotBlocked.selector);
        escrow.recoverBlocked(id);
    }

    function test_RecoverBlocked_CannotBeCalledTwice() external {
        uint256 id = _blockedEscrow(10 ether);
        vm.warp(block.timestamp + escrow.OWNER_BLOCKED_RECOVERY_MIN_AGE());

        vm.prank(owner);
        escrow.recoverBlocked(id);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.NotBlocked.selector);
        escrow.recoverBlocked(id);
    }

    /*///////////////////////////////////////////////////////////////
                        BATCH SIZE LIMIT (L-2)
    //////////////////////////////////////////////////////////////*/

    function test_BatchReleaseEarly_RevertsAboveMaxBatchSize() external {
        uint256[] memory ids = new uint256[](101);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.BatchTooLarge.selector);
        escrow.batchReleaseEarly(ids);
    }

    function test_BatchResolveCheckpoint2_RevertsAboveMaxBatchSize() external {
        uint256[] memory ids = new uint256[](101);
        bool[] memory flags = new bool[](101);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.BatchTooLarge.selector);
        escrow.batchResolveCheckpoint2(ids, flags);
    }

    function test_BatchReleaseDefault_RevertsAboveMaxBatchSize() external {
        uint256[] memory ids = new uint256[](101);

        vm.prank(keeper);
        vm.expectRevert(FeeEscrow.BatchTooLarge.selector);
        escrow.batchReleaseDefault(ids);
    }

    function test_GetEscrow_RevertsForStranger() external {
        uint256 id = _deposit(1 ether);
        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.UnauthorizedEscrowRead.selector);
        escrow.getEscrow(id);
    }

    function test_RecoverExpiredBlocked_AfterDelay() external {
        uint256 id = _blockedEscrow(8 ether);
        vm.prank(owner);
        escrow.setBlockedRecoveryDelay(1 days);

        vm.prank(stranger);
        vm.expectRevert(FeeEscrow.BlockedRecoveryTooEarly.selector);
        escrow.recoverExpiredBlocked(id);

        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        escrow.recoverExpiredBlocked(id);
        assertEq(token.balanceOf(reserve), 8 ether);
        assertEq(token.balanceOf(fund), 0);
    }

    function test_RecoverBlocked_UsesMinOfOwnerFloorAndConfiguredDelay() external {
        uint256 id = _blockedEscrow(4 ether);
        vm.prank(owner);
        escrow.setBlockedRecoveryDelay(1 days);

        vm.prank(owner);
        vm.expectRevert(FeeEscrow.BlockedRecoveryTooEarly.selector);
        escrow.recoverBlocked(id);

        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        escrow.recoverBlocked(id);
        assertEq(token.balanceOf(reserve), 4 ether);
        assertEq(token.balanceOf(fund), 0);
    }

    function test_BlockedRecovery_NeverCreditsLpFund() external {
        uint256 ownerAmount = 11 ether;
        uint256 expiredAmount = 9 ether;
        uint256 ownerId = _deposit(ownerAmount);
        uint256 expiredId = _deposit(expiredAmount);

        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(keeper);
        escrow.resolveCheckpoint2(ownerId, true);
        escrow.resolveCheckpoint2(expiredId, true);
        vm.stopPrank();

        vm.prank(owner);
        escrow.setBlockedRecoveryDelay(1 days);
        vm.warp(block.timestamp + 1 days);

        vm.prank(owner);
        escrow.recoverBlocked(ownerId);
        vm.prank(stranger);
        escrow.recoverExpiredBlocked(expiredId);

        assertEq(token.balanceOf(reserve), ownerAmount + expiredAmount);
        assertEq(token.balanceOf(fund), 0);
        assertEq(token.balanceOf(pool), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_UpdatedComplianceReserve_UsedOnRecoverBlocked() external {
        address nextReserve = makeAddr("nextReserve");
        uint256 amount = 6 ether;
        uint256 id = _blockedEscrow(amount);

        vm.prank(owner);
        escrow.setComplianceReserve(nextReserve);
        vm.warp(block.timestamp + escrow.OWNER_BLOCKED_RECOVERY_MIN_AGE());
        vm.prank(owner);
        escrow.recoverBlocked(id);

        assertEq(token.balanceOf(nextReserve), amount);
        assertEq(token.balanceOf(reserve), 0);
        assertEq(token.balanceOf(fund), 0);
    }

    function test_ApplyDepositor_RevertsBeforeTimelock() external {
        vm.prank(owner);
        escrow.setDepositor(makeAddr("soon"), true);
        vm.prank(owner);
        vm.expectRevert(FeeEscrow.DepositorTimelockPending.selector);
        escrow.applyDepositor();
    }

    function test_GetEscrowPublic_HashesWallet() external {
        uint256 id = _deposit(2 ether);
        (bytes32 walletHash, address recToken, uint256 amount, uint64 depositedAt, bytes32 fingerprint, IFeeEscrow.EscrowStatus status,)
            = escrow.getEscrowPublic(id);

        assertEq(walletHash, keccak256(abi.encodePacked(walletA)));
        assertEq(recToken, address(token));
        assertEq(amount, 2 ether);
        assertEq(depositedAt, uint64(block.timestamp));
        assertEq(fingerprint, ORIGIN_TX);
        assertEq(uint8(status), uint8(IFeeEscrow.EscrowStatus.Active));
    }

    function test_Balances_AreIndependentPerWalletAndToken() external {
        FeeToken tokenB = new FeeToken();
        vm.prank(owner);
        escrow.setAllowedFeeToken(address(tokenB), true);

        tokenB.mint(depositor, 1_000 ether);
        vm.prank(depositor);
        tokenB.approve(address(escrow), type(uint256).max);

        vm.prank(depositor);
        uint256 idA = escrow.deposit(walletA, address(token), ORIGIN_TX, 10 ether);
        vm.prank(depositor);
        uint256 idB = escrow.deposit(walletA, address(tokenB), ORIGIN_TX, 7 ether);
        vm.prank(depositor);
        escrow.deposit(walletB, address(token), ORIGIN_TX, 3 ether);

        assertEq(escrow.balances(walletA, address(token)), 10 ether);
        assertEq(escrow.balances(walletA, address(tokenB)), 7 ether);
        assertEq(escrow.balances(walletB, address(token)), 3 ether);
        assertEq(escrow.balances(walletB, address(tokenB)), 0);

        assertEq(escrow.getEscrow(idA).token, address(token));
        assertEq(escrow.getEscrow(idB).token, address(tokenB));

        vm.warp(block.timestamp + 30 hours);
        vm.prank(keeper);
        escrow.releaseEarly(idA);

        assertEq(escrow.balances(walletA, address(token)), 0);
        assertEq(escrow.balances(walletA, address(tokenB)), 7 ether);
        assertEq(token.balanceOf(fund), 10 ether);
        assertEq(tokenB.balanceOf(address(escrow)), 7 ether);
        assertEq(tokenB.balanceOf(fund), 0);
    }

    function test_Deposit_RevertsWhenTokenNotAllowed() external {
        FeeToken other = new FeeToken();
        other.mint(depositor, 1 ether);
        vm.prank(depositor);
        other.approve(address(escrow), 1 ether);

        vm.prank(depositor);
        vm.expectRevert(FeeEscrow.FeeTokenNotAllowed.selector);
        escrow.deposit(walletA, address(other), ORIGIN_TX, 1 ether);
    }
}
