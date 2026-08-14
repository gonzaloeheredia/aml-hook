// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMsgSender} from "../../src/interfaces/external/IMsgSender.sol";

/// @notice Minimal IMsgSender stand-in for Anvil deploy convenience.
/// @dev Lives under script/, not src/: it is deploy-time tooling, not part of the on-chain
///      application. Reused by the hook's unit tests as well, so there is one implementation
///      of "a router that answers msgSender()" rather than two that can drift apart.
contract MockTrustedRouter is IMsgSender {
    address private _subject;
    bool private _revertOnRead;

    /// @notice Sets the address returned by `msgSender()` (demo / test control).
    function setMsgSender(address subject) external {
        _subject = subject;
    }

    /// @notice When true, `msgSender()` reverts (trusted-router fail-closed tests).
    function setRevertOnRead(bool revertOnRead) external {
        _revertOnRead = revertOnRead;
    }

    /// @inheritdoc IMsgSender
    function msgSender() external view returns (address) {
        if (_revertOnRead) revert("MockTrustedRouter: msgSender reverted");
        return _subject;
    }
}
