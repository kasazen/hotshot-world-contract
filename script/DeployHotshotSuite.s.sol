// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FeeTreasury} from "../src/FeeTreasury.sol";
import {HotshotLaunchpadFactory} from "../src/HotshotLaunchpadFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../src/interfaces/IUniswapV3.sol";

/// @title DeployHotshotSuite
/// @notice Deploys FeeTreasury + HotshotLaunchpadFactory for production.
///
/// Required env vars:
///   QUOTE_TOKEN     — WLD address on the target chain
///   POSITION_MANAGER — Uniswap V3 NonfungiblePositionManager
///   TREASURY_OWNER  — Safe multisig that owns the FeeTreasury
///   LAUNCHER         — low-privilege automation key (server signer)
///
/// World Chain mainnet (chainId 480):
///   QUOTE_TOKEN      = 0x2cFc85d8E48F8EAB294be644d9E25C3030863003
///   POSITION_MANAGER = 0xec12a9F9a09f50550686363766Cc153D03c27b5e
///
/// Usage (testnet first):
///   QUOTE_TOKEN=0x... POSITION_MANAGER=0x... TREASURY_OWNER=0x... LAUNCHER=0x... \
///     forge script script/DeployHotshotSuite.s.sol \
///     --rpc-url worldchain_mainnet --broadcast --verify --private-key $DEPLOYER_PRIVATE_KEY
///
/// **Mainnet deploy is audit-gated.** Do not run on production until the suite
/// has been audited and the AUDIT-CRITICAL items (sqrtPriceX96 encoding, LP
/// lock irreversibility, distributor partial-claim accounting) are signed off.
contract DeployHotshotSuite is Script {
    function run() external {
        address quote = vm.envAddress("QUOTE_TOKEN");
        address npm = vm.envAddress("POSITION_MANAGER");
        address safe = vm.envAddress("TREASURY_OWNER");
        address launcher = vm.envAddress("LAUNCHER");

        require(quote != address(0), "QUOTE_TOKEN");
        require(npm != address(0), "POSITION_MANAGER");
        require(safe != address(0), "TREASURY_OWNER");
        require(launcher != address(0), "LAUNCHER");

        vm.startBroadcast();

        FeeTreasury treasury = new FeeTreasury(safe);
        HotshotLaunchpadFactory factory = new HotshotLaunchpadFactory(
            IERC20(quote),
            address(treasury),
            INonfungiblePositionManager(npm),
            launcher
        );

        vm.stopBroadcast();

        console.log("=== HOTSHOT World suite ===");
        console.log("FeeTreasury:           ", address(treasury));
        console.log("HotshotLaunchpadFactory:", address(factory));
        console.log("  quote (WLD):         ", quote);
        console.log("  positionManager:     ", npm);
        console.log("  treasury owner:      ", safe);
        console.log("  launcher (automation):", launcher);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Set LAUNCHPAD_FACTORY_ADDRESS env on Vercel to the factory address.");
        console.log("  2. Set TREASURY_SAFE_ADDRESS to the treasury address.");
        console.log("  3. Whitelist MerkleVestDistributor (per-launch) + WLD in the Developer Portal.");
    }
}
