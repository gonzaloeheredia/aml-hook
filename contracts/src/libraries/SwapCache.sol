// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IComplianceOracle} from "../interfaces/oracles/IComplianceOracle.sol";
import {HookDecision} from "./HookDecision.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title EIP-1153 transient cache from beforeSwap → afterSwap
/// @notice Avoids cold SSTORE for data that must not outlive the transaction.
/// @dev Slots are keccak-tagged with PoolId so concurrent swaps against this hook
///      in the same transaction cannot collide.
library SwapCache {
    bytes32 private constant _WALLET = keccak256("aml.hook.transient.wallet");
    bytes32 private constant _TOKEN = keccak256("aml.hook.transient.token");
    bytes32 private constant _ORIGIN = keccak256("aml.hook.transient.origin");
    bytes32 private constant _PACKED = keccak256("aml.hook.transient.packed");

    /// @dev packed: decision (8) | feeBps (24) | score (8) | hopDistance (8) | updatedAt (64) | oracleFeeBps (24)
    uint256 private constant _FEE_SHIFT = 8;
    uint256 private constant _SCORE_SHIFT = 32;
    uint256 private constant _HOP_SHIFT = 40;
    uint256 private constant _UPDATED_SHIFT = 48;
    uint256 private constant _ORACLE_FEE_SHIFT = 112;

    function store(
        PoolId poolId,
        address wallet,
        address token,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk memory risk
    ) internal {
        _tstore(_slot(_WALLET, poolId), uint256(uint160(wallet)));
        _tstore(_slot(_TOKEN, poolId), uint256(uint160(token)));
        _tstore(_slot(_ORIGIN, poolId), uint256(uint160(risk.origin)));
        uint256 packed = uint256(uint8(decision)) | (uint256(feeBps) << _FEE_SHIFT)
            | (uint256(risk.score) << _SCORE_SHIFT) | (uint256(risk.hopDistance) << _HOP_SHIFT)
            | (uint256(risk.updatedAt) << _UPDATED_SHIFT) | (uint256(risk.feeBps) << _ORACLE_FEE_SHIFT);
        _tstore(_slot(_PACKED, poolId), packed);
    }

    function load(PoolId poolId)
        internal
        view
        returns (
            address wallet,
            address token,
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        wallet = address(uint160(_tload(_slot(_WALLET, poolId))));
        token = address(uint160(_tload(_slot(_TOKEN, poolId))));
        risk.origin = address(uint160(_tload(_slot(_ORIGIN, poolId))));
        uint256 packed = _tload(_slot(_PACKED, poolId));
        decision = HookDecision(uint8(packed));
        feeBps = uint24(packed >> _FEE_SHIFT);
        risk.score = uint8(packed >> _SCORE_SHIFT);
        risk.hopDistance = uint8(packed >> _HOP_SHIFT);
        risk.updatedAt = uint64(packed >> _UPDATED_SHIFT);
        risk.feeBps = uint24(packed >> _ORACLE_FEE_SHIFT);
    }

    function clear(PoolId poolId) internal {
        _tstore(_slot(_WALLET, poolId), 0);
        _tstore(_slot(_TOKEN, poolId), 0);
        _tstore(_slot(_ORIGIN, poolId), 0);
        _tstore(_slot(_PACKED, poolId), 0);
    }

    function _slot(bytes32 baseSlot, PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(baseSlot, poolId));
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
