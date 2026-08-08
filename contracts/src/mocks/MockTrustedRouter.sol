// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMsgSender} from "../interfaces/IMsgSender.sol";

/// @notice Minimal IMsgSender stand-in for Anvil deploy + Forge tests.
contract MockTrustedRouter is IMsgSender {
    address private _subject;

    /// @notice Sets the address returned by `msgSender()` (demo / test control).
    function setMsgSender(address subject) external {
        _subject = subject;
    }

    /// @inheritdoc IMsgSender
    function msgSender() external view returns (address) {
        return _subject;
    }
}
