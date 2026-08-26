// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {AmlHook} from "contracts/hooks/AmlHook.sol";
import {AmlHookSettlement} from "contracts/hooks/AmlHookSettlement.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {FeeEscrow} from "contracts/escrow/FeeEscrow.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {Roles} from "libraries/Roles.sol";
import {MockFeeToken} from "../../../script/mocks/MockFeeToken.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice FEE_OVERRIDE afterSwap path: take differential → FeeEscrow.deposit.
contract UnitAmlHookFeeEscrowTest is Helpers {
    MockFeeToken feeToken;
    FeeEscrow escrow;
    PoolKey key;
    SwapParams params;

    event RiskFeeEscrowed(
        address indexed wallet, address indexed token, uint256 amount, uint256 escrowId, uint24 feeBps
    );

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();

        feeToken = new MockFeeToken();
        escrow = new FeeEscrow(owner, address(feeToken), owner, makeAddr("complianceReserve"), owner);

        hook = _deployHook(
            accessManager, sanctionRegistry, complianceOracle, riskPolicy, IFeeEscrow(address(escrow))
        );

        vm.startPrank(owner);
        escrow.bootstrapDepositor(address(hook));
        escrow.setAuditor(address(this), true);
        escrow.setComplianceSources(sanctionRegistry, complianceOracle);
        vm.stopPrank();

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        _wireHookGovernor();
        _bindUsdFeeds();

        // zeroForOne exactIn → output is currency1 = feeToken (escrow custody asset).
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(feeToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function test_AfterSwap_FeeOverride_DepositsDifferentialIntoEscrow() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        // Output basis = 1e18 → differential 770 bps → 7.7e16
        int128 amount0 = -1e18;
        int128 amount1 = 1e18;
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        uint256 expectedFee = (uint256(uint128(amount1)) * 770) / 10_000;

        feeToken.mint(address(manager), expectedFee);

        address sender = _bindTrustedSubject(walletB);
        (,, uint24 lpFee) = manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        assertEq(lpFee, 0);

        vm.expectEmit(true, true, false, true, address(hook));
        emit RiskFeeEscrowed(walletB, address(feeToken), expectedFee, 1, 800);

        (bytes4 sel, int128 hookDelta) =
            manager.callAfterSwap(IHooks(address(hook)), sender, key, params, delta, "");

        assertEq(sel, hook.afterSwap.selector);
        assertEq(uint256(uint128(hookDelta)), expectedFee);
        assertEq(feeToken.balanceOf(address(escrow)), expectedFee);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(1);
        assertEq(rec.wallet, walletB);
        assertEq(rec.amount, expectedFee);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Active));
    }

    function test_AfterSwap_FeeOverride_FingerprintIncludesNonce() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        int128 amount0 = -1e18;
        int128 amount1 = 1e18;
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        uint256 expectedFee = (uint256(uint128(amount1)) * 770) / 10_000;

        address sender = _bindTrustedSubject(walletB);

        feeToken.mint(address(manager), expectedFee);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        manager.callAfterSwap(IHooks(address(hook)), sender, key, params, delta, "");

        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSigN(walletB, 65, 1, walletA, 800, 1));

        feeToken.mint(address(manager), expectedFee);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        manager.callAfterSwap(IHooks(address(hook)), sender, key, params, delta, "");

        bytes32 fp1 = escrow.getEscrow(1).swapFingerprint;
        bytes32 fp2 = escrow.getEscrow(2).swapFingerprint;
        assertTrue(fp1 != fp2);
    }

    function test_AfterSwap_Allow_SkipsEscrow() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, _scoreSig(walletC, 0, 0));

        feeToken.mint(address(manager), 1e18);
        address sender = _bindTrustedSubject(walletC);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");

        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), sender, key, params, toBalanceDelta(-1e18, 1e18), ""
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
        assertEq(feeToken.balanceOf(address(manager)), 1e18);
    }

    function test_AfterSwap_FeeOverride_SkipsWhenCurrencyMismatch() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        // Output is currency0 (oneForZero), not the escrow feeToken.
        SwapParams memory oneForZero =
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, oneForZero, "");

        feeToken.mint(address(manager), 1e18);
        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), sender, key, oneForZero, toBalanceDelta(1e18, -1e18), ""
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
    }

    function test_AfterSwap_FeeOverride_AtOrBelowStandardFee_TakesZeroDifferential() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 30, _scoreSig(walletB, 65, 1, walletA, 30));

        feeToken.mint(address(manager), 1e18);
        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");

        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), sender, key, params, toBalanceDelta(-1e18, 1e18), ""
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
        assertEq(feeToken.balanceOf(address(manager)), 1e18);
    }

    function test_AfterSwap_FeeOverride_BelowStandardFee_TakesZeroDifferential() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 20, _scoreSig(walletB, 65, 1, walletA, 20));

        feeToken.mint(address(manager), 1e18);
        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");

        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), sender, key, params, toBalanceDelta(-1e18, 1e18), ""
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
    }

    function test_AfterSwap_FeeOverride_ExactOut_DepositsOnInputCurrency() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        // exactOut oneForZero: input is currency1 = feeToken.
        SwapParams memory exactOut =
            SwapParams({zeroForOne: false, amountSpecified: int256(1e18), sqrtPriceLimitX96: 0});
        int128 amount0 = 1e18; // output
        int128 amount1 = -1e18; // input owed
        uint256 expectedFee = (uint256(uint128(1e18)) * 770) / 10_000;
        feeToken.mint(address(manager), expectedFee);

        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, exactOut, "");

        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), sender, key, exactOut, toBalanceDelta(amount0, amount1), ""
        );

        assertEq(uint256(uint128(hookDelta)), expectedFee);
        assertEq(feeToken.balanceOf(address(escrow)), expectedFee);
    }

    event RiskFeeSkipped(address indexed wallet, address indexed token, uint24 feeBps, string reason);
    event FailedDepositRecorded(address indexed wallet, address indexed token, uint256 amount);
    event FailedDepositClaimed(address indexed wallet, address indexed token, uint256 amount);
    event FailedDepositRetried(
        address indexed wallet, address indexed token, uint256 amount, uint256 escrowId
    );

    function _revokeHookDepositor() internal {
        vm.startPrank(owner);
        escrow.setDepositor(address(hook), false);
        vm.warp(block.timestamp + escrow.DEPOSITOR_TIMELOCK());
        escrow.applyDepositor();
        vm.stopPrank();
    }

    function _grantHookDepositor() internal {
        vm.startPrank(owner);
        escrow.setDepositor(address(hook), true);
        vm.warp(block.timestamp + escrow.DEPOSITOR_TIMELOCK());
        escrow.applyDepositor();
        vm.stopPrank();
    }

    function _feeOverrideSwapThatFailsDeposit() internal returns (uint256 expectedFee) {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        expectedFee = (uint256(uint128(1e18)) * 770) / 10_000;
        feeToken.mint(address(manager), expectedFee);

        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        manager.callAfterSwap(
            IHooks(address(hook)), sender, key, params, toBalanceDelta(-1e18, 1e18), ""
        );
    }

    function test_AfterSwap_DepositFailed_RecordsFailedDeposit() external {
        _revokeHookDepositor();
        uint256 expectedFee = _feeOverrideSwapThatFailsDeposit();

        assertEq(hook.failedDeposits(walletB, address(feeToken)), expectedFee);
        assertEq(feeToken.balanceOf(address(hook)), expectedFee);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
    }

    function test_ClaimFailedDeposit_ReturnsTokensToSubject() external {
        _revokeHookDepositor();
        uint256 expectedFee = _feeOverrideSwapThatFailsDeposit();

        // M-02: governor must approve before the subject can claim.
        vm.prank(hookGovernor);
        hook.approveFailedDepositRefund(walletB, address(feeToken), true);

        vm.expectEmit(true, true, false, true, address(hook));
        emit FailedDepositClaimed(walletB, address(feeToken), expectedFee);

        vm.prank(walletB);
        hook.claimFailedDeposit(address(feeToken));

        assertEq(hook.failedDeposits(walletB, address(feeToken)), 0);
        assertEq(feeToken.balanceOf(walletB), expectedFee);
        assertEq(feeToken.balanceOf(address(hook)), 0);
        // Approval is consumed (single-use).
        assertEq(hook.failedDepositRefundApproved(walletB, address(feeToken)), false);
    }

    function test_ClaimFailedDeposit_RevertsWithoutApproval() external {
        _revokeHookDepositor();
        _feeOverrideSwapThatFailsDeposit();

        vm.prank(walletB);
        vm.expectRevert(AmlHookSettlement.RefundNotApproved.selector);
        hook.claimFailedDeposit(address(feeToken));
    }

    function test_ClaimFailedDeposit_RevertsWhenNone() external {
        // Approval is granted but there is nothing to claim.
        vm.prank(hookGovernor);
        hook.approveFailedDepositRefund(walletB, address(feeToken), true);

        vm.prank(walletB);
        vm.expectRevert(AmlHookSettlement.NoFailedDeposit.selector);
        hook.claimFailedDeposit(address(feeToken));
    }

    function test_ApproveFailedDepositRefund_RevertsForStranger() external {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        vm.prank(stranger);
        hook.approveFailedDepositRefund(walletB, address(feeToken), true);
    }

    function test_ApproveFailedDepositRefund_RevokesClearsApproval() external {
        _revokeHookDepositor();
        _feeOverrideSwapThatFailsDeposit();

        vm.prank(hookGovernor);
        hook.approveFailedDepositRefund(walletB, address(feeToken), true);
        assertEq(hook.failedDepositRefundApproved(walletB, address(feeToken)), true);

        // Governor revokes before the subject claims.
        vm.prank(hookGovernor);
        hook.approveFailedDepositRefund(walletB, address(feeToken), false);
        assertEq(hook.failedDepositRefundApproved(walletB, address(feeToken)), false);

        // Subject can no longer claim.
        vm.prank(walletB);
        vm.expectRevert(AmlHookSettlement.RefundNotApproved.selector);
        hook.claimFailedDeposit(address(feeToken));
    }

    function test_RetryEscrowDeposit_ReplaysOnceEscrowAccepts() external {
        _revokeHookDepositor();
        uint256 expectedFee = _feeOverrideSwapThatFailsDeposit();
        _grantHookDepositor();

        vm.expectEmit(true, true, false, true, address(hook));
        emit FailedDepositRetried(walletB, address(feeToken), expectedFee, 1);

        // L-02: only the subject (walletB) may retry their own deposit.
        vm.prank(walletB);
        hook.retryEscrowDeposit(walletB, address(feeToken));

        assertEq(hook.failedDeposits(walletB, address(feeToken)), 0);
        assertEq(feeToken.balanceOf(address(escrow)), expectedFee);
        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(1);
        assertEq(rec.wallet, walletB);
        assertEq(rec.amount, expectedFee);
    }

    function test_RetryEscrowDeposit_RevertsWhenCallerIsNotSubject() external {
        _revokeHookDepositor();
        _feeOverrideSwapThatFailsDeposit();
        _grantHookDepositor();

        vm.expectRevert(AmlHookSettlement.Unauthorized.selector);
        hook.retryEscrowDeposit(walletB, address(feeToken)); // msg.sender is test contract, not walletB
    }

    function test_FeeOverrideDeposit_ThenBlockedRecoverGoesToReserve() external {
        address reserve = escrow.complianceReserve();
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        uint256 expectedFee = (uint256(uint128(1e18)) * 770) / 10_000;
        feeToken.mint(address(manager), expectedFee);
        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        manager.callAfterSwap(
            IHooks(address(hook)), sender, key, params, toBalanceDelta(-1e18, 1e18), ""
        );

        assertEq(escrow.getEscrow(1).wallet, walletB);
        assertEq(uint8(escrow.getEscrow(1).status), uint8(IFeeEscrow.EscrowStatus.Active));

        vm.startPrank(owner);
        escrow.setKeeper(keeper, true);
        vm.warp(block.timestamp + escrow.KEEPER_TIMELOCK());
        escrow.applyKeeper();
        vm.stopPrank();

        vm.warp(block.timestamp + 48 hours);
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 71, 1, walletA, 800, _scoreSigN(walletB, 71, 1, walletA, 800, 1));
        vm.prank(keeper);
        escrow.resolveCheckpoint2(1);
        assertEq(uint8(escrow.getEscrow(1).status), uint8(IFeeEscrow.EscrowStatus.Blocked));

        uint256 ownerDelay = uint256(escrow.blockedRecoveryDelay()) > uint256(escrow.OWNER_BLOCKED_RECOVERY_MIN_AGE())
            ? uint256(escrow.blockedRecoveryDelay())
            : uint256(escrow.OWNER_BLOCKED_RECOVERY_MIN_AGE());
        vm.warp(block.timestamp + ownerDelay);
        vm.prank(owner);
        escrow.recoverBlocked(1);

        assertEq(uint8(escrow.getEscrow(1).status), uint8(IFeeEscrow.EscrowStatus.Recovered));
        assertEq(feeToken.balanceOf(reserve), expectedFee);
        assertEq(feeToken.balanceOf(owner), 0);
    }

    function test_RetryEscrowDeposit_RevertsWhenCauseUnresolved() external {
        _revokeHookDepositor();
        _feeOverrideSwapThatFailsDeposit();

        vm.prank(walletB);
        vm.expectRevert(AmlHookSettlement.RetryEscrowFailed.selector);
        hook.retryEscrowDeposit(walletB, address(feeToken));
        assertTrue(hook.failedDeposits(walletB, address(feeToken)) > 0);
    }
}

/// @notice FEE_OVERRIDE with feeEscrow disabled (separate suite: hook address is etched once).
contract UnitAmlHookFeeEscrowDisabledTest is Helpers {
    MockFeeToken feeToken;
    PoolKey key;
    SwapParams params;

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        feeToken = new MockFeeToken();

        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        _wireHookGovernor();

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(feeToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function test_AfterSwap_FeeOverride_SkipsWhenFeeEscrowDisabled() external {
        assertEq(address(hook.feeEscrow()), address(0));

        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));
        feeToken.mint(address(manager), 1e18);

        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), sender, key, params, toBalanceDelta(-1e18, 1e18), ""
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(manager)), 1e18);
    }
}

/// @dev ERC-20 that returns false on approve(0), so the settlement reset is fail-closed.
contract ApproveFalseOnZeroToken {
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (amount == 0) return false;
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

/// @notice Isolated suite: hook address is etched once, so approve(0) needs its own deploy.
contract UnitAmlHookApproveZeroRevertsTest is Helpers {
    ApproveFalseOnZeroToken feeToken;
    FeeEscrow escrow;
    PoolKey key;
    SwapParams params;

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        feeToken = new ApproveFalseOnZeroToken();
        escrow = new FeeEscrow(owner, address(feeToken), owner, makeAddr("complianceReserve"), owner);

        hook = _deployHook(
            accessManager, sanctionRegistry, complianceOracle, riskPolicy, IFeeEscrow(address(escrow))
        );

        vm.prank(owner);
        escrow.bootstrapDepositor(address(hook));

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        _wireHookGovernor();
        _bindUsdFeeds();

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(feeToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function test_AfterSwap_FeeOverride_RevertsWhenApproveZeroReturnsFalse() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        uint256 expectedFee = (uint256(uint128(1e18)) * 770) / 10_000;
        feeToken.mint(address(manager), expectedFee);

        address sender = _bindTrustedSubject(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");

        vm.expectRevert(AmlHookSettlement.FeeApproveFailed.selector);
        manager.callAfterSwap(
            IHooks(address(hook)), sender, key, params, toBalanceDelta(-1e18, 1e18), ""
        );
    }
}
