// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal Gnosis Safe owner enumeration used by `_resolveWallet` (C-03).
interface IGnosisSafeOwners {
    function getOwners() external view returns (address[] memory);
}
