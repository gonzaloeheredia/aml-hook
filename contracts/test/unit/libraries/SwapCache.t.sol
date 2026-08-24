// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IComplianceOracle} from "interfaces/oracles/IComplianceOracle.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {SwapCache} from "libraries/SwapCache.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @dev Concrete wrapper so unit tests can hit the EIP-1153 library.
contract SwapCacheHarness {
    function store(
        bytes32 poolId,
        address wallet,
        address token,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk memory risk,
        bool inflowTriggered
    ) external {
        SwapCache.store(PoolId.wrap(poolId), wallet, token, decision, feeBps, risk, inflowTriggered);
    }

    function load(bytes32 poolId)
        external
        view
        returns (
            address wallet,
            address token,
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        )
    {
        return SwapCache.load(PoolId.wrap(poolId));
    }

    function clear(bytes32 poolId) external {
        SwapCache.clear(PoolId.wrap(poolId));
    }
}

/// @notice Unit + fuzz coverage for `SwapCache` (beforeSwap → afterSwap transient snapshot).
contract UnitSwapCacheTest is Test {
    SwapCacheHarness internal cache;

    function setUp() public {
        cache = new SwapCacheHarness();
    }

    function _risk(uint8 score, uint8 hop, address origin, uint24 feeBps, uint64 updatedAt)
        internal
        pure
        returns (IComplianceOracle.WalletRisk memory risk)
    {
        risk.score = score;
        risk.hopDistance = hop;
        risk.origin = origin;
        risk.feeBps = feeBps;
        risk.updatedAt = updatedAt;
    }

    function test_StoreLoad_RoundTripsSnapshot() external {
        bytes32 poolId = keccak256("pool");
        IComplianceOracle.WalletRisk memory risk = _risk(42, 2, address(0xA11CE), 300, 1_700_000_000);

        cache.store(poolId, address(0xB0B), address(0xFEE), HookDecision.FEE_OVERRIDE, 800, risk, true);

        (
            address wallet,
            address token,
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory loaded,
            bool inflow
        ) = cache.load(poolId);

        assertEq(wallet, address(0xB0B));
        assertEq(token, address(0xFEE));
        assertEq(uint8(decision), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(feeBps, 800);
        assertEq(loaded.score, 42);
        assertEq(loaded.hopDistance, 2);
        assertEq(loaded.origin, address(0xA11CE));
        assertEq(loaded.feeBps, 300);
        assertEq(loaded.updatedAt, 1_700_000_000);
        assertTrue(inflow);
    }

    function test_Clear_WipesSnapshotAndBumpsNonce() external {
        bytes32 poolId = keccak256("pool");
        cache.store(
            poolId, address(1), address(2), HookDecision.ALLOW, 0, _risk(0, 0, address(0), 0, 1), false
        );
        cache.clear(poolId);

        (address wallet, address token, HookDecision decision, uint24 feeBps,, bool inflow) = cache.load(poolId);
        assertEq(wallet, address(0));
        assertEq(token, address(0));
        assertEq(uint8(decision), uint8(HookDecision.ALLOW));
        assertEq(feeBps, 0);
        assertFalse(inflow);

        cache.store(
            poolId, address(3), address(4), HookDecision.REVERT, 0, _risk(100, 0, address(5), 0, 9), true
        );
        (wallet, token, decision,,,) = cache.load(poolId);
        assertEq(wallet, address(3));
        assertEq(token, address(4));
        assertEq(uint8(decision), uint8(HookDecision.REVERT));
    }

    function test_DistinctPoolIds_DoNotCollide() external {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        cache.store(a, address(1), address(11), HookDecision.ALLOW, 0, _risk(0, 0, address(0), 0, 1), false);
        cache.store(
            b, address(2), address(22), HookDecision.FEE_OVERRIDE, 300, _risk(40, 1, address(9), 300, 2), true
        );

        (address walletA,,,,,) = cache.load(a);
        (address walletB, address tokenB, HookDecision dB, uint24 feeB,, bool inflowB) = cache.load(b);
        assertEq(walletA, address(1));
        assertEq(walletB, address(2));
        assertEq(tokenB, address(22));
        assertEq(uint8(dB), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(feeB, 300);
        assertTrue(inflowB);
    }

    function testFuzz_StoreLoad_PreservesPackedFields(
        bytes32 poolId,
        address wallet,
        address token,
        uint8 decisionRaw,
        uint24 feeBps,
        uint8 score,
        uint8 hop,
        address origin,
        uint24 oracleFee,
        uint64 updatedAt,
        bool inflow
    ) external {
        HookDecision decision = HookDecision(uint8(bound(decisionRaw, 0, 2)));

        cache.store(poolId, wallet, token, decision, feeBps, _risk(score, hop, origin, oracleFee, updatedAt), inflow);

        (
            address loadedWallet,
            address loadedToken,
            HookDecision loadedDecision,
            uint24 loadedFee,
            IComplianceOracle.WalletRisk memory loaded,
            bool loadedInflow
        ) = cache.load(poolId);

        assertEq(loadedWallet, wallet);
        assertEq(loadedToken, token);
        assertEq(uint8(loadedDecision), uint8(decision));
        assertEq(loadedFee, feeBps);
        assertEq(loaded.score, score);
        assertEq(loaded.hopDistance, hop);
        assertEq(loaded.origin, origin);
        assertEq(loaded.feeBps, oracleFee);
        assertEq(loaded.updatedAt, updatedAt);
        assertEq(loadedInflow, inflow);
    }
}
