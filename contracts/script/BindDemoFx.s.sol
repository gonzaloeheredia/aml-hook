// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {AmlHookGovernance} from "../src/contracts/hooks/AmlHookGovernance.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {DemoUsdFeed} from "./mocks/DemoUsdFeed.sol";

/// @notice Point the live Sepolia hook at demo FX: 1 MockUSDC = $1, 1 MockWETH = $1,000.
/// @dev Replaces the official Chainlink proxies (heartbeat-stale on Sepolia → MagnitudeQuoteFailed).
///      `PRIVATE_KEY` must be AccessManager admin (`0x01C67…`) or `_HOOK_GOVERNOR`.
///
///      From `contracts/` with `.env` loaded:
///        forge script script/BindDemoFx.s.sol:BindDemoFx --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
contract BindDemoFx is Script {
    AmlHookGovernance public constant HOOK =
        AmlHookGovernance(0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7);
    AccessManager public constant MANAGER =
        AccessManager(0x52C589cE6140F482795897D0b11852203a6403fC);

    address public constant MOCK_WETH = 0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a;
    address public constant MOCK_USDC = 0xa95c6057B2Bf93476590D93539dC5beB53549684;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(pk);

        vm.startBroadcast(pk);

        bool granted;
        (bool isGov,) = MANAGER.hasRole(Roles._HOOK_GOVERNOR, caller);
        if (!isGov) {
            MANAGER.grantRole(Roles._HOOK_GOVERNOR, caller, 0);
            granted = true;
        }

        DemoUsdFeed usdcUsd = new DemoUsdFeed(1e8);
        DemoUsdFeed ethUsd = new DemoUsdFeed(1_000e8);

        HOOK.setPriceFeed(MOCK_USDC, address(usdcUsd));
        HOOK.setPriceFeed(MOCK_WETH, address(ethUsd));
        HOOK.setPriceFeed(address(0), address(ethUsd));

        if (granted) {
            MANAGER.revokeRole(Roles._HOOK_GOVERNOR, caller);
        }

        vm.stopBroadcast();

        console2.log("DemoUsdcUsd", address(usdcUsd));
        console2.log("DemoEthUsd", address(ethUsd));
        console2.log("Hook", address(HOOK));
    }
}
