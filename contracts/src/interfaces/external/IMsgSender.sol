// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Router end-user reporter for AML Hook subject resolution
/// @notice Trusted Uniswap routers expose the economic actor of the current swap.
/// @dev Sole subject source when the router is registered via `setTrustedRouter`.
///      Uniswap Universal Router implements this; Uniswap `hookData` is not read (§3.5).
interface IMsgSender {
    /// @notice End-user wallet that initiated the current swap through this router.
    function msgSender() external view returns (address);
}
