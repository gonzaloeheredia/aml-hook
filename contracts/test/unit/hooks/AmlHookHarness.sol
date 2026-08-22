// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {IComplianceOracle} from "interfaces/oracles/IComplianceOracle.sol";

/// @dev Concrete harness to exercise AmlHookLogic without Uniswap v4 BaseHook.
contract AmlHookHarness is AmlHookLogic {
    constructor(
        address accessManager_,
        SanctionRegistry registry_,
        ComplianceOracle oracle_,
        RiskPolicy policy_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    )
        AmlHookLogic(
            accessManager_, registry_, oracle_, policy_, stalenessThreshold_, activityWindow_, maxOpsInWindow_
        )
    {}

    function evaluate(address wallet)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, address(0));
    }

    function evaluate(address wallet, address token, uint256 amount)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, amount);
    }

    function evaluateWithToken(address wallet, address token)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token);
    }

    function evaluateLive(address wallet)
        external
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        (decision, feeBps, risk,) = _evaluateWithMitigationEvents(wallet, address(0));
    }

    function evaluateLiveWithToken(address wallet, address token)
        external
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        (decision, feeBps, risk,) = _evaluateWithMitigationEvents(wallet, token);
    }

    function recordActivity(address wallet) external {
        _recordActivity(wallet);
    }

    function recordActivity(address wallet, address token, uint256 amount) external {
        _recordActivity(wallet, token, amount);
    }

    function updateKnownBalance(address wallet, address token) external {
        _updateKnownBalance(wallet, token, false);
    }

    function observe(
        address wallet,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk calldata risk
    ) external {
        _emitSwapObserved(wallet, decision, feeBps, risk);
    }
}
