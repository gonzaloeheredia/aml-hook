// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {AmlHook} from "contracts/hooks/AmlHook.sol";
import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {IComplianceTreasury} from "interfaces/treasury/IComplianceTreasury.sol";
import {Roles} from "libraries/Roles.sol";
import {MockTrustedRouter} from "../../script/mocks/MockTrustedRouter.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {HelpersCore} from "test/utils/HelpersCore.t.sol";

/// @notice Stand-in PoolManager so `AmlHook.onlyPoolManager` can be exercised in hook tests.
/// @dev `take` forwards ERC-20 from this stub to `to` (mint tokens here before FEE_OVERRIDE afterSwap tests).
contract HookPoolManagerStub {
    /// @dev 1:1 sqrtPriceX96. Returned from every `extsload` so StateLibrary.getSlot0 /
    ///      getLiquidity succeed. Liquidity slot then reads as 2^96 — impact ≈ 0 unless a
    ///      test overrides via a richer stub.
    uint256 internal constant STUB_SQRT_PRICE_X96 = 79228162514264337593543950336;

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(STUB_SQRT_PRICE_X96);
    }

    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "stub: take transfer failed");
    }

    function callBeforeSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return hook.beforeSwap(sender, key, params, hookData);
    }

    function callAfterSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return hook.afterSwap(sender, key, params, delta, hookData);
    }

    function callBeforeAddLiquidity(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return hook.beforeAddLiquidity(sender, key, params, hookData);
    }

    function callBeforeRemoveLiquidity(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        return hook.beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function callAfterRemoveLiquidity(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return hook.afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }
}

/**
 * @title Helpers
 * @notice Shared fixtures and utilities for the AML stack's unit tests.
 */
contract Helpers is HelpersCore {
    using LPFeeLibrary for uint24;

    HookPoolManagerStub public manager;
    AmlHook public hook;

    /// @dev Trusted IMsgSender stand-in used by hook lifecycle tests (hookData is ignored).
    MockTrustedRouter public trustedRouter;

    /// @dev Wires `_HOOK_GOVERNOR` so tests can `setTrustedRouter`.
    function _wireHookGovernor() internal {
        bytes4[] memory hookSelectors = new bytes4[](15);
        hookSelectors[0] = AmlHookGovernance.setStalenessThreshold.selector;
        hookSelectors[1] = AmlHookGovernance.setInflowThresholdBps.selector;
        hookSelectors[2] = AmlHookGovernance.setTrustedRouter.selector;
        hookSelectors[3] = AmlHookGovernance.pause.selector;
        hookSelectors[4] = AmlHookGovernance.unpause.selector;
        hookSelectors[5] = AmlHookGovernance.setTrustedMultisig.selector;
        hookSelectors[6] = AmlHookGovernance.setMultisigAggregation.selector;
        hookSelectors[7] = AmlHookGovernance.setMinBaselineInterval.selector;
        hookSelectors[8] = AmlHookGovernance.setPriceFeed.selector;
        hookSelectors[9] = AmlHookGovernance.setPriceStalenessThreshold.selector;
        hookSelectors[10] = AmlHookGovernance.setActivityWindow.selector;
        hookSelectors[11] = AmlHookLogic.observeSwap.selector;
        hookSelectors[12] = AmlHookLogic.syncBaseline.selector;
        hookSelectors[13] = AmlHookGovernance.setDailyWindow.selector;
        hookSelectors[14] = AmlHook.approveFailedDepositRefund.selector;
        _wireRole(accessManager, owner, address(hook), hookSelectors, Roles._HOOK_GOVERNOR, hookGovernor);
    }

    /// @dev Wires `_COMPLIANCE_OFFICER` apply selectors. Delay 0 so most unit tests can confirm instantly.
    function _wireComplianceOfficer() internal {
        _wireComplianceOfficer(address(hook), 0);
    }

    MockAggregatorV3 public usdFeed;

    /// @dev Bind a $1 Chainlink stand-in for stub pool currencies (address(1)/address(2)) and native ETH.
    function _bindUsdFeeds() internal {
        usdFeed = new MockAggregatorV3();
        usdFeed.setRound(1e8, block.timestamp);
        vm.startPrank(hookGovernor);
        hook.setPriceFeed(address(0), address(usdFeed));
        hook.setPriceFeed(address(1), address(usdFeed));
        hook.setPriceFeed(address(2), address(usdFeed));
        vm.stopPrank();
    }

    /// @dev Register a MockTrustedRouter (once) and set the end-user it reports via `msgSender()`.
    function _bindTrustedSubject(address subject) internal returns (address sender) {
        if (address(trustedRouter) == address(0)) {
            trustedRouter = new MockTrustedRouter();
            vm.prank(hookGovernor);
            hook.setTrustedRouter(address(trustedRouter), true);
        }
        trustedRouter.setMsgSender(subject);
        return address(trustedRouter);
    }

    /**
     * @notice Deploys `AmlHook` at an address whose low bits already carry its permission flags.
     * @param _feeEscrow FeeEscrow for afterSwap deposits, or address(0) to disable escrow path.
     */
    function _deployHook(
        AccessManager _accessManager,
        SanctionRegistry _registry,
        ComplianceOracle _oracle,
        RiskPolicy _riskPolicy,
        IFeeEscrow _feeEscrow,
        IComplianceTreasury _treasury
    ) internal returns (AmlHook _hook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo(
            "AmlHook.sol:AmlHook",
            abi.encode(IPoolManager(address(manager)), address(_accessManager)),
            flags
        );
        _hook = AmlHook(flags);
        _hook.initialize(_registry, _oracle, _riskPolicy, _feeEscrow, _treasury, uint256(300), uint64(3600));
    }

    function _deployHook(
        AccessManager _accessManager,
        SanctionRegistry _registry,
        ComplianceOracle _oracle,
        RiskPolicy _riskPolicy,
        IFeeEscrow _feeEscrow
    ) internal returns (AmlHook _hook) {
        return _deployHook(_accessManager, _registry, _oracle, _riskPolicy, _feeEscrow, IComplianceTreasury(address(0)));
    }

    /// @dev Convenience: deploy hook with FeeEscrow disabled.
    function _deployHook(
        AccessManager _accessManager,
        SanctionRegistry _registry,
        ComplianceOracle _oracle,
        RiskPolicy _riskPolicy
    ) internal returns (AmlHook _hook) {
        return _deployHook(_accessManager, _registry, _oracle, _riskPolicy, IFeeEscrow(address(0)));
    }

    function _buildKey(address _hook) internal pure returns (PoolKey memory _key) {
        _key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(_hook)
        });
    }

    function _buildParams() internal pure returns (SwapParams memory _params) {
        _params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    /// @dev `liquidityDelta` sign only matters to v4-core's own dispatch (add vs remove); the hook
    ///      callbacks under test are called directly, so either sign exercises the same gate.
    function _buildLiquidityParams(int256 _liquidityDelta)
        internal
        pure
        returns (ModifyLiquidityParams memory _params)
    {
        _params = ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: _liquidityDelta,
            salt: bytes32(0)
        });
    }
}
