// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "./IRiskPolicy.sol";

/// @title ILpPolicy: liquidity Layer 3. Same packed input as swaps; different known-score tree.
/// @notice Off-chain preview and tests CALL this wrapper over `LpPolicyLib`.
///         Never-scored rows share Floor A/C/D with `IRiskPolicy`. A published score ignores Floor B.
interface ILpPolicy {
    /// @notice Evaluate an LP add. Does not call the Compliance Officer Agent.
    function decide(IRiskPolicy.DecisionInput calldata input)
        external
        pure
        returns (IRiskPolicy.DecisionResult memory);
}
