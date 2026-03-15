// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockPriceFeed} from "../src/MockPriceFeed.sol";

/// @title DeployMockFeeds
/// @notice Deploys a MockPriceFeed on whichever chain this script is run against.
///         Run once per chain (Ethereum Sepolia, Base Sepolia, Arbitrum Sepolia).
///         Collect the 3 output addresses and hand them to Ola for Kopli wiring.
///
/// Usage:
///   forge script script/DeployMockFeeds.s.sol \
///     --rpc-url ethereum_sepolia --broadcast
///
///   forge script script/DeployMockFeeds.s.sol \
///     --rpc-url base_sepolia --broadcast
///
///   forge script script/DeployMockFeeds.s.sol \
///     --rpc-url arbitrum_sepolia --broadcast
///
/// Required env vars:
///   PRIVATE_KEY   deployer private key (with 0x prefix)
contract DeployMockFeeds is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        MockPriceFeed feed = new MockPriceFeed();
        vm.stopBroadcast();

        console2.log("MockPriceFeed deployed:", address(feed));
        console2.log("Chain ID             :", block.chainid);
    }
}
