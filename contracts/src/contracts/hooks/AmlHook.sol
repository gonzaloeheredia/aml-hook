// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AmlHookLogic} from "./AmlHookLogic.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {SwapCache} from "../../libraries/SwapCache.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Minimal ERC-20 surface for approving FeeEscrow.deposit's transferFrom.
interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title AMLHook — Uniswap v4 compliance hook (REAL on-chain logic)
/// @notice Orchestrator at swap time (whitepaper §3.1 / §3.5 / §3.7 / §3.9).
/// @dev Uses the official BaseHook from @uniswap/v4-periphery (`v4-periphery/src/utils/BaseHook.sol`).
///
///      FEE SPLIT (whitepaper §3.7 + FeeEscrow via afterSwap):
///      Pool = standard LP fee. Escrow = risk differential on FEE_OVERRIDE only.
///      beforeSwap does not set punitive lpFeeOverride; afterSwap takes the
///      differential via poolManager.take → FeeEscrow.deposit.
///      differentialBps = max(0, feeBps - STANDARD_FEE_BPS).
contract AmlHook is BaseHook, AmlHookLogic, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    /// @notice Pool base fee in bps (0.30%) — left to the PoolManager; not overridden.
    uint24 public constant STANDARD_FEE_BPS = FeeBps.STANDARD;

    /// @notice Escrow for FEE_OVERRIDE differential fees (§3.7). address(0) disables take/deposit.
    IFeeEscrow public immutable feeEscrow;

    /// @notice Emitted when the risk differential was taken and deposited into FeeEscrow.
    event RiskFeeEscrowed(
        address indexed wallet, address indexed token, uint256 amount, uint256 escrowId, uint24 feeBps
    );

    /// @notice Emitted when the risk fee is not taken (zero basis or escrow token mismatch).
    event RiskFeeSkipped(address indexed wallet, address indexed token, uint24 feeBps, string reason);

    error FeeTransferFailed();
    error FeeApproveFailed();

    /// @dev Extra entropy mixed into `swapFingerprint` (L-01), on top of `nextEscrowId`.
    uint256 private _fingerprintNonce;

    constructor(
        IPoolManager poolManager_,
        address accessManager_,
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        IFeeEscrow feeEscrow_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    )
        BaseHook(poolManager_)
        AmlHookLogic(
            accessManager_,
            sanctionRegistry_,
            complianceOracle_,
            riskPolicy_,
            stalenessThreshold_,
            activityWindow_,
            maxOpsInWindow_
        )
    {
        feeEscrow = feeEscrow_;
    }

    /// @inheritdoc BaseHook
    /// @notice beforeSwap + afterSwap + afterSwapReturnDelta (required to take the risk fee),
    ///         plus beforeAddLiquidity (pause + sanctions on LP entry) and beforeRemoveLiquidity
    ///         (always permitted — no sanction or pause gate).
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    /// @notice Blocks a sanctioned wallet from entering as a liquidity provider.
    /// @dev In Uniswap v4 the liquidity-hook `sender` is the PoolManager `msg.sender` of
    ///      `modifyLiquidity` — the LP itself. There is no router intermediary, so the
    ///      subject is `sender` directly (not `_resolveWallet`). Pause stops new exposure
    ///      (swaps and new LP deposits); exits stay open in `_beforeRemoveLiquidity`.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        _requireNotPaused();
        _requireNotSanctioned(sender);
        return this.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    /// @notice LP exit is always permitted — no sanction or pause gate here.
    /// @dev M-02: not screening sanctions on removal is a deliberate legal choice of
    ///      non-confiscation: capital already in the pool must remain withdrawable.
    ///      This is pending confirmation by compliance counsel. Do not add a sanctions
    ///      check here until that definition is written and a recovery path exists.
    function _beforeRemoveLiquidity(
        address /* sender */,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    /// @notice Point-of-execution control before funds move (§3.9 Step 5).
    /// @dev On FEE_OVERRIDE we intentionally return lpFee = 0 so the pool keeps its
    ///      standard fee. The risk differential is collected in afterSwap → FeeEscrow.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        address wallet = _resolveWallet(sender);
        address token = _inputToken(key, params);

        (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk, bool inflowTriggered)
            = _evaluateWithMitigationEvents(wallet, token);

        SwapCache.store(key.toId(), wallet, token, decision, feeBps, risk, inflowTriggered);

        // ALLOW and FEE_OVERRIDE: do not override pool LP fee (standard path).
        // REVERT already reverted inside evaluate.
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc BaseHook
    /// @notice afterSwap: pool-local memory + SwapObserved + optional FeeEscrow deposit (§3.7 / §3.9 Step 7).
    /// @dev On FEE_OVERRIDE with a live feeEscrow, takes differentialBps of actual output
    ///      (exactIn) or input (exactOut) via poolManager.take, then FeeEscrow.deposit.
    ///      Returns the same amount as int128 so PoolManager nets the hook delta (afterSwapReturnDelta).
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        (
            address wallet,
            address swapToken,
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        ) = SwapCache.load(key.toId());
        SwapCache.clear(key.toId());

        _recordActivity(wallet);
        _updateKnownBalance(wallet, swapToken, inflowTriggered);
        _emitSwapObserved(wallet, decision, feeBps, risk);

        int128 hookDelta = 0;
        if (decision == HookDecision.FEE_OVERRIDE && address(feeEscrow) != address(0) && feeBps > 0) {
            hookDelta = _escrowRiskFee(wallet, key, params, delta, feeBps);
        }

        return (this.afterSwap.selector, hookDelta);
    }

    /// @dev Take differential risk fee from the swap and deposit into FeeEscrow.
    ///      Follows Uniswap v4 afterSwap custom-accounting guide (unspecified currency).
    function _escrowRiskFee(
        address wallet,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint24 feeBps
    ) private returns (int128 hookDelta) {
        // Differential above the pool's standard fee (keeps total friction ≈ max(feeBps, standard)).
        uint256 differentialBps =
            feeBps > STANDARD_FEE_BPS ? uint256(feeBps) - uint256(STANDARD_FEE_BPS) : 0;
        if (differentialBps == 0) return 0;

        bool isExactIn = params.amountSpecified < 0;
        bool outputIsToken0 = !params.zeroForOne;

        // Fee is charged on the unspecified currency (guide): output for exactIn, input for exactOut.
        Currency feeCurrency;
        int256 basisAmount;
        if (isExactIn) {
            feeCurrency = outputIsToken0 ? key.currency0 : key.currency1;
            basisAmount = outputIsToken0 ? delta.amount0() : delta.amount1();
        } else {
            bool inputIsToken0 = params.zeroForOne;
            feeCurrency = inputIsToken0 ? key.currency0 : key.currency1;
            // Input amount owed by the user is negative in the swap delta.
            int256 inputDelta = inputIsToken0 ? delta.amount0() : delta.amount1();
            basisAmount = inputDelta < 0 ? -inputDelta : int256(0);
        }

        address token = Currency.unwrap(feeCurrency);
        if (basisAmount <= 0) {
            emit RiskFeeSkipped(wallet, token, feeBps, "ZERO_BASIS");
            return 0;
        }

        uint256 feeAmount = (uint256(basisAmount) * differentialBps) / 10_000;
        if (feeAmount == 0) return 0;
        if (feeAmount > uint256(uint128(type(int128).max))) revert FeeTransferFailed();

        // Effects complete. Interactions last (H-06): take → approve → deposit.
        if (!feeEscrow.allowedFeeTokens(token)) {
            emit RiskFeeSkipped(wallet, token, feeBps, "FEE_TOKEN_NOT_ALLOWED");
            return 0;
        }
        if (token != address(feeEscrow.feeToken())) {
            emit RiskFeeSkipped(wallet, token, feeBps, "FEE_TOKEN_MISMATCH");
            return 0;
        }

        uint256 nonce = ++_fingerprintNonce;
        bytes32 swapFingerprint = keccak256(
            abi.encode(
                wallet, token, feeAmount, block.number, block.timestamp, feeEscrow.nextEscrowId(), nonce
            )
        );

        poolManager.take(feeCurrency, address(this), feeAmount);
        IERC20Approve(token).approve(address(feeEscrow), 0);
        if (!IERC20Approve(token).approve(address(feeEscrow), feeAmount)) revert FeeApproveFailed();

        try feeEscrow.deposit(wallet, swapFingerprint, feeAmount) returns (uint256 escrowId) {
            emit RiskFeeEscrowed(wallet, token, feeAmount, escrowId, feeBps);
        } catch {
            emit RiskFeeSkipped(wallet, token, feeBps, "DEPOSIT_FAILED");
        }
        return int128(int256(feeAmount));
    }

    /// @dev Input currency of this swap — used by §3.8 Mitigation D.
    function _inputToken(PoolKey calldata key, SwapParams calldata params)
        private
        pure
        returns (address)
    {
        Currency c = params.zeroForOne ? key.currency0 : key.currency1;
        return Currency.unwrap(c);
    }
}
