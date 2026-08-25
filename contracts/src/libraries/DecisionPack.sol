// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../interfaces/policies/IRiskPolicy.sol";

/// @title Pack the small `DecisionInput` knobs into one word for a 9-arg `decidePacked` call.
/// @dev Avoids ABI-encoding the 15-field struct (stack-too-deep without via_ir / coverage).
library DecisionPack {
    uint256 internal constant REC_SHIFT = 8;
    uint256 internal constant STALE_SHIFT = 32;
    uint256 internal constant OPS_SHIFT = 33;
    uint256 internal constant NEVER_SHIFT = 65;
    uint256 internal constant PROP_SHIFT = 66;
    uint256 internal constant PUN_SHIFT = 90;

    function pack(IRiskPolicy.DecisionInput memory i) internal pure returns (uint256 packed) {
        packed = uint256(i.score) | (uint256(i.recommendedFeeBps) << REC_SHIFT)
            | (uint256(i.isStale ? 1 : 0) << STALE_SHIFT) | (uint256(i.operationCount) << OPS_SHIFT)
            | (uint256(i.neverScored ? 1 : 0) << NEVER_SHIFT) | (uint256(i.proportionalFeeBps) << PROP_SHIFT)
            | (uint256(i.punitiveFeeBps) << PUN_SHIFT);
    }

    function unpackSmall(uint256 packed)
        internal
        pure
        returns (
            uint8 score,
            uint24 recommendedFeeBps,
            bool isStale,
            uint32 operationCount,
            bool neverScored,
            uint24 proportionalFeeBps,
            uint24 punitiveFeeBps
        )
    {
        score = uint8(packed);
        recommendedFeeBps = uint24(packed >> REC_SHIFT);
        isStale = packed & (uint256(1) << STALE_SHIFT) != 0;
        operationCount = uint32(packed >> OPS_SHIFT);
        neverScored = packed & (uint256(1) << NEVER_SHIFT) != 0;
        proportionalFeeBps = uint24(packed >> PROP_SHIFT);
        punitiveFeeBps = uint24(packed >> PUN_SHIFT);
    }
}
