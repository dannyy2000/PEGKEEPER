// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockPriceFeed} from "../src/MockPriceFeed.sol";
import {PegKeeper} from "../src/PegKeeper.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

/// @title TriggerDepeg
/// @notice Demo script — simulates a stablecoin depeg event across multiple source chains
///         and shows PegKeeper responding with escalating protection stages.
///
/// How it works:
///   1. Push mock price feeds on 2+ source chains below the threshold
///   2. Reactive Network detects PriceUpdated events and calls react() on ReactiveSender
///   3. ReactiveSender emits a Callback event → Reactive relays to ReactiveMonitor on Unichain
///   4. ReactiveMonitor calls PegKeeper.receiveAlert() → stage + fee update
///
/// For a live demo, run TriggerYellow/TriggerOrange/TriggerRed on the source chains,
/// then check the PegKeeper stage on Unichain after ~30s for Reactive to relay.
///
/// Usage (run each on the appropriate source chain RPC):
///
///   # Step 1 — trigger YELLOW (mild pressure, 2 chains at $0.998)
///   forge script script/TriggerDepeg.s.sol:TriggerYellow \
///     --rpc-url ethereum_sepolia --broadcast
///   forge script script/TriggerDepeg.s.sol:TriggerYellow \
///     --rpc-url base_sepolia --broadcast
///
///   # Step 2 — check stage on Unichain (after ~30s)
///   cast call 0xD097AaE843980Da4b8b5D273c154a80b9414DC80 \
///     "getProtectionStage()(uint8)" --rpc-url https://unichain-sepolia-rpc.publicnode.com
///
///   # Step 3 — escalate to ORANGE ($0.992 on 2 chains)
///   forge script script/TriggerDepeg.s.sol:TriggerOrange \
///     --rpc-url ethereum_sepolia --broadcast
///   forge script script/TriggerDepeg.s.sol:TriggerOrange \
///     --rpc-url base_sepolia --broadcast
///
///   # Step 4 — full crisis RED ($0.980 on 2 chains)
///   forge script script/TriggerDepeg.s.sol:TriggerRed \
///     --rpc-url ethereum_sepolia --broadcast
///   forge script script/TriggerDepeg.s.sol:TriggerRed \
///     --rpc-url base_sepolia --broadcast
///
///   # Step 5 — recover back to GREEN
///   forge script script/TriggerDepeg.s.sol:TriggerRecovery \
///     --rpc-url ethereum_sepolia --broadcast
///   forge script script/TriggerDepeg.s.sol:TriggerRecovery \
///     --rpc-url base_sepolia --broadcast
///
/// Required env vars:
///   PRIVATE_KEY                  deployer private key
///   ETHEREUM_SOURCE_FEED_ADDRESS deployed MockPriceFeed on Ethereum Sepolia
///   BASE_SOURCE_FEED_ADDRESS     deployed MockPriceFeed on Base Sepolia
///
/// To check PegKeeper stage at any time:
///   cast call 0xD097AaE843980Da4b8b5D273c154a80b9414DC80 \
///     "getProtectionStage()(uint8)" --rpc-url https://unichain-sepolia-rpc.publicnode.com
///   Returns: 0=GREEN, 1=YELLOW, 2=ORANGE, 3=RED

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

abstract contract TriggerBase is Script {
    // Chain IDs used by MockPriceFeed (internal enum, not EVM chain IDs)
    uint8 internal constant FEED_CHAIN_ETHEREUM = 1;
    uint8 internal constant FEED_CHAIN_BASE     = 2;
    uint8 internal constant FEED_CHAIN_AMOY     = 3; // Polygon Amoy mapped to slot 3

    function _feedAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 11155111) return vm.envAddress("ETHEREUM_SOURCE_FEED_ADDRESS");
        if (chainId == 84532)    return vm.envAddress("BASE_SOURCE_FEED_ADDRESS");
        if (chainId == 80002)    return vm.envAddress("POLYGON_AMOY_SOURCE_FEED_ADDRESS");
        revert("TriggerDepeg: unsupported chain");
    }

    function _feedChainSlot() internal view returns (uint8) {
        uint256 chainId = block.chainid;
        if (chainId == 11155111) return FEED_CHAIN_ETHEREUM;
        if (chainId == 84532)    return FEED_CHAIN_BASE;
        if (chainId == 80002)    return FEED_CHAIN_AMOY;
        revert("TriggerDepeg: unsupported chain");
    }

    function _setPrice(uint256 priceBps) internal {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address feed = _feedAddress();
        uint8 slot = _feedChainSlot();

        vm.startBroadcast(deployerKey);
        MockPriceFeed(feed).setPrice(slot, priceBps);
        vm.stopBroadcast();

        console2.log("Feed          :", feed);
        console2.log("Chain slot    :", slot);
        console2.log("New price bps :", priceBps);
        console2.log("New price USD :", priceBps, "/ 10000");
        console2.log("PegKeeper     : 0xD097AaE843980Da4b8b5D273c154a80b9414DC80");
        console2.log("Check stage after ~30s with:");
        console2.log("  cast call 0xD097AaE843980Da4b8b5D273c154a80b9414DC80 getProtectionStage()(uint8) --rpc-url https://unichain-sepolia-rpc.publicnode.com");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// YELLOW — mild pressure ($0.998, 2+ chains needed)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Push price to $0.998 (9980 bps) — triggers YELLOW if 2+ chains show this
contract TriggerYellow is TriggerBase {
    function run() external {
        console2.log("\n=== TRIGGERING YELLOW STAGE ===");
        console2.log("Price: $0.998 (9980 bps)");
        console2.log("Threshold: YELLOW fires when 2+ chains <= $0.999");
        _setPrice(9_980);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ORANGE — sustained pressure ($0.992, 2+ chains needed)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Push price to $0.992 (9920 bps) — triggers ORANGE if 2+ chains show this
contract TriggerOrange is TriggerBase {
    function run() external {
        console2.log("\n=== TRIGGERING ORANGE STAGE ===");
        console2.log("Price: $0.992 (9920 bps)");
        console2.log("Threshold: ORANGE fires when 2+ chains <= $0.995");
        _setPrice(9_920);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RED — crisis ($0.980, 2+ chains needed)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Push price to $0.980 (9800 bps) — triggers RED if 2+ chains show this
contract TriggerRed is TriggerBase {
    function run() external {
        console2.log("\n=== TRIGGERING RED STAGE ===");
        console2.log("Price: $0.980 (9800 bps)");
        console2.log("Threshold: RED fires when 2+ chains < $0.985");
        _setPrice(9_800);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RECOVERY — restore peg ($1.000)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Restore price to $1.000 (10000 bps) — triggers recovery back to GREEN
contract TriggerRecovery is TriggerBase {
    function run() external {
        console2.log("\n=== TRIGGERING RECOVERY ===");
        console2.log("Price: $1.000 (10000 bps)");
        console2.log("All chains back to peg - pool returns to GREEN");
        _setPrice(10_000);
    }
}
