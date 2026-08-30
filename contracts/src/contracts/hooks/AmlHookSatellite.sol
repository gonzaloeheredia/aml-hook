// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookLogic} from "./AmlHookLogic.sol";
import {AmlHookGovernanceBase} from "./AmlHookGovernanceBase.sol";

import {HookDecision} from "../../libraries/HookDecision.sol";
import {OracleQuote} from "../../libraries/OracleQuote.sol";
import {SwapCache} from "../../libraries/SwapCache.sol";
import {SwapCurrencies} from "../../libraries/SwapCurrencies.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title AmlHookSatellite — evaluation and governance satellite for AmlHook
/// @notice Deployed once; called exclusively via DELEGATECALL from AmlHook so all state
///         reads/writes operate on AmlHook's storage. Contains: full swap/LP evaluation
///         (AmlHookLogic), governance setters (AmlHookGovernance), and the external
///         wrapper selectors that AmlHook's callbacks dispatch to.
///
/// @dev Storage layout (inherited base order):
///      [0] AccessManaged + Pausable (packed)
///      [1] AmlHookGovernanceBase.sanctionRegistry
///      [2..] remaining GovernanceBase + AmlHookActivity
///      (AmlHookLogic / AmlHookSatellite add no storage)
///
///      AmlHook must list Activity / Governance before Settlement so this prefix
///      lands in the same slots. DELEGATECALL then reads `sanctionRegistry` rather
///      than `complianceTreasury`.
///
///      The poolManager immutable is embedded in this bytecode and must equal
///      AmlHook's poolManager; pass the same address to the constructor.
contract AmlHookSatellite is AmlHookLogic {
    constructor(IPoolManager poolManager_, address accessManager_)
        AmlHookGovernanceBase(accessManager_)
    {
        // poolManager is declared immutable in ImmutableState (BaseHook ancestor).
        // Because ImmutableState is NOT in this contract's base chain (only AmlHook
        // inherits AmlHookSettlement → BaseHook → ImmutableState), we store the pool
        // manager reference in a dedicated immutable here so SwapCurrencies helpers work.
        _satellitePoolManager = poolManager_;
    }

    // ---------------------------------------------------------------------------
    // Satellite-private immutable (avoids BaseHook dependency)
    // ---------------------------------------------------------------------------

    IPoolManager private immutable _satellitePoolManager;

    // ---------------------------------------------------------------------------
    // Swap path wrappers — called from AmlHook via DELEGATECALL
    // ---------------------------------------------------------------------------

    /// @notice Evaluate the swap and write results to EIP-1153 transient storage.
    ///         AmlHook.beforeSwap calls this; AmlHook.afterSwap reads the cache.
    function satelliteBeginSwap(address sender, PoolKey calldata key, SwapParams calldata params) external {
        SwapEvaluation memory ev = _beginSwap(
            sender,
            SwapCurrencies.inputToken(key, params),
            SwapCurrencies.specifiedToken(key, params),
            SwapCurrencies.abs(params.amountSpecified),
            SwapCurrencies.poolImpactBps(_satellitePoolManager, key, params)
        );
        SwapCache.store(key.toId(), ev.wallet, ev.token, ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered);
        SwapCache.storeFx(key.toId(), ev.volumeFx.price, OracleQuote.pack(ev.volumeFx));
    }

    /// @notice Load the evaluation from transient storage, clear the cache, record activity.
    /// @return decision  The compliance decision from beforeSwap.
    /// @return wallet    The resolved compliance subject.
    /// @return feeBps    The override fee (0 on ALLOW / REVERT).
    function satelliteEndSwap(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        external
        returns (HookDecision decision, address wallet, uint24 feeBps)
    {
        SwapEvaluation memory ev;
        (ev.wallet, ev.token, ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered) = SwapCache.load(key.toId());
        (uint256 price, uint256 packed) = SwapCache.loadFx(key.toId());
        SwapCache.clear(key.toId());
        ev.volumeFx = OracleQuote.unpack(price, packed);
        _endSwap(ev, SwapCurrencies.specifiedToken(key, params), SwapCurrencies.settledSpecified(key, params, delta));
        return (ev.decision, ev.wallet, ev.feeBps);
    }

    // ---------------------------------------------------------------------------
    // Liquidity path wrappers
    // ---------------------------------------------------------------------------

    /// @notice L1 + score check for LP adds. Returns cache data for LiquidityCache.store.
    function satelliteGuardAddLiquidity(address sender)
        external
        returns (address wallet, bool viaRouter, bool neverScored, HookDecision decision, uint24 feeBps, uint8 score)
    {
        return _guardAddLiquidity(sender);
    }

    /// @notice Never-scored Floor A/C/D for afterAddLiquidity (token deltas exist).
    function satelliteEvaluateNeverScoredAdd(
        address wallet,
        bool viaRouter,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 impact
    ) external returns (HookDecision decision, uint24 feeBps) {
        return _evaluateNeverScoredAdd(wallet, viaRouter, token0, token1, amount0, amount1, impact);
    }

    /// @notice L1 or score ≥ 71 check for LP removes.
    function satelliteEvaluateRemoveLiquidity(address sender)
        external
        returns (address wallet, bool seize, uint8 score, bool viaRouter)
    {
        return _evaluateRemoveLiquidity(sender);
    }
}
