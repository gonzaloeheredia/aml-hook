// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILpPolicy} from "../../interfaces/policies/ILpPolicy.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {LpPolicyLib} from "../../libraries/LpPolicyLib.sol";

/// @title LP Layer 3: score band for known wallets; swap Floor A/C/D when never scored.
/// @dev Pure; no storage, no quotes, no agent. Distinct from `RiskPolicy` (swaps).
contract LpPolicy is ILpPolicy {
    /// @inheritdoc ILpPolicy
    function decide(IRiskPolicy.DecisionInput calldata in_)
        external
        pure
        returns (IRiskPolicy.DecisionResult memory)
    {
        return LpPolicyLib.decide(in_);
    }
}
