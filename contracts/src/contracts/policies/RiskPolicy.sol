// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {RiskPolicyLib} from "../../libraries/RiskPolicyLib.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";

/// @title Layer 3: ternary decision + latency floors A–D. Wrapper over RiskPolicyLib.
/// @dev Pure; no storage, no quotes, no agent call. Hook and off-chain preview both CALL `decide`.
contract RiskPolicy is IRiskPolicy {
    uint24 public constant STANDARD_FEE_BPS = FeeBps.STANDARD;
    uint24 public constant PUNITIVE_FEE_BPS = FeeBps.PUNITIVE;
    uint24 public constant PROPORTIONAL_FEE_BPS = FeeBps.PROPORTIONAL;
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;
    uint24 public constant MAX_OVERRIDE_FEE_BPS = FeeBps.MAX_OVERRIDE;

    /// @inheritdoc IRiskPolicy
    function decide(DecisionInput calldata in_) external pure returns (DecisionResult memory) {
        return RiskPolicyLib.decide(in_);
    }
}
