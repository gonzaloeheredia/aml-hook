// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISanctionRegistry} from "../interfaces/ISanctionRegistry.sol";
import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";
import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Shared beforeSwap decision logic for AMLHook
/// @dev Used by AmlHook (PoolManager-gated). L1 → L2 → L3.
abstract contract AmlHookLogic {
    ISanctionRegistry public immutable sanctionRegistry;
    IComplianceOracle public immutable complianceOracle;
    IRiskPolicy public immutable riskPolicy;

    error WalletBlocked(address wallet, uint8 score, string reason);
    error SanctionHit(address wallet);

    event SwapObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        uint24 feeBps,
        uint8 hopDistance,
        address origin
    );

    event WalletBlockedEvent(
        address indexed wallet,
        uint8 score,
        string reason
    );

    constructor(
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_
    ) {
        sanctionRegistry = sanctionRegistry_;
        complianceOracle = complianceOracle_;
        riskPolicy = riskPolicy_;
    }

    /// @notice Evaluate a swap subject. Reverts on REVERT / sanctions.
    /// @return decision ALLOW or FEE_OVERRIDE
    /// @return feeBps Override fee when FEE_OVERRIDE; 0 on ALLOW
    /// @return risk Snapshot from the oracle
    function _evaluate(address wallet)
        internal
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        if (sanctionRegistry.isSanctioned(wallet)) {
            revert SanctionHit(wallet);
        }

        risk = complianceOracle.getRisk(wallet);
        (decision, feeBps) = riskPolicy.decide(risk.score);

        if (decision == HookDecision.REVERT) {
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }
    }

    /// @notice Emit afterSwap audit trail (called only when settlement succeeded).
    function _emitSwapObserved(
        address wallet,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk memory risk
    ) internal {
        emit SwapObserved(
            wallet,
            risk.score,
            decision,
            feeBps,
            risk.hopDistance,
            risk.origin
        );
    }
}
