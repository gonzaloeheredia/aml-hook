// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
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
        uint64 activityWindow_
    ) AmlHookGovernance(accessManager_, registry_, oracle_, policy_, stalenessThreshold_, activityWindow_) {}

    function evaluate(address wallet)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, address(0), address(0), 0, 0);
    }

    function evaluate(address wallet, address token, uint256 amount)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, amount, 0);
    }

    function evaluate(address wallet, address token, uint256 amount, uint256 poolImpactBps)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, amount, poolImpactBps);
    }

    function evaluateWithToken(address wallet, address token)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, 0, 0);
    }

    function evaluateLive(address wallet)
        external
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        SwapEvaluation memory eval = _evaluateLive(wallet, address(0), address(0), 0, 0);
        return (eval.decision, eval.feeBps, eval.risk);
    }

    function evaluateLiveWithToken(address wallet, address token)
        external
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        SwapEvaluation memory eval = _evaluateLive(wallet, token, token, 0, 0);
        return (eval.decision, eval.feeBps, eval.risk);
    }

    function evaluateLive(address wallet, address token, uint256 amount)
        external
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        SwapEvaluation memory eval = _evaluateLive(wallet, token, token, amount, 0);
        return (eval.decision, eval.feeBps, eval.risk);
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
