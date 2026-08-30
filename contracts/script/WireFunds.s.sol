// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FeeEscrow} from "../src/contracts/escrow/FeeEscrow.sol";
import {ComplianceTreasury} from "../src/contracts/treasury/ComplianceTreasury.sol";
import {LpCompensationVault} from "../src/contracts/compensation/LpCompensationVault.sol";
import {ISanctionRegistry} from "../src/interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../src/interfaces/oracles/IComplianceOracle.sol";

/// @notice Additive deploy for an existing FeeEscrow / hook (Sepolia). Does not
///         redeploy the hook or the pool. Broadcaster must be FeeEscrow.owner.
///
///         Env (or contracts/deployments/11155111.json via the caller):
///         FEE_ESCROW, AML_HOOK, SANCTION_REGISTRY, COMPLIANCE_ORACLE,
///         optional WETH_TOKEN, AUTHORITY_DEST (defaults to broadcaster).
contract WireFunds is Script {
    uint256 constant ANVIL_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", ANVIL_PK);
        address caller = vm.addr(pk);

        FeeEscrow feeEscrow = FeeEscrow(vm.envAddress("FEE_ESCROW"));
        address hook = vm.envAddress("AML_HOOK");
        ISanctionRegistry registry = ISanctionRegistry(vm.envAddress("SANCTION_REGISTRY"));
        IComplianceOracle oracle = IComplianceOracle(vm.envAddress("COMPLIANCE_ORACLE"));
        address weth = vm.envOr("WETH_TOKEN", address(0));
        address authority = vm.envOr("AUTHORITY_DEST", caller);

        if (feeEscrow.owner() != caller) {
            revert("WireFunds: broadcaster is not FeeEscrow.owner");
        }

        vm.startBroadcast(pk);

        ComplianceTreasury treasury = new ComplianceTreasury(caller, caller);
        LpCompensationVault vault = new LpCompensationVault(caller, caller, address(treasury));

        treasury.setLpCompensationFund(address(vault));
        treasury.setHook(hook);
        treasury.setEscrow(address(feeEscrow));
        if (authority != address(0) && authority != address(vault)) {
            treasury.setDestination(authority, true);
        }

        vault.setEscrow(address(feeEscrow));
        vault.setComplianceSources(registry, oracle);

        feeEscrow.setLpCompensationFund(address(vault));
        feeEscrow.setComplianceReserve(address(treasury));
        if (weth != address(0)) feeEscrow.setAllowedFeeToken(weth, true);

        vm.stopBroadcast();

        console2.log("LpCompensationVault", address(vault));
        console2.log("ComplianceTreasury", address(treasury));
        console2.log("FeeEscrow.lpCompensationFund", feeEscrow.lpCompensationFund());
        console2.log("FeeEscrow.complianceReserve", feeEscrow.complianceReserve());

        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "LpCompensationVault": "',
            vm.toString(address(vault)),
            '",\n',
            '  "ComplianceTreasury": "',
            vm.toString(address(treasury)),
            '",\n',
            '  "lpCompensationFund": "',
            vm.toString(address(vault)),
            '",\n',
            '  "complianceReserve": "',
            vm.toString(address(treasury)),
            '"\n',
            "}\n"
        );
        string memory path = string.concat("deployments/", vm.toString(block.chainid), "-funds.json");
        vm.writeFile(path, json);
        console2.log(string.concat("Wrote ", path));
    }
}
