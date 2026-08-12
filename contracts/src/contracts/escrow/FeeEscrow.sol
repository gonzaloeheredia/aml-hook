// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";

/// @dev Minimal ERC-20 surface for fee custody (transfer / transferFrom only).
interface IERC20Fee {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title FeeEscrow — 48h differential-fee hold for FEE_OVERRIDE swaps (§3.7)
/// @notice Retains only the differential fee (not swap output). User capital settles in-block.
/// @dev Access model mirrors ComplianceOracle / SanctionRegistry before their move to
///      `AccessManager`:
///      - depositors write deposits (settlement / hook integration point)
///      - keepers alone release or confiscate (COA never writes on-chain)
///      Checkpoint 1 (≥24h, <48h): early release to pool only (never confiscates).
///      Checkpoint 2 (≥48h): illicit → lpCompensationFund (LP compensation, never the pool);
///      clean → pool. Default (≥48h, no resolution): pool.
///
///      This contract keeps its own owner/keeper/depositor pattern rather than the shared
///      `AccessManager` the rest of the stack now answers to. Folding it in is a separate
///      decision — deposit/release/confiscate authority here is a different shape of problem
///      (per-role membership checked inline in the settlement path, not just admin setters) and
///      deserves its own review before it moves.
contract FeeEscrow is IFeeEscrow {
    uint64 public constant ESCROW_WINDOW = 48 hours;
    uint64 public constant CHECKPOINT1_MIN_AGE = 24 hours;

    address public owner;
    IERC20Fee public immutable feeToken;
    /// @notice Destination for clean / default / early releases (normal pool fee path).
    address public poolRecipient;
    /// @notice Destination for confiscated fees — LP compensation fund only (§3.7). Never the pool.
    address public lpCompensationFund;

    mapping(address => bool) public keepers;
    mapping(address => bool) public depositors;

    uint256 public nextEscrowId = 1;
    mapping(uint256 => EscrowRecord) private _escrows;

    error NotOwner();
    error NotKeeper();
    error NotDepositor();
    error ZeroAddress();
    error ZeroAmount();
    error UnknownEscrow();
    error NotActive();
    error Checkpoint1TooEarly();
    error Checkpoint1WindowClosed();
    error EscrowWindowOpen();
    error TransferFailed();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event DepositorUpdated(address indexed depositor, bool allowed);
    event PoolRecipientUpdated(address indexed poolRecipient);
    event LpCompensationFundUpdated(address indexed lpCompensationFund);

    /// @notice Differential fee deposited into the 48h escrow (§3.6 / §3.7 audit trail).
    event FeeDeposited(
        uint256 indexed escrowId,
        address indexed wallet,
        uint256 amount,
        uint64 depositedAt,
        bytes32 originTxHash
    );

    /// @notice Checkpoint 1 early release to the liquidity pool (never confiscates).
    event FeeReleasedEarly(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    /// @notice Checkpoint 2 confiscation: fee goes to LP compensation, never to the pool.
    event FeeConfiscated(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    /// @notice Default / non-illicit release to the pool at or after window close.
    event FeeReleasedDefault(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    constructor(
        address owner_,
        address feeToken_,
        address poolRecipient_,
        address lpCompensationFund_
    ) {
        if (
            owner_ == address(0) || feeToken_ == address(0) || poolRecipient_ == address(0)
                || lpCompensationFund_ == address(0)
        ) {
            revert ZeroAddress();
        }
        owner = owner_;
        feeToken = IERC20Fee(feeToken_);
        poolRecipient = poolRecipient_;
        lpCompensationFund = lpCompensationFund_;
        keepers[owner_] = true;
        depositors[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperUpdated(owner_, true);
        emit DepositorUpdated(owner_, true);
        emit PoolRecipientUpdated(poolRecipient_);
        emit LpCompensationFundUpdated(lpCompensationFund_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (!keepers[msg.sender]) revert NotKeeper();
        _;
    }

    modifier onlyDepositor() {
        if (!depositors[msg.sender]) revert NotDepositor();
        _;
    }

    /// @inheritdoc IFeeEscrow
    function deposit(address wallet, bytes32 originTxHash, uint256 amount)
        external
        onlyDepositor
        returns (uint256 escrowId)
    {
        if (wallet == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (!feeToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        escrowId = nextEscrowId++;
        uint64 ts = uint64(block.timestamp);
        _escrows[escrowId] = EscrowRecord({
            wallet: wallet,
            amount: amount,
            depositedAt: ts,
            originTxHash: originTxHash,
            status: EscrowStatus.Active
        });

        emit FeeDeposited(escrowId, wallet, amount, ts, originTxHash);
    }

    /// @inheritdoc IFeeEscrow
    /// @dev Checkpoint 1: after 24h and before the 48h window closes. Pool only.
    function releaseEarly(uint256 escrowId) external onlyKeeper {
        EscrowRecord storage rec = _requireActive(escrowId);
        uint256 age = block.timestamp - uint256(rec.depositedAt);
        if (age < uint256(CHECKPOINT1_MIN_AGE)) revert Checkpoint1TooEarly();
        if (age >= uint256(ESCROW_WINDOW)) revert Checkpoint1WindowClosed();

        rec.status = EscrowStatus.ReleasedEarly;
        address to = poolRecipient;
        uint256 amount = rec.amount;
        address wallet = rec.wallet;

        _transferOut(to, amount);
        emit FeeReleasedEarly(escrowId, wallet, amount, to);
    }

    /// @inheritdoc IFeeEscrow
    /// @dev Checkpoint 2: keeper applies COA conclusion after off-chain sanity checks.
    function resolveCheckpoint2(uint256 escrowId, bool illicitConfirmed) external onlyKeeper {
        EscrowRecord storage rec = _requireActive(escrowId);
        if (block.timestamp < uint256(rec.depositedAt) + uint256(ESCROW_WINDOW)) {
            revert EscrowWindowOpen();
        }

        address wallet = rec.wallet;
        uint256 amount = rec.amount;

        if (illicitConfirmed) {
            // Confiscated differential fees compensate LPs — never the pool recipient.
            rec.status = EscrowStatus.Confiscated;
            address to = lpCompensationFund;
            _transferOut(to, amount);
            emit FeeConfiscated(escrowId, wallet, amount, to);
        } else {
            rec.status = EscrowStatus.ReleasedDefault;
            address to = poolRecipient;
            _transferOut(to, amount);
            emit FeeReleasedDefault(escrowId, wallet, amount, to);
        }
    }

    /// @inheritdoc IFeeEscrow
    /// @dev Same destination as a non-illicit checkpoint-2 result (§3.7 default path).
    function releaseDefault(uint256 escrowId) external onlyKeeper {
        EscrowRecord storage rec = _requireActive(escrowId);
        if (block.timestamp < uint256(rec.depositedAt) + uint256(ESCROW_WINDOW)) {
            revert EscrowWindowOpen();
        }

        rec.status = EscrowStatus.ReleasedDefault;
        address to = poolRecipient;
        uint256 amount = rec.amount;
        address wallet = rec.wallet;

        _transferOut(to, amount);
        emit FeeReleasedDefault(escrowId, wallet, amount, to);
    }

    /// @inheritdoc IFeeEscrow
    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory) {
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        return _escrows[escrowId];
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    function setDepositor(address depositor, bool allowed) external onlyOwner {
        if (depositor == address(0)) revert ZeroAddress();
        depositors[depositor] = allowed;
        emit DepositorUpdated(depositor, allowed);
    }

    function setPoolRecipient(address poolRecipient_) external onlyOwner {
        if (poolRecipient_ == address(0)) revert ZeroAddress();
        poolRecipient = poolRecipient_;
        emit PoolRecipientUpdated(poolRecipient_);
    }

    function setLpCompensationFund(address lpCompensationFund_) external onlyOwner {
        if (lpCompensationFund_ == address(0)) revert ZeroAddress();
        lpCompensationFund = lpCompensationFund_;
        emit LpCompensationFundUpdated(lpCompensationFund_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _requireActive(uint256 escrowId) private view returns (EscrowRecord storage rec) {
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        rec = _escrows[escrowId];
        if (rec.status != EscrowStatus.Active) revert NotActive();
    }

    function _transferOut(address to, uint256 amount) private {
        if (!feeToken.transfer(to, amount)) revert TransferFailed();
    }
}
