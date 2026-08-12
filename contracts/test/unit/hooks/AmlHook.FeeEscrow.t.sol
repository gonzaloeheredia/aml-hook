// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {FeeEscrow} from "contracts/escrow/FeeEscrow.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {Roles} from "libraries/Roles.sol";
import {MockFeeToken} from "../../../script/mocks/MockFeeToken.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice FEE_OVERRIDE afterSwap path: take differential → FeeEscrow.deposit.
contract UnitAmlHookFeeEscrowTest is Helpers {
    MockFeeToken feeToken;
    FeeEscrow escrow;
    PoolKey key;
    SwapParams params;

    event RiskFeeEscrowed(
        address indexed wallet, address indexed token, uint256 amount, uint256 escrowId, uint24 feeBps
    );

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager));
        riskPolicy = new RiskPolicy();

        feeToken = new MockFeeToken();
        escrow = new FeeEscrow(owner, address(feeToken), owner, owner);

        hook = _deployHook(
            accessManager, sanctionRegistry, complianceOracle, riskPolicy, IFeeEscrow(address(escrow))
        );

        vm.prank(owner);
        escrow.setDepositor(address(hook), true);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        // zeroForOne exactIn → output is currency1 = feeToken (escrow custody asset).
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(feeToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function test_AfterSwap_FeeOverride_DepositsDifferentialIntoEscrow() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");

        // Output basis = 1e18 → differential 770 bps → 7.7e16
        int128 amount0 = -1e18;
        int128 amount1 = 1e18;
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        uint256 expectedFee = (uint256(uint128(amount1)) * 770) / 10_000;

        feeToken.mint(address(manager), expectedFee);

        bytes memory data = abi.encode(walletB);
        (,, uint24 lpFee) = manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertEq(lpFee, 0);

        vm.expectEmit(true, true, false, true, address(hook));
        emit RiskFeeEscrowed(walletB, address(feeToken), expectedFee, 1, 800);

        (bytes4 sel, int128 hookDelta) =
            manager.callAfterSwap(IHooks(address(hook)), router, key, params, delta, data);

        assertEq(sel, hook.afterSwap.selector);
        assertEq(uint256(uint128(hookDelta)), expectedFee);
        assertEq(feeToken.balanceOf(address(escrow)), expectedFee);

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(1);
        assertEq(rec.wallet, walletB);
        assertEq(rec.amount, expectedFee);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Active));
    }

    function test_AfterSwap_Allow_SkipsEscrow() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, "");

        feeToken.mint(address(manager), 1e18);
        bytes memory data = abi.encode(walletC);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);

        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), router, key, params, toBalanceDelta(-1e18, 1e18), data
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
        assertEq(feeToken.balanceOf(address(manager)), 1e18);
    }

    function test_AfterSwap_FeeOverride_SkipsWhenCurrencyMismatch() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");

        // Output is currency0 (oneForZero), not the escrow feeToken.
        SwapParams memory oneForZero =
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        bytes memory data = abi.encode(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, oneForZero, data);

        feeToken.mint(address(manager), 1e18);
        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), router, key, oneForZero, toBalanceDelta(1e18, -1e18), data
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
    }

    function test_AfterSwap_FeeOverride_ExactOut_DepositsOnInputCurrency() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");

        // exactOut oneForZero: input is currency1 = feeToken.
        SwapParams memory exactOut =
            SwapParams({zeroForOne: false, amountSpecified: int256(1e18), sqrtPriceLimitX96: 0});
        int128 amount0 = 1e18; // output
        int128 amount1 = -1e18; // input owed
        uint256 expectedFee = (uint256(uint128(1e18)) * 770) / 10_000;
        feeToken.mint(address(manager), expectedFee);

        bytes memory data = abi.encode(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, exactOut, data);

        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), router, key, exactOut, toBalanceDelta(amount0, amount1), data
        );

        assertEq(uint256(uint128(hookDelta)), expectedFee);
        assertEq(feeToken.balanceOf(address(escrow)), expectedFee);
    }
}

/// @notice FEE_OVERRIDE with feeEscrow disabled (separate suite: hook address is etched once).
contract UnitAmlHookFeeEscrowDisabledTest is Helpers {
    MockFeeToken feeToken;
    PoolKey key;
    SwapParams params;

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager));
        riskPolicy = new RiskPolicy();
        feeToken = new MockFeeToken();

        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(feeToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function test_AfterSwap_FeeOverride_SkipsWhenFeeEscrowDisabled() external {
        assertEq(address(hook.feeEscrow()), address(0));

        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");
        feeToken.mint(address(manager), 1e18);

        bytes memory data = abi.encode(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        (, int128 hookDelta) = manager.callAfterSwap(
            IHooks(address(hook)), router, key, params, toBalanceDelta(-1e18, 1e18), data
        );

        assertEq(hookDelta, 0);
        assertEq(feeToken.balanceOf(address(manager)), 1e18);
    }
}
