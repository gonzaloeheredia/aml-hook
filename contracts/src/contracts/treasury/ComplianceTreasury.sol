// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IComplianceTreasury} from "../../interfaces/treasury/IComplianceTreasury.sol";

/// @dev Minimal ERC-20 surface used for principal pulls and authority payouts.
interface IERC20Treasury {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ComplianceTreasury: authority fund with two ledgers
/// @notice `LP_PRINCIPAL` is seized LP capital after a confirmed-illicit FeeEscrow recover
///         (the remove tx itself holds principal 48h in escrow). `ILLICIT_RISK_FEE` is a
///         risk-fee recover after Layer 1 or a later oracle illicit write. The two
///         accounts never share a credit path. The LP compensation vault is not this
///         contract. Outflow is delayed, allowlisted, and booked by account.
contract ComplianceTreasury is IComplianceTreasury {
    /// @notice Delay after `proposePayout` before `executePayout` (same clock as officer grants).
    uint64 public constant PAYOUT_DELAY = 48 hours;

    address public owner;
    address public pendingOwner;
    /// @notice One-shot deploy key allowed to call `setHook` / `setEscrow`. Cleared after both are set.
    address public bootstrapper;
    /// @notice Only the AML hook may credit seized principal.
    address public hook;
    /// @notice Only FeeEscrow may book a recovered illicit risk fee.
    address public escrow;
    /// @notice LP compensation vault. Payouts cannot go here (whitepaper §8.3).
    address public lpCompensationFund;

    mapping(Account => mapping(address => uint256)) public override balances;
    /// @notice Amount reserved by pending payouts, per ledger account and token.
    mapping(Account => mapping(address => uint256)) public pendingOut;
    mapping(address => bool) public allowedDestinations;

    uint256 public nextPayoutId = 1;
    mapping(uint256 => Payout) private _payouts;

    error NotOwner();
    error NotPendingOwner();
    error NotHook();
    error NotEscrow();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();
    error DestinationNotAllowed(address to);
    error PaysLpFund(address to);
    error InsufficientBalance();
    error UnknownPayout();
    error NotPending();
    error PayoutDelayPending();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event HookUpdated(address indexed hook);
    event EscrowUpdated(address indexed escrow);
    event LpCompensationFundUpdated(address indexed lpCompensationFund);
    event DestinationUpdated(address indexed dest, bool allowed);

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

    event PayoutProposed(
        uint256 indexed payoutId,
        Account indexed account,
        address indexed to,
        address token,
        uint256 amount,
        bytes32 fileHash,
        uint256 escrowId
    );
    event PayoutExecuted(uint256 indexed payoutId, address indexed to, address token, uint256 amount);
    event PayoutCancelled(uint256 indexed payoutId);

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

    /// @notice Point at the LP compensation vault so payouts can never land there.
    function setLpCompensationFund(address lpCompensationFund_) external onlyOwnerOrBootstrapper {
        if (lpCompensationFund_ == address(0) || lpCompensationFund_ == address(this)) revert ZeroAddress();
        lpCompensationFund = lpCompensationFund_;
        emit LpCompensationFundUpdated(lpCompensationFund_);
    }

    /// @notice Allow or revoke an authority / judicial destination for delayed payouts.
    function setDestination(address dest, bool allowed) external onlyOwner {
        if (dest == address(0) || dest == address(this)) revert ZeroAddress();
        if (dest == lpCompensationFund) revert PaysLpFund(dest);
        allowedDestinations[dest] = allowed;
        emit DestinationUpdated(dest, allowed);
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

    /// @inheritdoc IComplianceTreasury
    function proposePayout(
        Account account,
        address token,
        uint256 amount,
        address to,
        bytes32 fileHash,
        string calldata memo,
        uint256 escrowId,
        bytes32 fingerprint
    ) external onlyOwner returns (uint256 payoutId) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to == lpCompensationFund) revert PaysLpFund(to);
        if (!allowedDestinations[to]) revert DestinationNotAllowed(to);
        uint256 available = balances[account][token] - pendingOut[account][token];
        if (available < amount) revert InsufficientBalance();

        pendingOut[account][token] += amount;
        payoutId = nextPayoutId++;
        _payouts[payoutId] = Payout({
            account: account,
            token: token,
            amount: amount,
            to: to,
            fileHash: fileHash,
            memo: memo,
            proposedAt: uint64(block.timestamp),
            escrowId: escrowId,
            fingerprint: fingerprint,
            status: PayoutStatus.Pending
        });
        emit PayoutProposed(payoutId, account, to, token, amount, fileHash, escrowId);
    }

    /// @inheritdoc IComplianceTreasury
    function executePayout(uint256 payoutId) external onlyOwner {
        Payout storage rec = _requirePending(payoutId);
        if (block.timestamp < uint256(rec.proposedAt) + uint256(PAYOUT_DELAY)) revert PayoutDelayPending();
        if (rec.to == lpCompensationFund) revert PaysLpFund(rec.to);
        if (!allowedDestinations[rec.to]) revert DestinationNotAllowed(rec.to);

        rec.status = PayoutStatus.Executed;
        pendingOut[rec.account][rec.token] -= rec.amount;
        balances[rec.account][rec.token] -= rec.amount;
        if (!IERC20Treasury(rec.token).transfer(rec.to, rec.amount)) revert TransferFailed();
        emit PayoutExecuted(payoutId, rec.to, rec.token, rec.amount);
    }

    /// @inheritdoc IComplianceTreasury
    function cancelPayout(uint256 payoutId) external onlyOwner {
        Payout storage rec = _requirePending(payoutId);
        rec.status = PayoutStatus.Cancelled;
        pendingOut[rec.account][rec.token] -= rec.amount;
        emit PayoutCancelled(payoutId);
    }

    /// @notice Full payout row for the officer / API.
    function getPayout(uint256 payoutId) external view returns (Payout memory) {
        if (payoutId == 0 || payoutId >= nextPayoutId) revert UnknownPayout();
        return _payouts[payoutId];
    }

    function _requirePending(uint256 payoutId) private view returns (Payout storage rec) {
        if (payoutId == 0 || payoutId >= nextPayoutId) revert UnknownPayout();
        rec = _payouts[payoutId];
        if (rec.status != PayoutStatus.Pending) revert NotPending();
    }
}
