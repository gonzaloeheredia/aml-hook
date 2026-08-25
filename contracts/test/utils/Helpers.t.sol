// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";
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
import {IRiskPolicy} from "interfaces/policies/IRiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {MockTrustedRouter} from "../../script/mocks/MockTrustedRouter.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

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
}

/**
 * @title Helpers
 * @notice Shared fixtures and utilities for the AML stack's unit tests.
 */
contract Helpers is Test {
    using LPFeeLibrary for uint24;

    /// Contracts
    HookPoolManagerStub public manager;
    AccessManager public accessManager;
    SanctionRegistry public sanctionRegistry;
    ComplianceOracle public complianceOracle;
    RiskPolicy public riskPolicy;
    AmlHook public hook;

    /// EOAs
    address public owner = makeAddr("owner");
    address public stranger = makeAddr("stranger");
    address public keeper = makeAddr("keeper");
    address public router = makeAddr("router");
    address public registryKeeper = makeAddr("registryKeeper");
    address public oracleKeeper = makeAddr("oracleKeeper");
    address public hookGovernor = makeAddr("hookGovernor");
    address public complianceOfficer = makeAddr("complianceOfficer");
    address public walletA = address(0xA11CE);
    address public walletB = address(0xB0B);
    address public walletC = address(0xC0FFEE);

    uint256 internal constant ATTESTOR_PK = uint256(keccak256("aml.oracle.attestor"));

    function _attestor() internal returns (address) {
        return vm.addr(ATTESTOR_PK);
    }

    /// @dev ECDSA payload the ComplianceOracle attestor must produce (C-01).
    ///      3-arg / 5-arg forms default to nonce=0 (first update on a fresh wallet).
    ///      Use _scoreSigN for subsequent updates on the same wallet (nonce > 0).
    function _scoreSig(address wallet, uint8 score, uint24 feeBps) internal view returns (bytes memory) {
        return _scoreSigN(wallet, score, 0, address(0), feeBps, 0);
    }

    function _scoreSig(address wallet, uint8 score, uint8 hopDistance, address origin, uint24 feeBps)
        internal
        view
        returns (bytes memory)
    {
        return _scoreSigN(wallet, score, hopDistance, origin, feeBps, 0);
    }

    function _scoreSigN(address wallet, uint8 score, uint8 hopDistance, address origin, uint24 feeBps, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hash = keccak256(
            abi.encode(wallet, score, hopDistance, origin, feeBps, uint64(block.timestamp), block.chainid, nonce)
        );
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Trusted IMsgSender stand-in used by hook lifecycle tests (hookData is ignored).
    MockTrustedRouter public trustedRouter;

    function _wireRole(
        AccessManager _manager,
        address _admin,
        address _target,
        bytes4[] memory _selectors,
        uint64 _role,
        address _account
    ) internal {
        vm.startPrank(_admin);
        _manager.setTargetFunctionRole(_target, _selectors, _role);
        _manager.grantRole(_role, _account, 0);
        vm.stopPrank();
    }

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

    function _wireComplianceOfficer(address target, uint32 executionDelay) internal {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = AmlHookGovernance.applyUnscoredThresholds.selector;
        selectors[1] = AmlHookGovernance.applyPoolImpactThresholdBps.selector;
        selectors[2] = AmlHookGovernance.applyFloorFees.selector;
        vm.startPrank(owner);
        accessManager.setTargetFunctionRole(target, selectors, Roles._COMPLIANCE_OFFICER);
        accessManager.grantRole(Roles._COMPLIANCE_OFFICER, complianceOfficer, executionDelay);
        vm.stopPrank();
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

    /// @dev Helper to list an account. Uses commit-reveal (production path). Tests that
    ///      specifically cover the emergency `setSanctioned(..., true)` path call it directly.
    function _sanction(SanctionRegistry _registry, address _caller, address _account) internal {
        bytes32 salt = keccak256(abi.encode(_account, block.number, address(_registry)));
        bytes32 commitHash = keccak256(abi.encode(_account, true, salt));

        vm.prank(_caller);
        _registry.commitSanction(commitHash);

        vm.roll(block.number + _registry.revealDelay() + 1);

        vm.prank(_caller);
        _registry.revealSanction(_account, true, salt);
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
        IFeeEscrow _feeEscrow
    ) internal returns (AmlHook _hook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            )
        );
        deployCodeTo(
            "AmlHook.sol:AmlHook",
            abi.encode(
                IPoolManager(address(manager)),
                address(_accessManager),
                _registry,
                _oracle,
                _riskPolicy,
                _feeEscrow,
                uint256(300),
                uint64(3600)
            ),
            flags
        );
        _hook = AmlHook(flags);
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

    function _in(uint8 score, uint24 rec) internal pure returns (IRiskPolicy.DecisionInput memory i) {
        return _in(score, rec, false, 0);
    }

    function _in(uint8 score, uint24 rec, bool stale, uint32 ops)
        internal
        pure
        returns (IRiskPolicy.DecisionInput memory i)
    {
        i.score = score;
        i.recommendedFeeBps = rec;
        i.isStale = stale;
        i.operationCount = ops;
        i.proportionalFeeBps = 300;
        i.punitiveFeeBps = 800;
    }

    function _usd(
        uint8 score,
        uint24 rec,
        bool stale,
        uint32 ops,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint256 feeTh,
        uint256 revTh
    ) internal pure returns (IRiskPolicy.DecisionInput memory i) {
        i = _in(score, rec, stale, ops);
        i.neverScored = neverScored;
        i.assessedUsd = assessedUsd;
        i.inflowUsd = inflowUsd;
        i.unscoredFeeThreshold = feeTh;
        i.unscoredRevertThreshold = revTh;
    }

    function _fees(IRiskPolicy.DecisionInput memory i, uint24 prop, uint24 pun)
        internal
        pure
        returns (IRiskPolicy.DecisionInput memory)
    {
        i.proportionalFeeBps = prop;
        i.punitiveFeeBps = pun;
        return i;
    }

    function _policy(IRiskPolicy.DecisionInput memory i) internal view returns (IRiskPolicy.DecisionResult memory) {
        return riskPolicy.decide(i);
    }

    function _dec(IRiskPolicy.DecisionInput memory i) internal view returns (HookDecision, uint24) {
        IRiskPolicy.DecisionResult memory r = _policy(i);
        return (r.decision, r.feeBps);
    }
}
