// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Minimal ERC-20 surface for approving FeeEscrow.deposit's transferFrom.
interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title FEE_OVERRIDE differential take + FeeEscrow deposit (§3.7)
/// @notice Pool-accounting half of the hook: Uniswap `take` / approve / `deposit`.
/// @dev Compliance decisions live in `AmlHookLogic`. Fee *math* lives in `FeeBps`.
///      This contract only moves the already-decided differential into escrow.
abstract contract AmlHookSettlement is BaseHook, ReentrancyGuard {
    /// @notice Pool base fee in bps (0.30%) — left to the PoolManager; not overridden.
    uint24 public constant STANDARD_FEE_BPS = FeeBps.STANDARD;

    /// @notice Escrow for FEE_OVERRIDE differential fees (§3.7). address(0) disables take/deposit.
    IFeeEscrow public immutable feeEscrow;

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
    /// @param feeEscrow_ Differential escrow; `address(0)` disables take / deposit.
    constructor(IPoolManager poolManager_, IFeeEscrow feeEscrow_) BaseHook(poolManager_) {
        feeEscrow = feeEscrow_;
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
        uint256 dBps = FeeBps.differentialBps(feeBps);
        if (dBps == 0) return 0;

        bool isExactIn = params.amountSpecified < 0;
        bool outputIsToken0 = !params.zeroForOne;

        // Fee is charged on the unspecified currency (guide): output for exactIn, input for exactOut.
        Currency feeCurrency;
        int256 basisAmount;
        if (isExactIn) {
            feeCurrency = outputIsToken0 ? key.currency0 : key.currency1;
            basisAmount = outputIsToken0 ? delta.amount0() : delta.amount1();
        } else {
            bool inputIsToken0 = params.zeroForOne;
            feeCurrency = inputIsToken0 ? key.currency0 : key.currency1;
            int256 inputDelta = inputIsToken0 ? delta.amount0() : delta.amount1();
            basisAmount = inputDelta < 0 ? -inputDelta : int256(0);
        }

        address token = Currency.unwrap(feeCurrency);
        if (basisAmount <= 0) {
            emit RiskFeeSkipped(wallet, token, feeBps, "ZERO_BASIS");
            return 0;
        }

        uint256 feeAmount = FeeBps.differentialAmount(uint256(basisAmount), feeBps);
        if (feeAmount == 0) return 0;
        if (feeAmount > uint256(uint128(type(int128).max))) revert FeeTransferFailed();

        // Effects complete. Interactions last (H-06): take → approve → deposit.
        if (!feeEscrow.allowedFeeTokens(token)) {
            emit RiskFeeSkipped(wallet, token, feeBps, "FEE_TOKEN_NOT_ALLOWED");
            return 0;
        }

        bytes32 swapFingerprint = _buildFingerprint(wallet, token, feeAmount);

        poolManager.take(feeCurrency, address(this), feeAmount);
        _approveEscrow(token, feeAmount);

        try feeEscrow.deposit(wallet, token, swapFingerprint, feeAmount) returns (uint256 escrowId) {
            emit RiskFeeEscrowed(wallet, token, feeAmount, escrowId, feeBps);
        } catch {
            failedDeposits[wallet][token] += feeAmount;
            emit FailedDepositRecorded(wallet, token, feeAmount);
            emit RiskFeeSkipped(wallet, token, feeBps, "DEPOSIT_FAILED");
        }
        return int128(int256(feeAmount));
    }

    /// @notice Grant or revoke a subject's right to reclaim their failed deposit for `token`.
    /// @dev Restricted — call this from AmlHook (which has the `restricted` modifier from
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
    /// @dev L-02 fix: restricted to the subject themselves — third parties cannot trigger an
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
            failedDeposits[wallet][token] = amount;
            revert RetryEscrowFailed();
        }
    }
}
