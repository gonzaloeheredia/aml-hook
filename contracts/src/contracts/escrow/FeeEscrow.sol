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
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      WHY ESCROW THE FEE AT ALL?
///      ═══════════════════════════════════════════════════════════════════════
///
///      On FEE_OVERRIDE (score 31–70), the product applies economic friction without
///      hard-blocking. The *differential* fee slice is parked here for 48h so a
///      Compliance Officer Agent (COA) can review off-chain. User swap output still
///      settles in the same block — we never hold the full swap.
///
///      Two COA consultations → keeper-only on-chain transfers:
///
///        Moment              Call                         Destination
///        ─────────────────   ──────────────────────────   ─────────────────────────────
///        0–24h               (optional COA, no write)     still held
///        Checkpoint 1        releaseEarly                 lpCompensationFund
///          (≥24h, <48h)      after 1st COA + sanity       (never blocks; never the pool)
///        Checkpoint 2        resolveCheckpoint2(…)        illicit → Blocked (tokens stay here)
///          (≥48h)            after 2nd COA + sanity       clean   → lpCompensationFund
///        No resolution       releaseDefault               lpCompensationFund
///          (≥48h)                                         (not confirmed high-risk/sanctioned)
///
///      WHY split destinations? A confirmed sanction freezes the differential in
///      a blocked reserve for reporting — later release calls revert. Every other
///      path credits LPs as retroactive compensation. The risk fee never returns
///      to the pool.
///
///      Access: own owner / keepers / depositors (NOT the shared AccessManager).
///      The COA never writes on-chain; only a FeeEscrow keeper submits txs after
///      an off-chain sanity check on the COA output.
contract FeeEscrow is IFeeEscrow {
    /// @dev Full hold window before Checkpoint 2 / default release may run.
    uint64 public constant ESCROW_WINDOW = 48 hours;
    /// @dev Earliest moment Checkpoint 1 (early release to LPs) is allowed.
    uint64 public constant CHECKPOINT1_MIN_AGE = 24 hours;

    address public owner;
    /// @notice Two-step ownership: proposed owner must call `acceptOwnership`.
    address public pendingOwner;
    IERC20Fee private immutable _feeToken;
    /// @notice Sole release destination: LP compensation when the wallet is not confirmed sanctioned.
    ///         Checkpoint 1, Checkpoint 2 clean, and `releaseDefault` all credit LPs here. Never the pool.
    address public lpCompensationFund;

    /// @dev Keepers alone call releaseEarly / resolveCheckpoint2 / releaseDefault.
    mapping(address => bool) public keepers;
    /// @dev Depositors (settlement / hook integration) alone call deposit.
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
    error LengthMismatch();
    error NotPendingOwner();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event DepositorUpdated(address indexed depositor, bool allowed);
    event LpCompensationFundUpdated(address indexed lpCompensationFund);

    /// @notice Differential fee deposited into the 48h escrow (§3.6 / §3.7 audit trail).
    event FeeDeposited(
        uint256 indexed escrowId,
        address indexed wallet,
        uint256 amount,
        uint64 depositedAt,
        bytes32 originTxHash
    );

    /// @notice Checkpoint 1 early release to the LP compensation fund (never the pool; never confiscates).
    event FeeReleasedEarly(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    /// @notice Checkpoint 2 sanction confirmed: fee stays blocked in this contract.
    event FeeBlocked(uint256 indexed escrowId, address indexed wallet, uint256 amount);

    /// @notice Period expired without a confirmed sanction: release to LPs (default or Checkpoint 2 clean).
    event FeeReleasedDefault(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    constructor(address owner_, address feeToken_, address lpCompensationFund_) {
        if (owner_ == address(0) || feeToken_ == address(0) || lpCompensationFund_ == address(0)) {
            revert ZeroAddress();
        }
        owner = owner_;
        _feeToken = IERC20Fee(feeToken_);
        lpCompensationFund = lpCompensationFund_;
        // Bootstrap: owner can deposit and resolve until roles are specialized.
        keepers[owner_] = true;
        depositors[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperUpdated(owner_, true);
        emit DepositorUpdated(owner_, true);
        emit LpCompensationFundUpdated(lpCompensationFund_);
    }

    /// @inheritdoc IFeeEscrow
    function feeToken() external view returns (address) {
        return address(_feeToken);
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
    /// @notice Pull the differential fee from the depositor into this contract for 48h.
    /// @dev `wallet` is the compliance subject (for the audit trail), not necessarily msg.sender.
    ///      `originTxHash` links the escrow row to the FEE_OVERRIDE swap that created it.
    function deposit(address wallet, bytes32 originTxHash, uint256 amount)
        external
        onlyDepositor
        returns (uint256 escrowId)
    {
        if (wallet == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (!_feeToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

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
    /// @notice Checkpoint 1 (≥24h, <48h): first COA consult → early credit to LPs.
    /// @dev Never confiscates here: blocking is reserved for Checkpoint 2 after a second COA pass.
    ///      The risk fee never returns to the pool.
    function releaseEarly(uint256 escrowId) external onlyKeeper {
        _releaseEarly(escrowId);
    }

    /// @inheritdoc IFeeEscrow
    function batchReleaseEarly(uint256[] calldata escrowIds) external onlyKeeper {
        uint256 n = escrowIds.length;
        for (uint256 i; i < n; ++i) {
            _releaseEarly(escrowIds[i]);
        }
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Checkpoint 2 (≥48h): second COA consult → block in escrow or release to LP fund.
    /// @param illicitConfirmed Keeper's post-sanity conclusion from the COA (true = block).
    /// @dev Illicit → Blocked, tokens stay here. Clean → lpCompensationFund (never pool).
    function resolveCheckpoint2(uint256 escrowId, bool illicitConfirmed) external onlyKeeper {
        _resolveCheckpoint2(escrowId, illicitConfirmed);
    }

    /// @inheritdoc IFeeEscrow
    function batchResolveCheckpoint2(uint256[] calldata escrowIds, bool[] calldata illicitConfirmed)
        external
        onlyKeeper
    {
        uint256 n = escrowIds.length;
        if (n != illicitConfirmed.length) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            _resolveCheckpoint2(escrowIds[i], illicitConfirmed[i]);
        }
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Default path if nobody resolved at Checkpoint 2: credit LPs.
    /// @dev The wallet was not confirmed high-risk or sanctioned. Same destination as
    ///      Checkpoint 2 clean (§3.7) — retroactive LP compensation, never the pool.
    function releaseDefault(uint256 escrowId) external onlyKeeper {
        _releaseDefault(escrowId);
    }

    /// @inheritdoc IFeeEscrow
    function batchReleaseDefault(uint256[] calldata escrowIds) external onlyKeeper {
        uint256 n = escrowIds.length;
        for (uint256 i; i < n; ++i) {
            _releaseDefault(escrowIds[i]);
        }
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

    function setLpCompensationFund(address lpCompensationFund_) external onlyOwner {
        if (lpCompensationFund_ == address(0)) revert ZeroAddress();
        lpCompensationFund = lpCompensationFund_;
        emit LpCompensationFundUpdated(lpCompensationFund_);
    }

    /// @notice Propose a new owner. Completes only when `newOwner` calls `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete a pending two-step ownership transfer.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function _releaseEarly(uint256 escrowId) private {
        EscrowRecord storage rec = _requireActive(escrowId);
        uint256 age = block.timestamp - uint256(rec.depositedAt);
        if (age < uint256(CHECKPOINT1_MIN_AGE)) revert Checkpoint1TooEarly();
        if (age >= uint256(ESCROW_WINDOW)) revert Checkpoint1WindowClosed();

        rec.status = EscrowStatus.ReleasedEarly;
        address to = lpCompensationFund;
        uint256 amount = rec.amount;
        address wallet = rec.wallet;

        _transferOut(to, amount);
        emit FeeReleasedEarly(escrowId, wallet, amount, to);
    }

    function _resolveCheckpoint2(uint256 escrowId, bool illicitConfirmed) private {
        EscrowRecord storage rec = _requireActive(escrowId);
        if (block.timestamp < uint256(rec.depositedAt) + uint256(ESCROW_WINDOW)) {
            revert EscrowWindowOpen();
        }

        address wallet = rec.wallet;
        uint256 amount = rec.amount;

        if (illicitConfirmed) {
            rec.status = EscrowStatus.Blocked;
            emit FeeBlocked(escrowId, wallet, amount);
        } else {
            rec.status = EscrowStatus.ReleasedDefault;
            address to = lpCompensationFund;
            _transferOut(to, amount);
            emit FeeReleasedDefault(escrowId, wallet, amount, to);
        }
    }

    function _releaseDefault(uint256 escrowId) private {
        EscrowRecord storage rec = _requireActive(escrowId);
        if (block.timestamp < uint256(rec.depositedAt) + uint256(ESCROW_WINDOW)) {
            revert EscrowWindowOpen();
        }

        rec.status = EscrowStatus.ReleasedDefault;
        address to = lpCompensationFund;
        uint256 amount = rec.amount;
        address wallet = rec.wallet;

        _transferOut(to, amount);
        emit FeeReleasedDefault(escrowId, wallet, amount, to);
    }

    function _requireActive(uint256 escrowId) private view returns (EscrowRecord storage rec) {
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        rec = _escrows[escrowId];
        // Terminal statuses cannot be resolved twice (no double pay).
        if (rec.status != EscrowStatus.Active) revert NotActive();
    }

    function _transferOut(address to, uint256 amount) private {
        if (!_feeToken.transfer(to, amount)) revert TransferFailed();
    }
}
