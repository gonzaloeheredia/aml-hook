// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title Minimal BaseHook (PoolManager-gated IHooks)
/// @dev Local stand-in for OpenZeppelin / periphery BaseHook so AML Hook compiles
///      against Uniswap v4-core without a separate hooks package.
abstract contract BaseHook is IHooks {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
        validateHookAddress(this);
    }

    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    function validateHookAddress(BaseHook hook) internal pure {
        Hooks.validateHookPermissions(hook, getHookPermissions());
    }

    // ─── Initialize ──────────────────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    // ─── Liquidity ───────────────────────────────────────────────────────────

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    // ─── Swap ────────────────────────────────────────────────────────────────

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    // ─── Donate ──────────────────────────────────────────────────────────────

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
