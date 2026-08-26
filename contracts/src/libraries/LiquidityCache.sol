// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {HookDecision} from "./HookDecision.sol";

/// @title EIP-1153 cache from before{Add,Remove}Liquidity → after{Add,Remove}Liquidity
/// @notice Stores the resolved LP subject, add decision / fee, and whether a remove is seized.
library LiquidityCache {
    bytes32 private constant _WALLET = keccak256("aml.hook.transient.lp.wallet");
    bytes32 private constant _PACKED = keccak256("aml.hook.transient.lp.packed");
    bytes32 private constant _NONCE = keccak256("aml.hook.transient.lp.nonce");

    /// @dev packed: seize (8) | score (8) | viaTrustedRouter (8) | neverScored (8) | decision (8) | feeBps (24)
    uint256 private constant _SCORE_SHIFT = 8;
    uint256 private constant _VIA_SHIFT = 16;
    uint256 private constant _NEVER_SHIFT = 24;
    uint256 private constant _DECISION_SHIFT = 32;
    uint256 private constant _FEE_SHIFT = 40;

    /// @notice Snapshot written in `beforeAddLiquidity` / `beforeRemoveLiquidity`.
    function store(
        PoolId poolId,
        address wallet,
        bool seize,
        uint8 score,
        bool viaTrustedRouter,
        bool neverScored,
        HookDecision decision,
        uint24 feeBps
    ) internal {
        _tstore(_slot(_WALLET, poolId), uint256(uint160(wallet)));
        uint256 packed = (seize ? uint256(1) : 0) | (uint256(score) << _SCORE_SHIFT)
            | (viaTrustedRouter ? uint256(1) << _VIA_SHIFT : 0)
            | (neverScored ? uint256(1) << _NEVER_SHIFT : 0)
            | (uint256(uint8(decision)) << _DECISION_SHIFT) | (uint256(feeBps) << _FEE_SHIFT);
        _tstore(_slot(_PACKED, poolId), packed);
    }

    /// @notice Read the snapshot for this `poolId`.
    function load(PoolId poolId)
        internal
        view
        returns (
            address wallet,
            bool seize,
            uint8 score,
            bool viaTrustedRouter,
            bool neverScored,
            HookDecision decision,
            uint24 feeBps
        )
    {
        wallet = address(uint160(_tload(_slot(_WALLET, poolId))));
        uint256 packed = _tload(_slot(_PACKED, poolId));
        seize = uint8(packed) != 0;
        score = uint8(packed >> _SCORE_SHIFT);
        viaTrustedRouter = uint8(packed >> _VIA_SHIFT) != 0;
        neverScored = uint8(packed >> _NEVER_SHIFT) != 0;
        decision = HookDecision(uint8(packed >> _DECISION_SHIFT));
        feeBps = uint24(packed >> _FEE_SHIFT);
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
