// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {IComplianceTreasury} from "../../interfaces/treasury/IComplianceTreasury.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Minimal ERC-20 surface for approving FeeEscrow.deposit's transferFrom.
interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title FEE_OVERRIDE take + LP seize into FeeEscrow (§3.7 / §8.3)
/// @notice Pool-accounting half of the hook: Uniswap `take` / approve / `deposit`.
/// @dev Compliance decisions live in `AmlHookLogic`. Fee *math* lives in `FeeBps`.
///      Swap FEE_OVERRIDE deposits the differential (`EscrowKind.RiskFee`). LP add
///      deposits the full 3%/8% override. A blocked remove deposits principal
///      (`LpPrincipal`) and `feesAccrued` (`RiskFee`) for 48h. Settlement does not credit the treasury in-tx.
abstract contract AmlHookSettlement is BaseHook, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    /// @notice Pool base fee in bps (0.30%): left to the PoolManager; not overridden.
    uint24 public constant STANDARD_FEE_BPS = FeeBps.STANDARD;

    /// @notice Escrow for FEE_OVERRIDE differential fees (§3.7). address(0) disables take/deposit.
    IFeeEscrow public feeEscrow;
    /// @notice Ledged compliance fund. address(0) skips recover notify; seize still escrows the LP delta.
    IComplianceTreasury public complianceTreasury;
    /// @notice Next seize id assigned on a blocked LP exit (starts at 1).
    uint256 public nextSeizeId = 1;

    /// @notice Emitted when the risk differential was taken and deposited into FeeEscrow.
    event RiskFeeEscrowed(
        address indexed wallet, address indexed token, uint256 amount, uint256 escrowId, uint24 feeBps
    );

    /// @notice Emitted when the risk fee is not taken (zero basis or escrow token mismatch).
    event RiskFeeSkipped(address indexed wallet, address indexed token, uint24 feeBps, string reason);

    /// @notice Tokens taken from the pool whose `FeeEscrow.deposit` failed (C-04 follow-up).
    event FailedDepositRecorded(address indexed wallet, address indexed token, uint256 amount);
    event FailedDepositClaimed(address indexed wallet, address indexed token, uint256 amount);
    event FailedDepositRetried(
        address indexed wallet, address indexed token, uint256 amount, uint256 escrowId
    );
    /// @notice Blocked LP exit: the LP received nothing in this tx. Principal and fees → FeeEscrow 48h.
    event LpExitSeized(
        uint256 indexed seizeId,
        address indexed wallet,
        bytes32 poolId,
        bytes32 positionKey,
        uint256 principal0,
        uint256 principal1,
        uint256 fee0,
        uint256 fee1
    );

    error FeeTransferFailed();
    error FeeApproveFailed();
    error NoFailedDeposit();
    error RetryEscrowFailed();
    error FeeEscrowNotConfigured();
    error RefundNotApproved();
    error Unauthorized();

    /// @notice Taken-but-not-escrowed differential, keyed by compliance subject and token.
    mapping(address => mapping(address => uint256)) public failedDeposits;

    /// @notice Compliance-officer approval for a subject to claim their failed deposit.
    /// @dev M-02 fix: subjects cannot self-recover without an explicit per-(wallet, token) approval
    ///      from the hook governor. Approval is consumed on claim (single-use).
    mapping(address => mapping(address => bool)) public failedDepositRefundApproved;

    /// @dev Extra entropy mixed into `swapFingerprint` (L-01), on top of `nextEscrowId`.
    uint256 private _fingerprintNonce;

    /// @param poolManager_ Uniswap v4 PoolManager (BaseHook).
    constructor(IPoolManager poolManager_) BaseHook(poolManager_) {}

    /// @dev Called once by AmlHook.initialize. Sets FeeEscrow and the compliance treasury.
    function _initSettlement(IFeeEscrow feeEscrow_, IComplianceTreasury treasury_) internal {
        feeEscrow = feeEscrow_;
        complianceTreasury = treasury_;
    }

    /// @dev Take the full remove delta so the LP gets 0. Principal and feesAccrued → FeeEscrow (48h).
    function _seizeLpExit(
        address wallet,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued
    ) internal returns (BalanceDelta hookDelta) {
        uint256 fee0 = _pos(feesAccrued.amount0());
        uint256 fee1 = _pos(feesAccrued.amount1());
        uint256 out0 = _pos(delta.amount0());
        uint256 out1 = _pos(delta.amount1());
        uint256 prin0 = out0 > fee0 ? out0 - fee0 : 0;
        uint256 prin1 = out1 > fee1 ? out1 - fee1 : 0;

        if (out0 > 0) poolManager.take(key.currency0, address(this), out0);
        if (out1 > 0) poolManager.take(key.currency1, address(this), out1);

        uint256 seizeId = nextSeizeId++;
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 positionKey = keccak256(abi.encode(params.tickLower, params.tickUpper, params.salt));
        emit LpExitSeized(seizeId, wallet, poolId, positionKey, prin0, prin1, fee0, fee1);

        bytes32 fingerprint = keccak256(abi.encode(seizeId, poolId, positionKey));
        _escrowKind(wallet, Currency.unwrap(key.currency0), prin0, fingerprint, IFeeEscrow.EscrowKind.LpPrincipal);
        _escrowKind(wallet, Currency.unwrap(key.currency1), prin1, fingerprint, IFeeEscrow.EscrowKind.LpPrincipal);
        _escrowKind(wallet, Currency.unwrap(key.currency0), fee0, fingerprint, IFeeEscrow.EscrowKind.RiskFee);
        _escrowKind(wallet, Currency.unwrap(key.currency1), fee1, fingerprint, IFeeEscrow.EscrowKind.RiskFee);
        hookDelta = delta;
    }

    /// @dev Take `feeBps` of each token the LP just deposited (full override, not swap differential).
    function _escrowAddRiskFee(address wallet, PoolKey calldata key, BalanceDelta delta, uint24 feeBps)
        internal
        returns (BalanceDelta hookDelta)
    {
        uint256 a0 = _absInt(delta.amount0());
        uint256 a1 = _absInt(delta.amount1());
        uint256 f0 = FeeBps.overrideAmount(a0, feeBps);
        uint256 f1 = FeeBps.overrideAmount(a1, feeBps);
        if (f0 > 0) {
            poolManager.take(key.currency0, address(this), f0);
            _escrowKind(wallet, Currency.unwrap(key.currency0), f0, _buildFingerprint(wallet, Currency.unwrap(key.currency0), f0), IFeeEscrow.EscrowKind.RiskFee);
        }
        if (f1 > 0) {
            poolManager.take(key.currency1, address(this), f1);
            _escrowKind(wallet, Currency.unwrap(key.currency1), f1, _buildFingerprint(wallet, Currency.unwrap(key.currency1), f1), IFeeEscrow.EscrowKind.RiskFee);
        }
        if (f0 > uint256(uint128(type(int128).max)) || f1 > uint256(uint128(type(int128).max))) revert FeeTransferFailed();
        hookDelta = toBalanceDelta(int128(uint128(f0)), int128(uint128(f1)));
    }

    function _escrowKind(
        address wallet,
        address token,
        uint256 amount,
        bytes32 fingerprint,
        IFeeEscrow.EscrowKind kind
    ) private {
        if (amount == 0 || token == address(0) || address(feeEscrow) == address(0)) return;
        if (!feeEscrow.allowedFeeTokens(token)) {
            _recordFailedDeposit(wallet, token, amount, 0);
            return;
        }
        _approve(token, address(feeEscrow), amount);
        try feeEscrow.deposit(wallet, token, fingerprint, amount, kind) returns (uint256 escrowId) {
            emit RiskFeeEscrowed(wallet, token, amount, escrowId, 0);
        } catch {
            _recordFailedDeposit(wallet, token, amount, 0);
        }
    }

    function _absInt(int128 amount) private pure returns (uint256) {
        if (amount >= 0) return uint256(uint128(amount));
        return uint256(uint128(-amount));
    }

    function _pos(int128 amount) private pure returns (uint256) {
        return amount > 0 ? uint256(uint128(amount)) : 0;
    }

    function _approve(address token, address spender, uint256 amount) private {
        if (!IERC20Approve(token).approve(spender, 0)) revert FeeApproveFailed();
        if (!IERC20Approve(token).approve(spender, amount)) revert FeeApproveFailed();
    }

    /// @dev Take differential risk fee from the swap and deposit into FeeEscrow.
    ///      Follows Uniswap v4 afterSwap custom-accounting guide (unspecified currency).
    function _escrowRiskFee(
        address wallet,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint24 feeBps
    ) internal returns (int128 hookDelta) {
        if (FeeBps.differentialBps(feeBps) == 0) return 0;
        (Currency feeCurrency, int256 basisAmount) = _feeBasis(key, params, delta);
        hookDelta = _takeAndDeposit(wallet, feeCurrency, basisAmount, feeBps);
    }

    /// @dev Resolves token + amount from the Uniswap basis, then deposits. No PoolKey/SwapParams.
    function _takeAndDeposit(address wallet, Currency feeCurrency, int256 basisAmount, uint24 feeBps)
        private
        returns (int128)
    {
        address token = Currency.unwrap(feeCurrency);
        if (basisAmount <= 0) {
            _emitRiskFeeSkipped(wallet, token, feeBps, "ZERO_BASIS");
            return 0;
        }

        uint256 feeAmount = FeeBps.differentialAmount(uint256(basisAmount), feeBps);
        if (feeAmount == 0) return 0;
        if (feeAmount > uint256(uint128(type(int128).max))) revert FeeTransferFailed();

        if (!feeEscrow.allowedFeeTokens(token)) {
            _emitRiskFeeSkipped(wallet, token, feeBps, "FEE_TOKEN_NOT_ALLOWED");
            return 0;
        }

        _depositDifferential(wallet, token, feeCurrency, feeAmount, feeBps);
        return int128(int256(feeAmount));
    }

    /// @dev Interactions last (H-06): take → approve → deposit. No Uniswap swap types in this frame.
    function _depositDifferential(
        address wallet,
        address token,
        Currency feeCurrency,
        uint256 feeAmount,
        uint24 feeBps
    ) private {
        bytes32 swapFingerprint = _buildFingerprint(wallet, token, feeAmount);
        poolManager.take(feeCurrency, address(this), feeAmount);
        _approveEscrow(token, feeAmount);
        try feeEscrow.deposit(wallet, token, swapFingerprint, feeAmount) returns (uint256 escrowId) {
            emit RiskFeeEscrowed(wallet, token, feeAmount, escrowId, feeBps);
        } catch {
            _recordFailedDeposit(wallet, token, feeAmount, feeBps);
        }
    }

    /// @dev Unspecified-currency basis for the differential take (exactIn output / exactOut input).
    function _feeBasis(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        pure
        returns (Currency feeCurrency, int256 basisAmount)
    {
        if (params.amountSpecified < 0) {
            bool outputIsToken0 = !params.zeroForOne;
            feeCurrency = outputIsToken0 ? key.currency0 : key.currency1;
            basisAmount = outputIsToken0 ? delta.amount0() : delta.amount1();
            return (feeCurrency, basisAmount);
        }
        bool inputIsToken0 = params.zeroForOne;
        feeCurrency = inputIsToken0 ? key.currency0 : key.currency1;
        int256 inputDelta = inputIsToken0 ? delta.amount0() : delta.amount1();
        basisAmount = inputDelta < 0 ? -inputDelta : int256(0);
    }

    function _emitRiskFeeSkipped(address wallet, address token, uint24 feeBps, string memory reason)
        private
    {
        emit RiskFeeSkipped(wallet, token, feeBps, reason);
    }

    function _recordFailedDeposit(address wallet, address token, uint256 feeAmount, uint24 feeBps)
        private
    {
        failedDeposits[wallet][token] += feeAmount;
        emit FailedDepositRecorded(wallet, token, feeAmount);
        _emitRiskFeeSkipped(wallet, token, feeBps, "DEPOSIT_FAILED");
    }

    /// @notice Grant or revoke a subject's right to reclaim their failed deposit for `token`.
    /// @dev Restricted: call this from AmlHook (which has the `restricted` modifier from
    ///      AccessManaged) via `approveFailedDepositRefund`. Internal so it is callable
    ///      across the AmlHook diamond without a circular import.
    function _setFailedDepositRefundApproval(address wallet, address token, bool approved) internal {
        failedDepositRefundApproved[wallet][token] = approved;
    }

    /// @notice Subject recovers tokens that were taken but never reached FeeEscrow.
    /// @dev M-02 fix: requires prior governor approval via `approveFailedDepositRefund`.
    ///      Approval is single-use and consumed on claim to prevent double-withdrawal.
    function claimFailedDeposit(address token) external nonReentrant {
        if (!failedDepositRefundApproved[msg.sender][token]) revert RefundNotApproved();
        failedDepositRefundApproved[msg.sender][token] = false;
        uint256 amount = failedDeposits[msg.sender][token];
        if (amount == 0) revert NoFailedDeposit();
        failedDeposits[msg.sender][token] = 0;
        if (!IERC20Approve(token).transfer(msg.sender, amount)) revert FeeTransferFailed();
        emit FailedDepositClaimed(msg.sender, token, amount);
    }

    /// @dev Reset-then-set approve pattern for tokens that require allowance to go through 0 first.
    function _approveEscrow(address token, uint256 amount) private {
        if (!IERC20Approve(token).approve(address(feeEscrow), 0)) revert FeeApproveFailed();
        if (!IERC20Approve(token).approve(address(feeEscrow), amount)) revert FeeApproveFailed();
    }

    /// @dev Builds a unique fingerprint for a fee deposit, mixing block context and an incrementing
    ///      nonce (L-01) so two deposits for the same wallet/token/amount in the same block differ.
    function _buildFingerprint(address wallet, address token, uint256 amount) private returns (bytes32) {
        uint256 nonce = ++_fingerprintNonce;
        return keccak256(
            abi.encode(wallet, token, amount, block.number, block.timestamp, feeEscrow.nextEscrowId(), nonce)
        );
    }

    /// @notice Subject (wallet) may retry depositing their recorded failed amount into FeeEscrow.
    /// @dev L-02 fix: restricted to the subject themselves. Third parties cannot trigger an
    ///      `_approveEscrow` call on someone else's behalf, removing the approval-grief vector.
    function retryEscrowDeposit(address wallet, address token) external nonReentrant {
        if (msg.sender != wallet) revert Unauthorized();
        if (address(feeEscrow) == address(0)) revert FeeEscrowNotConfigured();
        uint256 amount = failedDeposits[wallet][token];
        if (amount == 0) revert NoFailedDeposit();
        if (!feeEscrow.allowedFeeTokens(token)) {
            revert RetryEscrowFailed();
        }

        failedDeposits[wallet][token] = 0;

        bytes32 swapFingerprint = _buildFingerprint(wallet, token, amount);

        _approveEscrow(token, amount);

        try feeEscrow.deposit(wallet, token, swapFingerprint, amount) returns (uint256 escrowId) {
            emit RiskFeeEscrowed(wallet, token, amount, escrowId, 0);
            emit FailedDepositRetried(wallet, token, amount, escrowId);
        } catch {
            _restoreFailedDeposit(wallet, token, amount);
        }
    }

    function _restoreFailedDeposit(address wallet, address token, uint256 amount) private {
        failedDeposits[wallet][token] = amount;
        revert RetryEscrowFailed();
    }
}
