// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {HookDecision} from "../src/libraries/HookDecision.sol";
import {AmlHookLogic} from "../src/hooks/AmlHookLogic.sol";
import {IComplianceOracle} from "../src/interfaces/IComplianceOracle.sol";

/// @dev Concrete harness to exercise AmlHookLogic without Uniswap v4 BaseHook.
contract AmlHookHarness is AmlHookLogic {
    constructor(
        SanctionRegistry registry_,
        ComplianceOracle oracle_,
        RiskPolicy policy_,
        uint64 maxScoreAge_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    ) AmlHookLogic(registry_, oracle_, policy_, maxScoreAge_, activityWindow_, maxOpsInWindow_) {}

    function evaluate(address wallet)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet);
    }

    function evaluateLive(address wallet)
        external
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluateWithMitigationEvents(wallet);
    }

    function recordActivity(address wallet) external {
        _recordActivity(wallet);
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
