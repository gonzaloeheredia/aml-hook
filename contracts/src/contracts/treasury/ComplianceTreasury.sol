// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IComplianceTreasury} from "../../interfaces/treasury/IComplianceTreasury.sol";

/// @dev Minimal ERC-20 surface used for principal pulls.
interface IERC20Treasury {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ComplianceTreasury — authority fund with two ledgers
/// @notice `LP_PRINCIPAL` is seized LP capital after a confirmed-illicit FeeEscrow recover
///         (the remove tx itself holds principal 48h in escrow). `ILLICIT_RISK_FEE` is a
///         risk-fee recover after Layer 1 or a later oracle illicit write. The two
///         accounts never share a credit path. The LP compensation fund is not this contract.
contract ComplianceTreasury is IComplianceTreasury {
    address public owner;
    address public pendingOwner;
    /// @notice One-shot deploy key allowed to call `setHook` / `setEscrow`. Cleared after both are set.
    address public bootstrapper;
    /// @notice Only the AML hook may credit seized principal.
    address public hook;
    /// @notice Only FeeEscrow may book a recovered illicit risk fee.
    address public escrow;

    mapping(Account => mapping(address => uint256)) public override balances;

    error NotOwner();
    error NotPendingOwner();
    error NotHook();
    error NotEscrow();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event HookUpdated(address indexed hook);
    event EscrowUpdated(address indexed escrow);

    /// @notice Seized LP principal booked on `LP_PRINCIPAL`.
    event PrincipalPosted(
        uint256 indexed seizeId,
        address indexed wallet,
        address indexed token,
        uint256 amount,
        bytes32 poolId,
        bytes32 positionKey
    );

    /// @notice Recovered illicit risk fee booked on `ILLICIT_RISK_FEE`.
    event ComplianceCredited(
        Account indexed account,
        address indexed wallet,
        address indexed token,
        uint256 amount,
        uint256 sourceId,
        bytes32 fingerprint
    );

    constructor(address owner_, address bootstrapper_) {
        if (owner_ == address(0) || bootstrapper_ == address(0)) revert ZeroAddress();
        owner = owner_;
        bootstrapper = bootstrapper_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrBootstrapper() {
        if (msg.sender != owner && msg.sender != bootstrapper) revert NotOwner();
        _;
    }

    function setHook(address hook_) external onlyOwnerOrBootstrapper {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookUpdated(hook_);
        _clearBootstrapperIfWired();
    }

    function setEscrow(address escrow_) external onlyOwnerOrBootstrapper {
        if (escrow_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        emit EscrowUpdated(escrow_);
        _clearBootstrapperIfWired();
    }

    function _clearBootstrapperIfWired() private {
        if (hook != address(0) && escrow != address(0)) bootstrapper = address(0);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @inheritdoc IComplianceTreasury
    function creditPrincipal(
        address wallet,
        address token,
        uint256 amount,
        uint256 seizeId,
        bytes32 poolId,
        bytes32 positionKey
    ) external {
        if (msg.sender != hook) revert NotHook();
        if (wallet == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!IERC20Treasury(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        balances[Account.LP_PRINCIPAL][token] += amount;
        emit PrincipalPosted(seizeId, wallet, token, amount, poolId, positionKey);
        emit ComplianceCredited(Account.LP_PRINCIPAL, wallet, token, amount, seizeId, positionKey);
    }

    /// @inheritdoc IComplianceTreasury
    /// @dev Tokens must already sit on this contract (FeeEscrow transferred first).
    function recordSeizedPrincipal(
        address wallet,
        address token,
        uint256 amount,
        uint256 escrowId,
        bytes32 fingerprint
    ) external {
        if (msg.sender != escrow) revert NotEscrow();
        if (wallet == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        balances[Account.LP_PRINCIPAL][token] += amount;
        emit PrincipalPosted(escrowId, wallet, token, amount, bytes32(0), fingerprint);
        emit ComplianceCredited(Account.LP_PRINCIPAL, wallet, token, amount, escrowId, fingerprint);
    }

    /// @inheritdoc IComplianceTreasury
    /// @dev Tokens must already sit on this contract (FeeEscrow transferred first).
    function recordIllicitFee(
        address wallet,
        address token,
        uint256 amount,
        uint256 escrowId,
        bytes32 fingerprint
    ) external {
        if (msg.sender != escrow) revert NotEscrow();
        if (wallet == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        balances[Account.ILLICIT_RISK_FEE][token] += amount;
        emit ComplianceCredited(Account.ILLICIT_RISK_FEE, wallet, token, amount, escrowId, fingerprint);
    }
}
