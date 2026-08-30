// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILpCompensationVault} from "../../interfaces/compensation/ILpCompensationVault.sol";
import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {ComplianceBand} from "../../libraries/ComplianceBand.sol";

/// @dev Minimal ERC-20 surface for compensation custody.
interface IERC20Vault {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title LpCompensationVault: clean risk-fee releases, claimed by LPs after epoch close
/// @notice FeeEscrow transfers clean `RiskFee` rows here. FeeEscrow already classified
///         illicit vs clean. A keeper closes an
///         epoch with a merkle root of LP shares at the risk-assumption blocks. A
///         listed or score ≥ 71 wallet cannot claim. Unclaimed pot recycles after 90 days.
contract LpCompensationVault is ILpCompensationVault, ReentrancyGuard {
    /// @notice How long a closed epoch stays claimable before leftover recycles.
    uint64 public constant CLAIM_WINDOW = 90 days;

    address public owner;
    address public pendingOwner;
    address public bootstrapper;
    /// @notice FeeEscrow that releases clean risk fees here.
    address public escrow;
    /// @notice Compliance treasury: must stay a different address.
    address public complianceTreasury;
    ISanctionRegistry public sanctionRegistry;
    IComplianceOracle public complianceOracle;

    mapping(address => bool) public keepers;
    /// @notice Tokens booked into epochs (open + closed unclaimed).
    mapping(address => uint256) public accounted;
    mapping(uint256 => bool) public escrowAccrued;

    /// @notice Open epoch that `accrue` credits. Starts at 1.
    uint256 public epochId = 1;
    mapping(uint256 => uint64) public openedAt;
    mapping(uint256 => uint64) public closedAt;
    mapping(uint256 => uint64) public claimUntil;
    mapping(uint256 => bytes32) public merkleRoot;
    mapping(uint256 => uint64) public endBlock;
    mapping(uint256 => mapping(address => uint256)) public epochPot;
    mapping(uint256 => mapping(address => uint256)) public claimedTotal;
    mapping(uint256 => mapping(address => mapping(address => bool))) public claimed;

    error NotOwner();
    error NotPendingOwner();
    error NotKeeper();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();
    error DestinationsMustDiffer();
    error EscrowNotSet();
    error AlreadyAccrued();
    error WrongEscrowKind();
    error EscrowNotReleased();
    error InsufficientUnaccounted();
    error EpochOpen();
    error EpochAlreadyClosed();
    error InvalidRoot();
    error AlreadyClaimed();
    error InvalidProof();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error IllicitOnChain(address wallet);
    error NothingToRecycle();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event EscrowUpdated(address indexed escrow);
    event ComplianceTreasuryUpdated(address indexed complianceTreasury);
    event ComplianceSourcesUpdated(address indexed sanctionRegistry, address indexed complianceOracle);
    event Accrued(uint256 indexed epochId, address indexed token, uint256 amount);
    event AccruedFromEscrow(uint256 indexed epochId, uint256 indexed escrowId, address indexed token, uint256 amount);
    event EpochClosed(uint256 indexed epochId, bytes32 merkleRoot, uint64 endBlock);
    event Claimed(
        uint256 indexed epochId, address indexed account, address indexed token, uint256 amount
    );
    event UnclaimedRecycled(uint256 indexed fromEpoch, uint256 indexed toEpoch, address indexed token, uint256 amount);

    constructor(address owner_, address bootstrapper_, address complianceTreasury_) {
        if (owner_ == address(0) || bootstrapper_ == address(0) || complianceTreasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (complianceTreasury_ == address(this)) revert DestinationsMustDiffer();
        owner = owner_;
        bootstrapper = bootstrapper_;
        complianceTreasury = complianceTreasury_;
        keepers[owner_] = true;
        openedAt[1] = uint64(block.timestamp);
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperUpdated(owner_, true);
        emit ComplianceTreasuryUpdated(complianceTreasury_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrBootstrapper() {
        if (msg.sender != owner && msg.sender != bootstrapper) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (!keepers[msg.sender]) revert NotKeeper();
        _;
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    function setEscrow(address escrow_) external onlyOwnerOrBootstrapper {
        if (escrow_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        emit EscrowUpdated(escrow_);
        _clearBootstrapperIfWired();
    }

    function setComplianceTreasury(address complianceTreasury_) external onlyOwner {
        if (complianceTreasury_ == address(0) || complianceTreasury_ == address(this)) revert ZeroAddress();
        complianceTreasury = complianceTreasury_;
        emit ComplianceTreasuryUpdated(complianceTreasury_);
    }

    function setComplianceSources(ISanctionRegistry registry_, IComplianceOracle oracle_)
        external
        onlyOwnerOrBootstrapper
    {
        sanctionRegistry = registry_;
        complianceOracle = oracle_;
        emit ComplianceSourcesUpdated(address(registry_), address(oracle_));
        _clearBootstrapperIfWired();
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

    function _clearBootstrapperIfWired() private {
        if (escrow != address(0) && address(sanctionRegistry) != address(0)) bootstrapper = address(0);
    }

    /// @inheritdoc ILpCompensationVault
    function accrue(address token) external {
        if (token == address(0)) revert ZeroAddress();
        uint256 bal = IERC20Vault(token).balanceOf(address(this));
        if (bal <= accounted[token]) revert ZeroAmount();
        uint256 delta = bal - accounted[token];
        _book(token, delta);
        emit Accrued(epochId, token, delta);
    }

    /// @inheritdoc ILpCompensationVault
    function accrueFromEscrow(uint256 escrowId) external {
        if (escrow == address(0)) revert EscrowNotSet();
        if (escrowAccrued[escrowId]) revert AlreadyAccrued();
        (
            ,
            address token,
            uint256 amount,
            ,
            ,
            IFeeEscrow.EscrowStatus status,
            ,
            IFeeEscrow.EscrowKind kind
        ) = IFeeEscrow(escrow).getEscrowPublic(escrowId);
        if (kind != IFeeEscrow.EscrowKind.RiskFee) revert WrongEscrowKind();
        if (
            status != IFeeEscrow.EscrowStatus.ReleasedEarly
                && status != IFeeEscrow.EscrowStatus.ReleasedDefault
        ) {
            revert EscrowNotReleased();
        }
        uint256 bal = IERC20Vault(token).balanceOf(address(this));
        uint256 free = bal - accounted[token];
        if (free < amount) revert InsufficientUnaccounted();
        escrowAccrued[escrowId] = true;
        _book(token, amount);
        emit AccruedFromEscrow(epochId, escrowId, token, amount);
    }

    /// @inheritdoc ILpCompensationVault
    function closeEpoch(bytes32 merkleRoot_, uint64 endBlock_) external onlyKeeper {
        if (merkleRoot_ == bytes32(0)) revert InvalidRoot();
        if (closedAt[epochId] != 0) revert EpochAlreadyClosed();
        uint256 id = epochId;
        merkleRoot[id] = merkleRoot_;
        endBlock[id] = endBlock_;
        closedAt[id] = uint64(block.timestamp);
        claimUntil[id] = uint64(block.timestamp + uint256(CLAIM_WINDOW));
        emit EpochClosed(id, merkleRoot_, endBlock_);
        epochId = id + 1;
        openedAt[epochId] = uint64(block.timestamp);
    }

    /// @inheritdoc ILpCompensationVault
    function claim(
        uint256 epoch,
        address account,
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (account == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (closedAt[epoch] == 0) revert EpochOpen();
        if (block.timestamp > uint256(claimUntil[epoch])) revert ClaimWindowClosed();
        if (claimed[epoch][token][account]) revert AlreadyClaimed();
        if (_isIllicit(account)) revert IllicitOnChain(account);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, token, amount))));
        if (!MerkleProof.verify(proof, merkleRoot[epoch], leaf)) revert InvalidProof();

        claimed[epoch][token][account] = true;
        claimedTotal[epoch][token] += amount;
        accounted[token] -= amount;
        if (!IERC20Vault(token).transfer(account, amount)) revert TransferFailed();
        emit Claimed(epoch, account, token, amount);
    }

    /// @inheritdoc ILpCompensationVault
    function recycleUnclaimed(uint256 epoch, address token) external {
        if (token == address(0)) revert ZeroAddress();
        if (closedAt[epoch] == 0) revert EpochOpen();
        if (block.timestamp <= uint256(claimUntil[epoch])) revert ClaimWindowOpen();
        uint256 leftover = epochPot[epoch][token] - claimedTotal[epoch][token];
        if (leftover == 0) revert NothingToRecycle();
        epochPot[epoch][token] = claimedTotal[epoch][token];
        epochPot[epochId][token] += leftover;
        emit UnclaimedRecycled(epoch, epochId, token, leftover);
    }

    /// @notice Packed epoch header for the API.
    function epochInfo(uint256 id)
        external
        view
        returns (uint64 opened, uint64 closed, uint64 claimBy, bytes32 root, uint64 endBlk)
    {
        return (openedAt[id], closedAt[id], claimUntil[id], merkleRoot[id], endBlock[id]);
    }

    function _book(address token, uint256 amount) private {
        accounted[token] += amount;
        epochPot[epochId][token] += amount;
    }

    function _isIllicit(address wallet) private view returns (bool) {
        if (address(sanctionRegistry) != address(0) && sanctionRegistry.isSanctioned(wallet)) return true;
        if (address(complianceOracle) != address(0) && ComplianceBand.isIllicitScore(complianceOracle.getScore(wallet))) {
            return true;
        }
        return false;
    }
}
