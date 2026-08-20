// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal Gnosis Safe owner list for C-03 unit tests.
contract MockGnosisSafe {
    address[] private _owners;

    constructor(address[] memory owners_) {
        _owners = owners_;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function setOwners(address[] memory owners_) external {
        _owners = owners_;
    }
}
