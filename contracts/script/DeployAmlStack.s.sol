// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {AmlHook} from "../src/hooks/AmlHook.sol";
import {MockPoolManager} from "../src/mocks/MockPoolManager.sol";

/// @notice Deploys the REAL on-chain AML stack (registry, oracle, policy, hook).
/// @dev What is real vs mock in this script:
///      - REAL: SanctionRegistry, ComplianceOracle, RiskPolicy, AmlHook (CREATE2).
///      - MOCK: PoolManager defaults to MockPoolManager (no live Uniswap swaps).
///      - Keeper: deployer (Anvil #0) is set as ComplianceOracle keeper in the constructor.
///      Optional env:
///      - POOL_MANAGER: real PoolManager address (else MockPoolManager)
///      - EXTRA_KEEPER: additional address granted setKeeper(true)
///      - PRIVATE_KEY: broadcaster (defaults to Anvil account #0)
contract DeployAmlStack is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Anvil account #0
    uint256 constant ANVIL_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", ANVIL_PK);
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // MOCK unless POOL_MANAGER points at a real v4 PoolManager.
        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0));
        if (poolManagerAddr == address(0)) {
            poolManagerAddr = address(new MockPoolManager());
            console2.log("MockPoolManager", poolManagerAddr);
        }

        // REAL L1 / L2 / L3 + hook (on-chain, not stubs).
        SanctionRegistry registry = new SanctionRegistry(deployer);
        ComplianceOracle oracle = new ComplianceOracle(deployer);
        RiskPolicy policy = new RiskPolicy();

        // REAL keeper role: deployer is already a keeper (constructor). Optional second keeper.
        address extraKeeper = vm.envOr("EXTRA_KEEPER", address(0));
        if (extraKeeper != address(0)) {
            oracle.setKeeper(extraKeeper, true);
            console2.log("ExtraKeeper", extraKeeper);
        }

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs =
            abi.encode(poolManagerAddr, address(registry), address(oracle), address(policy));

        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AmlHook).creationCode, constructorArgs);

        AmlHook hook = new AmlHook{salt: salt}(
            IPoolManager(poolManagerAddr), registry, oracle, policy
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        console2.log("Deployer / Keeper", deployer);
        console2.log("PoolManager", poolManagerAddr);
        console2.log("SanctionRegistry", address(registry));
        console2.log("ComplianceOracle", address(oracle));
        console2.log("RiskPolicy", address(policy));
        console2.log("AmlHook", address(hook));
        console2.log("chainId", block.chainid);

        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "deployer": "',
            vm.toString(deployer),
            '",\n',
            '  "keeper": "',
            vm.toString(deployer),
            '",\n',
            '  "poolManager": "',
            vm.toString(poolManagerAddr),
            '",\n',
            '  "SanctionRegistry": "',
            vm.toString(address(registry)),
            '",\n',
            '  "ComplianceOracle": "',
            vm.toString(address(oracle)),
            '",\n',
            '  "RiskPolicy": "',
            vm.toString(address(policy)),
            '",\n',
            '  "AmlHook": "',
            vm.toString(address(hook)),
            '"\n',
            "}\n"
        );

        vm.writeFile("deployments/31337.json", json);
        console2.log("Wrote deployments/31337.json");

        vm.stopBroadcast();
    }
}
