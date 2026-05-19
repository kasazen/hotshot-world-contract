// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SpikeClaim} from "../src/SpikeClaim.sol";

/// @notice Deploy SpikeClaim to World Chain Sepolia (4801).
///   forge script script/DeploySpikeClaim.s.sol \
///     --rpc-url worldchain_sepolia --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY
/// Then whitelist the printed address as a Contract Entrypoint in the
/// Developer Portal, and put it in the spike page env.
contract DeploySpikeClaim is Script {
    function run() external {
        vm.startBroadcast();
        SpikeClaim s = new SpikeClaim();
        console.log("SpikeClaim:", address(s));
        vm.stopBroadcast();
    }
}
