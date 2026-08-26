// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {IRiskPolicy} from "interfaces/policies/IRiskPolicy.sol";
import {Roles} from "libraries/Roles.sol";

/// @notice Fixtures shared by unit tests that must not import Uniswap v4 (coverage IR-minimum).
abstract contract HelpersCore is Test {
    AccessManager public accessManager;
    SanctionRegistry public sanctionRegistry;
    ComplianceOracle public complianceOracle;
    RiskPolicy public riskPolicy;

    address public owner = makeAddr("owner");
    address public stranger = makeAddr("stranger");
    address public keeper = makeAddr("keeper");
    address public router = makeAddr("router");
    address public registryKeeper = makeAddr("registryKeeper");
    address public oracleKeeper = makeAddr("oracleKeeper");
    address public hookGovernor = makeAddr("hookGovernor");
    address public complianceOfficer = makeAddr("complianceOfficer");
    address public walletA = address(0xA11CE);
    address public walletB = address(0xB0B);
    address public walletC = address(0xC0FFEE);
    address public walletD = address(0xD00D);
    address public walletE = address(0xE0E);

    uint256 internal constant ATTESTOR_PK = uint256(keccak256("aml.oracle.attestor"));

    function _attestor() internal returns (address) {
        return vm.addr(ATTESTOR_PK);
    }

    function _scoreSig(address wallet, uint8 score, uint24 feeBps) internal view returns (bytes memory) {
        return _scoreSigN(wallet, score, 0, address(0), feeBps, 0);
    }

    function _scoreSig(address wallet, uint8 score, uint8 hopDistance, address origin, uint24 feeBps)
        internal
        view
        returns (bytes memory)
    {
        return _scoreSigN(wallet, score, hopDistance, origin, feeBps, 0);
    }

    function _scoreSigN(address wallet, uint8 score, uint8 hopDistance, address origin, uint24 feeBps, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hash = keccak256(
            abi.encode(wallet, score, hopDistance, origin, feeBps, uint64(block.timestamp), block.chainid, nonce)
        );
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    function _wireRole(
        AccessManager _manager,
        address _admin,
        address _target,
        bytes4[] memory _selectors,
        uint64 _role,
        address _account
    ) internal {
        vm.startPrank(_admin);
        _manager.setTargetFunctionRole(_target, _selectors, _role);
        _manager.grantRole(_role, _account, 0);
        vm.stopPrank();
    }

    function _wireComplianceOfficer(address target, uint32 executionDelay) internal {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = AmlHookGovernance.applyUnscoredThresholds.selector;
        selectors[1] = AmlHookGovernance.applyPoolImpactThresholdBps.selector;
        selectors[2] = AmlHookGovernance.applyFloorFees.selector;
        vm.startPrank(owner);
        accessManager.setTargetFunctionRole(target, selectors, Roles._COMPLIANCE_OFFICER);
        accessManager.grantRole(Roles._COMPLIANCE_OFFICER, complianceOfficer, executionDelay);
        vm.stopPrank();
    }

    function _sanction(SanctionRegistry _registry, address _caller, address _account) internal {
        bytes32 salt = keccak256(abi.encode(_account, block.number, address(_registry)));
        bytes32 commitHash = keccak256(abi.encode(_account, true, salt));

        vm.prank(_caller);
        _registry.commitSanction(commitHash);

        vm.roll(block.number + _registry.revealDelay() + 1);

        vm.prank(_caller);
        _registry.revealSanction(_account, true, salt);
    }

    function _in(uint8 score, uint24 rec) internal pure returns (IRiskPolicy.DecisionInput memory i) {
        return _in(score, rec, false, 0);
    }

    function _in(uint8 score, uint24 rec, bool stale, uint32 ops)
        internal
        pure
        returns (IRiskPolicy.DecisionInput memory i)
    {
        i.score = score;
        i.recommendedFeeBps = rec;
        i.isStale = stale;
        i.operationCount = ops;
        i.proportionalFeeBps = 300;
        i.punitiveFeeBps = 800;
    }

    function _usd(
        uint8 score,
        uint24 rec,
        bool stale,
        uint32 ops,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint256 feeTh,
        uint256 revTh
    ) internal pure returns (IRiskPolicy.DecisionInput memory i) {
        i = _in(score, rec, stale, ops);
        i.neverScored = neverScored;
        i.assessedUsd = assessedUsd;
        i.inflowUsd = inflowUsd;
        i.unscoredFeeThreshold = feeTh;
        i.unscoredRevertThreshold = revTh;
    }

    function _fees(IRiskPolicy.DecisionInput memory i, uint24 prop, uint24 pun)
        internal
        pure
        returns (IRiskPolicy.DecisionInput memory)
    {
        i.proportionalFeeBps = prop;
        i.punitiveFeeBps = pun;
        return i;
    }

    function _policy(IRiskPolicy.DecisionInput memory i) internal view returns (IRiskPolicy.DecisionResult memory) {
        return riskPolicy.decide(i);
    }

    function _dec(IRiskPolicy.DecisionInput memory i) internal view returns (HookDecision, uint24) {
        IRiskPolicy.DecisionResult memory r = _policy(i);
        return (r.decision, r.feeBps);
    }
}
