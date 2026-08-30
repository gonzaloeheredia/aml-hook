// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice Locks the AmlHook / AmlHookSatellite DELEGATECALL prefix.
/// @dev Satellite `sanctionRegistry` is slot 1. If AmlHook lists Settlement first,
///      that slot is `complianceTreasury` and every LP/swap guard reverts.
contract UnitAmlHookStorageLayoutTest is Helpers {
    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);
    }

    function test_SatellitePrefixSlotsMatchHookGetters() external view {
        assertEq(_slotAddress(1), address(hook.sanctionRegistry()), "slot1 sanctionRegistry");
        assertEq(_slotAddress(2), address(hook.complianceOracle()), "slot2 complianceOracle");
        assertEq(_slotAddress(3), address(hook.riskPolicy()), "slot3 riskPolicy");
        assertEq(address(hook.sanctionRegistry()), address(sanctionRegistry));
    }

    function _slotAddress(uint256 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(address(hook), bytes32(slot)))));
    }
}
