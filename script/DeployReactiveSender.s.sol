// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ReactiveSender} from "../src/ReactiveSender.sol";

/// @title DeployReactiveSender
/// @notice Deploys the Kopli-side Reactive sender that watches source-chain feeds
///         and emits callbacks to the Unichain ReactiveMonitor receiver.
contract DeployReactiveSender is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 deployValue = vm.envUint("REACTIVE_DEPLOY_VALUE");

        address destinationReceiver = vm.envAddress("UNICHAIN_REACTIVE_MONITOR_ADDRESS");
        uint256 destinationChainId = vm.envUint("UNICHAIN_DESTINATION_CHAIN_ID");
        uint64 callbackGasLimit = uint64(vm.envUint("REACTIVE_CALLBACK_GAS_LIMIT"));

        ReactiveSender.SourceConfig memory ethereumSource = ReactiveSender.SourceConfig({
            chainId: vm.envUint("ETHEREUM_SOURCE_CHAIN_ID"),
            feed: vm.envAddress("ETHEREUM_SOURCE_FEED_ADDRESS")
        });

        ReactiveSender.SourceConfig memory baseSource = ReactiveSender.SourceConfig({
            chainId: vm.envUint("BASE_SOURCE_CHAIN_ID"),
            feed: vm.envAddress("BASE_SOURCE_FEED_ADDRESS")
        });

        ReactiveSender.SourceConfig memory polygonAmoySource = ReactiveSender.SourceConfig({
            chainId: vm.envUint("POLYGON_AMOY_SOURCE_CHAIN_ID"),
            feed: vm.envAddress("POLYGON_AMOY_SOURCE_FEED_ADDRESS")
        });

        vm.startBroadcast(deployerKey);

        ReactiveSender sender = new ReactiveSender{value: deployValue}(
            destinationChainId,
            destinationReceiver,
            callbackGasLimit,
            ethereumSource,
            baseSource,
            polygonAmoySource
        );

        vm.stopBroadcast();

        console2.log("ReactiveSender deployed:", address(sender));
        console2.log("Destination chain ID   :", destinationChainId);
        console2.log("Destination receiver   :", destinationReceiver);
    }
}
