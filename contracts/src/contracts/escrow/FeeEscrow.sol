// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IComplianceTreasury} from "../../interfaces/treasury/IComplianceTreasury.sol";
import {ComplianceBand} from "../../libraries/ComplianceBand.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal ERC-20 surface for fee custody (transfer / transferFrom only).
interface IERC20Fee {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title FeeEscrow — 48-hour hold of the extra risk fee (whitepaper §8.3)
/// @notice Holds only the extra slice on a fee-override. Not the swap output. User capital settles in the same block.
///
/// @dev Whitepaper §2.2 and §8.3, in this contract.
///
///      On score 31–70 the pool keeps its standard LP fee. After the swap, only the extra
///      slice is taken and deposited here for 48 hours. That slice is the price of letting
///      a medium-risk swap settle. It belongs in FeeEscrow, not in the pool.
///
///      Sending the extra fee to LPs on the same swap would pay them with funds that may
///      still be illicit. That would make them instruments of money launderers.
///
///      The Compliance Officer Agent reviews the case off-chain. It cannot write this
///      contract. A dedicated escrow keeper submits the on-chain call after a sanity
///      check on the agent output.
///
///        Moment                         Action                         Destination
///        ────────────────────────────   ────────────────────────────   ─────────────────────────
///        0–24h                          Optional review                Still held
///        24–48h                         Early release                  LP compensation fund
///        At 48h, illicit confirmed      Block                          Stays here for the file;
///                                                                      then compliance reserve
///        At 48h, not illicit            Release                        LP compensation fund
///        Nobody resolved by 48h         Default release                LP compensation fund
///
///      Two destinations, and they cannot be the same address. Every clean exit — early
///      release, clean checkpoint, or default — goes to the LP compensation fund. A
///      confirmed-illicit row stays blocked while the operator produces the file. Then
///      the escrow owner (a Safe in production) recovers it after at least 7 days, only
///      to the compliance reserve. After the full delay (default 90 days) anyone may
///      send an expired blocked row to that same reserve. Never the LP fund. Never the pool.
///
///      `FeeRecovered` records destination, token, amount, wallet, and the originating
///      swap fingerprint so the movement is auditable against the fee-override transaction.
///
///      FeeEscrow has its own owner, keeper, depositor, and auditor — not the shared
///      AccessManager. Ownership is two-step and starts as the admin or a dedicated
///      escrow owner, not the deploying key. The hook is registered as depositor once
///      at deploy; that bootstrap key is then cleared.
contract FeeEscrow is IFeeEscrow, ReentrancyGuard {
    /// @dev Full hold window before Checkpoint 2 / default release may run.
    uint64 public constant ESCROW_WINDOW = 48 hours;
    /// @dev Earliest moment Checkpoint 1 (early release to LPs) is allowed.
    uint64 public constant CHECKPOINT1_MIN_AGE = 24 hours;
    uint64 public constant DEPOSITOR_TIMELOCK = 24 hours;
    /// @dev Adding a keeper is delayed; revoking a keeper is immediate.
    uint64 public constant KEEPER_TIMELOCK = 24 hours;
    /// @dev Whitepaper §8.1: the escrow owner recovers blocked fees after 7 days, only to the compliance reserve.
    uint64 public constant OWNER_BLOCKED_RECOVERY_MIN_AGE = 7 days;

    /// @notice Production owner is a Safe (whitepaper §8.1). Not a single key.
    address public owner;
    /// @notice Two-step ownership: proposed owner must call `acceptOwnership`.
    address public pendingOwner;
    /// @notice One-shot deploy key allowed to call `bootstrapDepositor`. Cleared after that call.
    address public bootstrapper;
    IERC20Fee private immutable _feeToken;
    mapping(address => bool) public allowedFeeTokens;
    /// @notice Token amount currently retained per compliance subject (Active + Blocked).
    mapping(address => mapping(address => uint256)) public balances;
    /// @notice Wait after a confirmed-illicit block before anyone may send the fee to the compliance reserve (default 90 days).
    uint64 public blockedRecoveryDelay = 90 days;
    /// @notice LP compensation fund (whitepaper §8.3). Early release, clean checkpoint, and default all go here.
    ///         Compensation for risk already taken on a swap that turned out clean. Never the pool.
    address public lpCompensationFund;
    /// @notice Compliance reserve (whitepaper §2.2 / §8.3). Only destination for a fee confirmed illicit.
    ///         Never the LP compensation fund, at any point. Production: ComplianceTreasury.
    address public complianceReserve;
    /// @notice Layer 1 list read by Checkpoint 2 / early-release gate. Optional until `setComplianceSources`.
    ISanctionRegistry public sanctionRegistry;
    /// @notice Layer 2 store read by Checkpoint 2 / early-release gate. Optional until `setComplianceSources`.
    IComplianceOracle public complianceOracle;

    /// @dev Keepers alone call releaseEarly / resolveCheckpoint2 / releaseDefault.
    mapping(address => bool) public keepers;
    /// @dev Depositors (settlement / hook integration) alone call deposit.
    mapping(address => bool) public depositors;
    mapping(address => bool) public auditors;

    address public pendingDepositor;
    bool public pendingDepositorAllowed;
    uint64 public pendingDepositorApplyAt;
    /// @dev One-shot: wire the hook (or equivalent) as depositor at deploy without the 24h delay.
    bool public depositorBootstrapped;

    address public pendingKeeper;
    bool public pendingKeeperAllowed;
    uint64 public pendingKeeperApplyAt;

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
    error NotBlocked();
    uint256 private constant MAX_BATCH_SIZE = 100;
    error BatchTooLarge();
    error FeeTokenNotAllowed();
    error UnauthorizedEscrowRead();
    error DepositorTimelockPending();
    error NoPendingDepositor();
    error DepositorAlreadyBootstrapped();
    error KeeperTimelockPending();
    error NoPendingKeeper();
    error BlockedRecoveryTooEarly();
    error InvalidBlockedRecoveryDelay();
    error DestinationsMustDiffer();
    /// @notice Early release refused: the wallet is listed or the oracle score is in the REVERT band.
    error IllicitOnChain(address wallet);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event KeeperChangeScheduled(address indexed keeper, bool allowed, uint64 applyAt);
    event DepositorUpdated(address indexed depositor, bool allowed);
    event DepositorChangeScheduled(address indexed depositor, bool allowed, uint64 applyAt);
    event AuditorUpdated(address indexed auditor, bool allowed);
    event AllowedFeeTokenUpdated(address indexed token, bool allowed);
    event BlockedRecoveryDelayUpdated(uint64 previous, uint64 current);
    event LpCompensationFundUpdated(address indexed lpCompensationFund);
    event ComplianceReserveUpdated(address indexed complianceReserve);
    event ComplianceSourcesUpdated(address indexed sanctionRegistry, address indexed complianceOracle);

    /// @notice Extra slice deposited for 48 hours (whitepaper §8.3). `swapFingerprint` ties the row to the swap.
    event FeeDeposited(
        uint256 indexed escrowId,
        address indexed wallet,
        uint256 amount,
        uint64 depositedAt,
        bytes32 swapFingerprint
    );

    /// @notice Early release to the LP compensation fund. Never blocks. Never the pool.
    event FeeReleasedEarly(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    /// @notice Sanction or illicit typology confirmed. The slice stays here so the operator can produce the file.
    event FeeBlocked(uint256 indexed escrowId, address indexed wallet, uint256 amount);

    /// @notice Clean checkpoint or default after 48 hours: retroactive LP compensation. Never the pool.
    event FeeReleasedDefault(
        uint256 indexed escrowId, address indexed wallet, uint256 amount, address indexed to
    );

    /// @notice A blocked fee left this contract for the compliance reserve (`to`).
    /// @dev `token`, `amount`, and `swapFingerprint` let a reader match this movement to the fee-override swap.
    event FeeRecovered(
        uint256 indexed escrowId,
        address indexed wallet,
        address indexed to,
        address token,
        uint256 amount,
        bytes32 swapFingerprint
    );

    constructor(
        address owner_,
        address feeToken_,
        address lpCompensationFund_,
        address complianceReserve_,
        address bootstrapper_
    ) {
        if (
            owner_ == address(0) || feeToken_ == address(0) || lpCompensationFund_ == address(0)
                || complianceReserve_ == address(0) || bootstrapper_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (lpCompensationFund_ == complianceReserve_) revert DestinationsMustDiffer();
        owner = owner_;
        bootstrapper = bootstrapper_;
        _feeToken = IERC20Fee(feeToken_);
        allowedFeeTokens[feeToken_] = true;
        lpCompensationFund = lpCompensationFund_;
        complianceReserve = complianceReserve_;
        // Until keepers are appointed, the owner can resolve. The hook is wired as depositor at deploy.
        keepers[owner_] = true;
        depositors[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperUpdated(owner_, true);
        emit DepositorUpdated(owner_, true);
        emit LpCompensationFundUpdated(lpCompensationFund_);
        emit ComplianceReserveUpdated(complianceReserve_);
        emit AllowedFeeTokenUpdated(feeToken_, true);
    }

    /// @inheritdoc IFeeEscrow
    function feeToken() external view returns (address) {
        return address(_feeToken);
    }

    /// @dev Restricts admin paths (keepers, depositors, recovery, ownership).
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Restricts Checkpoint 1 / 2 / default release to the escrow keeper list.
    modifier onlyKeeper() {
        if (!keepers[msg.sender]) revert NotKeeper();
        _;
    }

    /// @dev Restricts `deposit` to the hook (or another wired settlement contract).
    modifier onlyDepositor() {
        if (!depositors[msg.sender]) revert NotDepositor();
        _;
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Take the extra slice from the hook and hold it for 48 hours.
    /// @dev `wallet` is the swap subject. `swapFingerprint` links this row to that swap.
    function deposit(address wallet, address token, bytes32 swapFingerprint, uint256 amount)
        external
        onlyDepositor
        nonReentrant
        returns (uint256 escrowId)
    {
        if (wallet == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!allowedFeeTokens[token]) revert FeeTokenNotAllowed();

        if (!IERC20Fee(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        escrowId = nextEscrowId++;
        uint64 ts = uint64(block.timestamp);
        _escrows[escrowId] = EscrowRecord({
            wallet: wallet,
            token: token,
            amount: amount,
            depositedAt: ts,
            swapFingerprint: swapFingerprint,
            status: EscrowStatus.Active,
            blockedAt: 0
        });
        balances[wallet][token] += amount;

        emit FeeDeposited(escrowId, wallet, amount, ts, swapFingerprint);
    }

    /// @inheritdoc IFeeEscrow
    /// @notice 24–48h: early release to the LP compensation fund (whitepaper §8.3).
    /// @dev Early release never blocks. Blocking waits for the second review at 48 hours.
    function releaseEarly(uint256 escrowId) external onlyKeeper nonReentrant {
        _releaseEarly(escrowId);
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Checkpoint 1 for many ids in one tx (cap `MAX_BATCH_SIZE`).
    function batchReleaseEarly(uint256[] calldata escrowIds) external onlyKeeper nonReentrant {
        if (escrowIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        uint256 n = escrowIds.length;
        for (uint256 i; i < n; ++i) {
            _releaseEarly(escrowIds[i]);
        }
    }

    /// @inheritdoc IFeeEscrow
    /// @notice At 48h: second review. Destination is the on-chain list / oracle row, not a keeper argument.
    function resolveCheckpoint2(uint256 escrowId) external onlyKeeper nonReentrant {
        _resolveCheckpoint2(escrowId);
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Checkpoint 2 for many ids (same on-chain illicit read).
    function batchResolveCheckpoint2(uint256[] calldata escrowIds) external onlyKeeper nonReentrant {
        uint256 n = escrowIds.length;
        if (n > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i; i < n; ++i) {
            _resolveCheckpoint2(escrowIds[i]);
        }
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Nobody resolved by 48h: treat as clean and credit the LP compensation fund.
    function releaseDefault(uint256 escrowId) external onlyKeeper nonReentrant {
        _releaseDefault(escrowId);
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Default LP credit for many unresolved ids after the 48h window.
    function batchReleaseDefault(uint256[] calldata escrowIds) external onlyKeeper nonReentrant {
        if (escrowIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        uint256 n = escrowIds.length;
        for (uint256 i; i < n; ++i) {
            _releaseDefault(escrowIds[i]);
        }
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Full escrow row for owner or an auditor (wallet plaintext).
    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory) {
        if (msg.sender != owner && !auditors[msg.sender]) revert UnauthorizedEscrowRead();
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        return _escrows[escrowId];
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Public escrow view with `wallet` hashed (no owner/auditor gate).
    function getEscrowPublic(uint256 escrowId)
        external
        view
        returns (
            bytes32 walletHash,
            address token,
            uint256 amount,
            uint64 depositedAt,
            bytes32 swapFingerprint,
            EscrowStatus status,
            uint64 blockedAt
        )
    {
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        return _publicView(_escrows[escrowId]);
    }

    function _publicView(EscrowRecord storage rec)
        private
        view
        returns (
            bytes32 walletHash,
            address token,
            uint256 amount,
            uint64 depositedAt,
            bytes32 swapFingerprint,
            EscrowStatus status,
            uint64 blockedAt
        )
    {
        return (
            keccak256(abi.encodePacked(rec.wallet)),
            rec.token,
            rec.amount,
            rec.depositedAt,
            rec.swapFingerprint,
            rec.status,
            rec.blockedAt
        );
    }

    /// @inheritdoc IFeeEscrow
    /// @notice Escrow owner recovers a blocked row to the compliance reserve, after at least 7 days (whitepaper §8.1 / §8.3).
    /// @dev Never the LP compensation fund. `FeeRecovered` records where it went, how much, and which swap.
    function recoverBlocked(uint256 escrowId) external onlyOwner nonReentrant {
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        EscrowRecord storage rec = _escrows[escrowId];
        if (rec.status != EscrowStatus.Blocked) revert NotBlocked();
        uint256 ownerDelay = uint256(blockedRecoveryDelay) > uint256(OWNER_BLOCKED_RECOVERY_MIN_AGE)
            ? uint256(blockedRecoveryDelay)
            : uint256(OWNER_BLOCKED_RECOVERY_MIN_AGE);
        if (rec.blockedAt == 0 || block.timestamp < uint256(rec.blockedAt) + ownerDelay) {
            revert BlockedRecoveryTooEarly();
        }
        _executeBlockedRecovery(escrowId, rec);
    }

    /// @inheritdoc IFeeEscrow
    /// @notice After the full delay (default 90 days), anyone may send an expired blocked row to the compliance reserve.
    /// @dev Same destination as owner recovery. Still never the LP fund and never the pool.
    function recoverExpiredBlocked(uint256 escrowId) external nonReentrant {
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        EscrowRecord storage rec = _escrows[escrowId];
        if (rec.status != EscrowStatus.Blocked) revert NotBlocked();
        if (rec.blockedAt == 0 || block.timestamp < uint256(rec.blockedAt) + uint256(blockedRecoveryDelay)) {
            revert BlockedRecoveryTooEarly();
        }
        _executeBlockedRecovery(escrowId, rec);
    }

    /// @notice Schedule adding a keeper (`allowed = true`) or revoke immediately (`allowed = false`).
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        if (!allowed) {
            keepers[keeper] = false;
            if (pendingKeeper == keeper) {
                pendingKeeper = address(0);
                pendingKeeperAllowed = false;
                pendingKeeperApplyAt = 0;
            }
            emit KeeperUpdated(keeper, false);
            return;
        }
        pendingKeeper = keeper;
        pendingKeeperAllowed = true;
        pendingKeeperApplyAt = uint64(block.timestamp + uint256(KEEPER_TIMELOCK));
        emit KeeperChangeScheduled(keeper, true, pendingKeeperApplyAt);
    }

    /// @notice Execute a scheduled keeper grant after `KEEPER_TIMELOCK`.
    function applyKeeper() external onlyOwner {
        if (pendingKeeperApplyAt == 0) revert NoPendingKeeper();
        if (block.timestamp < uint256(pendingKeeperApplyAt)) revert KeeperTimelockPending();
        address keeper = pendingKeeper;
        bool allowed = pendingKeeperAllowed;
        pendingKeeper = address(0);
        pendingKeeperAllowed = false;
        pendingKeeperApplyAt = 0;
        keepers[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    /// @notice One-shot deploy wiring: grant a depositor immediately (the hook). Later changes use the timelock.
    /// @dev Callable by `owner` or the constructor `bootstrapper`. The bootstrapper is cleared afterwards
    ///      so the deploying EOA cannot keep a privileged path into this contract.
    function bootstrapDepositor(address depositor) external {
        if (depositorBootstrapped) revert DepositorAlreadyBootstrapped();
        if (msg.sender != owner && msg.sender != bootstrapper) revert NotOwner();
        if (depositor == address(0)) revert ZeroAddress();
        depositorBootstrapped = true;
        bootstrapper = address(0);
        depositors[depositor] = true;
        emit DepositorUpdated(depositor, true);
    }

    /// @notice Schedule a depositor grant or revoke; takes effect after `DEPOSITOR_TIMELOCK`.
    function setDepositor(address depositor, bool allowed) external onlyOwner {
        if (depositor == address(0)) revert ZeroAddress();
        pendingDepositor = depositor;
        pendingDepositorAllowed = allowed;
        pendingDepositorApplyAt = uint64(block.timestamp + uint256(DEPOSITOR_TIMELOCK));
        emit DepositorChangeScheduled(depositor, allowed, pendingDepositorApplyAt);
    }

    /// @notice Execute a scheduled depositor change after `DEPOSITOR_TIMELOCK`.
    function applyDepositor() external onlyOwner {
        if (pendingDepositorApplyAt == 0) revert NoPendingDepositor();
        if (block.timestamp < uint256(pendingDepositorApplyAt)) revert DepositorTimelockPending();
        address depositor = pendingDepositor;
        bool allowed = pendingDepositorAllowed;
        pendingDepositor = address(0);
        pendingDepositorAllowed = false;
        pendingDepositorApplyAt = 0;
        depositors[depositor] = allowed;
        emit DepositorUpdated(depositor, allowed);
    }

    /// @notice Grant or revoke full-row `getEscrow` read access.
    function setAuditor(address auditor, bool allowed) external onlyOwner {
        if (auditor == address(0)) revert ZeroAddress();
        auditors[auditor] = allowed;
        emit AuditorUpdated(auditor, allowed);
    }

    /// @notice Allow or reject a token for `deposit` (constructor token starts allowed).
    function setAllowedFeeToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedFeeTokens[token] = allowed;
        emit AllowedFeeTokenUpdated(token, allowed);
    }

    /// @notice Retune how long a blocked row waits before anyone may send it to the compliance reserve (minimum one day).
    /// @dev Owner recovery still waits at least 7 days.
    function setBlockedRecoveryDelay(uint64 delay) external onlyOwner {
        if (delay < 1 days) revert InvalidBlockedRecoveryDelay();
        emit BlockedRecoveryDelayUpdated(blockedRecoveryDelay, delay);
        blockedRecoveryDelay = delay;
    }

    /// @notice Point clean / early / default releases at a new LP compensation fund.
    /// @dev Cannot equal the compliance reserve. The two destinations stay distinct (whitepaper §8.3).
    function setLpCompensationFund(address lpCompensationFund_) external onlyOwner {
        if (lpCompensationFund_ == address(0)) revert ZeroAddress();
        if (lpCompensationFund_ == complianceReserve) revert DestinationsMustDiffer();
        lpCompensationFund = lpCompensationFund_;
        emit LpCompensationFundUpdated(lpCompensationFund_);
    }

    /// @notice Point recovered blocked fees at a new compliance reserve. Cannot equal the LP compensation fund.
    function setComplianceReserve(address complianceReserve_) external onlyOwner {
        if (complianceReserve_ == address(0)) revert ZeroAddress();
        if (complianceReserve_ == lpCompensationFund) revert DestinationsMustDiffer();
        complianceReserve = complianceReserve_;
        emit ComplianceReserveUpdated(complianceReserve_);
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

    /// @dev 24–48h: LP compensation fund. Refuses if the oracle/list already marks the wallet illicit.
    function _releaseEarly(uint256 escrowId) private {
        EscrowRecord storage rec = _requireActive(escrowId);
        uint256 age = block.timestamp - uint256(rec.depositedAt);
        if (age < uint256(CHECKPOINT1_MIN_AGE)) revert Checkpoint1TooEarly();
        if (age >= uint256(ESCROW_WINDOW)) revert Checkpoint1WindowClosed();
        if (_isIllicit(rec.wallet)) revert IllicitOnChain(rec.wallet);

        rec.status = EscrowStatus.ReleasedEarly;
        address to = lpCompensationFund;
        uint256 amount = rec.amount;
        address wallet = rec.wallet;

        _debitAndTransfer(rec, to, amount);
        emit FeeReleasedEarly(escrowId, wallet, amount, to);
    }

    /// @dev At 48h: on-chain illicit stays here for the file; clean pays the LP compensation fund.
    function _resolveCheckpoint2(uint256 escrowId) private {
        EscrowRecord storage rec = _requireActive(escrowId);
        _requireWindowElapsed(rec);

        if (_isIllicit(rec.wallet)) {
            rec.status = EscrowStatus.Blocked;
            rec.blockedAt = uint64(block.timestamp);
            emit FeeBlocked(escrowId, rec.wallet, rec.amount);
        } else {
            _releaseToLpFund(escrowId, rec);
        }
    }

    /// @dev Nobody resolved by 48h. If the oracle/list already marks illicit, block instead of paying LPs.
    function _releaseDefault(uint256 escrowId) private {
        EscrowRecord storage rec = _requireActive(escrowId);
        _requireWindowElapsed(rec);
        if (_isIllicit(rec.wallet)) {
            rec.status = EscrowStatus.Blocked;
            rec.blockedAt = uint64(block.timestamp);
            emit FeeBlocked(escrowId, rec.wallet, rec.amount);
            return;
        }
        _releaseToLpFund(escrowId, rec);
    }

    /// @dev Layer 1 list or published score ≥ 71. Missing sources → not illicit (clean / default path).
    function _isIllicit(address wallet) private view returns (bool) {
        if (address(sanctionRegistry) != address(0) && sanctionRegistry.isSanctioned(wallet)) return true;
        if (address(complianceOracle) != address(0) && ComplianceBand.isIllicitScore(complianceOracle.getScore(wallet))) {
            return true;
        }
        return false;
    }

    /// @notice Owner or the one-shot bootstrapper wires the sources Checkpoint 2 reads.
    function setComplianceSources(ISanctionRegistry registry_, IComplianceOracle oracle_) external {
        if (msg.sender != owner && msg.sender != bootstrapper) revert NotOwner();
        sanctionRegistry = registry_;
        complianceOracle = oracle_;
        emit ComplianceSourcesUpdated(address(registry_), address(oracle_));
    }

    /// @dev Reverts if the 48-hour escrow window has not elapsed for this record.
    function _requireWindowElapsed(EscrowRecord storage rec) private view {
        if (block.timestamp < uint256(rec.depositedAt) + uint256(ESCROW_WINDOW)) {
            revert EscrowWindowOpen();
        }
    }

    /// @dev Sets the record to ReleasedDefault, transfers to the LP compensation fund, and emits.
    ///      Shared by `_releaseDefault` (no-action path) and the clean branch of `_resolveCheckpoint2`.
    function _releaseToLpFund(uint256 escrowId, EscrowRecord storage rec) private {
        address wallet = rec.wallet;
        uint256 amount = rec.amount;
        address to = lpCompensationFund;
        rec.status = EscrowStatus.ReleasedDefault;
        _debitAndTransfer(rec, to, amount);
        emit FeeReleasedDefault(escrowId, wallet, amount, to);
    }

    /// @dev Sets the record to Recovered, transfers to the compliance reserve, and emits.
    ///      Shared by `recoverBlocked` (owner, min 7 days) and `recoverExpiredBlocked` (anyone, full delay).
    function _executeBlockedRecovery(uint256 escrowId, EscrowRecord storage rec) private {
        rec.status = EscrowStatus.Recovered;
        uint256 amount = rec.amount;
        address wallet = rec.wallet;
        address token = rec.token;
        bytes32 swapFingerprint = rec.swapFingerprint;
        address to = complianceReserve;
        _debitAndTransfer(rec, to, amount);
        if (to.code.length != 0) {
            IComplianceTreasury(to).recordIllicitFee(wallet, token, amount, escrowId, swapFingerprint);
        }
        emit FeeRecovered(escrowId, wallet, to, token, amount, swapFingerprint);
    }

    /// @dev Load an Active row or revert (unknown id / already terminal).
    function _requireActive(uint256 escrowId) private view returns (EscrowRecord storage rec) {
        if (escrowId == 0 || escrowId >= nextEscrowId) revert UnknownEscrow();
        rec = _escrows[escrowId];
        // Terminal statuses cannot be resolved twice (no double pay).
        if (rec.status != EscrowStatus.Active) revert NotActive();
    }

    /// @dev Decrease per-wallet token balance then transfer; revert the whole call on failure.
    function _debitAndTransfer(EscrowRecord storage rec, address to, uint256 amount) private {
        balances[rec.wallet][rec.token] -= amount;
        if (!IERC20Fee(rec.token).transfer(to, amount)) revert TransferFailed();
    }
}
