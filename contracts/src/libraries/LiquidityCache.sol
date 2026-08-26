// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title EIP-1153 cache from beforeRemoveLiquidity → afterRemoveLiquidity
/// @notice Stores the resolved LP subject and whether the exit is seized.
library LiquidityCache {
    bytes32 private constant _WALLET = keccak256("aml.hook.transient.lp.wallet");
    bytes32 private constant _PACKED = keccak256("aml.hook.transient.lp.packed");
    bytes32 private constant _NONCE = keccak256("aml.hook.transient.lp.nonce");

    /// @dev packed: seize (8) | score (8) | viaTrustedRouter (8)
    uint256 private constant _SCORE_SHIFT = 8;
    uint256 private constant _VIA_SHIFT = 16;

    function store(PoolId poolId, address wallet, bool seize, uint8 score, bool viaTrustedRouter) internal {
        _tstore(_slot(_WALLET, poolId), uint256(uint160(wallet)));
        uint256 packed = (seize ? uint256(1) : 0) | (uint256(score) << _SCORE_SHIFT)
            | (viaTrustedRouter ? uint256(1) << _VIA_SHIFT : 0);
        _tstore(_slot(_PACKED, poolId), packed);
    }

    function load(PoolId poolId)
        internal
        view
        returns (address wallet, bool seize, uint8 score, bool viaTrustedRouter)
    {
        wallet = address(uint160(_tload(_slot(_WALLET, poolId))));
        uint256 packed = _tload(_slot(_PACKED, poolId));
        seize = uint8(packed) != 0;
        score = uint8(packed >> _SCORE_SHIFT);
        viaTrustedRouter = uint8(packed >> _VIA_SHIFT) != 0;
    }

    function clear(PoolId poolId) internal {
        _tstore(_slot(_WALLET, poolId), 0);
        _tstore(_slot(_PACKED, poolId), 0);
        _tstore(_nonceSlot(poolId), _tload(_nonceSlot(poolId)) + 1);
    }

    function _slot(bytes32 baseSlot, PoolId poolId) private view returns (bytes32) {
        return keccak256(abi.encode(baseSlot, poolId, _tload(_nonceSlot(poolId))));
    }

    function _nonceSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(_NONCE, poolId));
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
