// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReactiveMonitor} from "../src/ReactiveMonitor.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract FuzzMockPegKeeper is IPegKeeper {
    DepegAlert public lastAlert;
    uint256 public callCount;
    Stage public current;

    function receiveAlert(DepegAlert calldata alert) external override {
        lastAlert = alert;
        current   = alert.stage;
        callCount++;
    }

    function getProtectionStage() external view override returns (Stage) {
        return current;
    }

    function getLastAlert() external view returns (DepegAlert memory) {
        return lastAlert;
    }
}

contract FuzzMockFeed {
    mapping(uint8 => uint256) internal _prices;

    function setPrice(uint8 chainId, uint256 priceBps) external {
        _prices[chainId] = priceBps;
    }

    function getPrice(uint8 chainId) external view returns (uint256) {
        return _prices[chainId];
    }
}

// ─── Fuzz tests ───────────────────────────────────────────────────────────────

contract ReactiveMonitorFuzzTest is Test {
    uint8 internal constant CHAIN_ETHEREUM = 1;
    uint8 internal constant CHAIN_BASE     = 2;
    uint8 internal constant CHAIN_ARBITRUM = 3;

    // Thresholds mirrored from ReactiveMonitor
    uint256 internal constant YELLOW_THRESHOLD = 9_990;
    uint256 internal constant ORANGE_THRESHOLD = 9_950;
    uint256 internal constant RED_THRESHOLD    = 9_850;
    uint256 internal constant PEG              = 10_000;

    FuzzMockPegKeeper internal pegKeeper;
    FuzzMockFeed      internal feed;
    ReactiveMonitor   internal monitor;

    function setUp() public {
        pegKeeper = new FuzzMockPegKeeper();
        feed      = new FuzzMockFeed();

        feed.setPrice(CHAIN_ETHEREUM, PEG);
        feed.setPrice(CHAIN_BASE,     PEG);
        feed.setPrice(CHAIN_ARBITRUM, PEG);

        monitor = new ReactiveMonitor(address(pegKeeper), address(feed));
    }

    // ─── Fuzz: single-chain pressure never fires an alert ────────────────────

    /// If only ONE chain is below YELLOW_THRESHOLD and the rest are at peg,
    /// the monitor must NOT call pegKeeper.
    function testFuzz_singleChainPressure_neverFiresAlert(uint256 singlePrice) public {
        singlePrice = bound(singlePrice, 1, YELLOW_THRESHOLD);

        // Only Ethereum is depressed; Base and Arbitrum at peg.
        feed.setPrice(CHAIN_ETHEREUM, singlePrice);
        feed.setPrice(CHAIN_BASE,     PEG);
        feed.setPrice(CHAIN_ARBITRUM, PEG);

        monitor.react("");

        assertEq(pegKeeper.callCount(), 0, "single-chain pressure must not trigger alert");
        assertEq(uint8(monitor.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    /// Symmetry: single-chain on Base also never fires.
    function testFuzz_singleChainPressure_onBase_neverFiresAlert(uint256 singlePrice) public {
        singlePrice = bound(singlePrice, 1, YELLOW_THRESHOLD);

        feed.setPrice(CHAIN_ETHEREUM, PEG);
        feed.setPrice(CHAIN_BASE,     singlePrice);
        feed.setPrice(CHAIN_ARBITRUM, PEG);

        monitor.react("");

        assertEq(pegKeeper.callCount(), 0);
    }

    /// Symmetry: single-chain on Arbitrum also never fires.
    function testFuzz_singleChainPressure_onArbitrum_neverFiresAlert(uint256 singlePrice) public {
        singlePrice = bound(singlePrice, 1, YELLOW_THRESHOLD);

        feed.setPrice(CHAIN_ETHEREUM, PEG);
        feed.setPrice(CHAIN_BASE,     PEG);
        feed.setPrice(CHAIN_ARBITRUM, singlePrice);

        monitor.react("");

        assertEq(pegKeeper.callCount(), 0);
    }

    // ─── Fuzz: two-chain pressure always fires an alert ──────────────────────

    /// Two chains below YELLOW_THRESHOLD always triggers an alert.
    function testFuzz_twoChainPressure_alwaysFiresAlert(uint256 ethPrice, uint256 basePrice) public {
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, PEG);

        monitor.react("");

        assertGt(pegKeeper.callCount(), 0, "two-chain pressure must always fire an alert");
    }

    // ─── Fuzz: stage selection matches worst-price logic ─────────────────────

    /// With two chains depressed, stage matches the worst (lowest) price.
    function testFuzz_stageMatchesWorstPrice_twoChains(
        uint256 ethPrice,
        uint256 basePrice
    ) public {
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, PEG);

        monitor.react("");

        uint256 worst = ethPrice < basePrice ? ethPrice : basePrice;

        IPegKeeper.Stage expected;
        if (worst < RED_THRESHOLD) {
            expected = IPegKeeper.Stage.RED;
        } else if (worst <= ORANGE_THRESHOLD) {
            expected = IPegKeeper.Stage.ORANGE;
        } else {
            expected = IPegKeeper.Stage.YELLOW;
        }

        assertEq(
            uint8(pegKeeper.getLastAlert().stage),
            uint8(expected),
            "stage must match worst price"
        );
    }

    /// With all three chains depressed, stage still matches the worst price.
    function testFuzz_stageMatchesWorstPrice_threeChains(
        uint256 ethPrice,
        uint256 basePrice,
        uint256 arbPrice
    ) public {
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);
        arbPrice  = bound(arbPrice,  1, YELLOW_THRESHOLD);

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, arbPrice);

        monitor.react("");

        uint256 worst = ethPrice;
        if (basePrice < worst) worst = basePrice;
        if (arbPrice  < worst) worst = arbPrice;

        IPegKeeper.Stage expected;
        if (worst < RED_THRESHOLD) {
            expected = IPegKeeper.Stage.RED;
        } else if (worst <= ORANGE_THRESHOLD) {
            expected = IPegKeeper.Stage.ORANGE;
        } else {
            expected = IPegKeeper.Stage.YELLOW;
        }

        assertEq(
            uint8(pegKeeper.getLastAlert().stage),
            uint8(expected),
            "three-chain stage must match worst price"
        );
    }

    // ─── Fuzz: prices forwarded in alert match feed ───────────────────────────

    /// Alert contains the exact prices read from the feed.
    function testFuzz_alertPricesMatchFeed(
        uint256 ethPrice,
        uint256 basePrice,
        uint256 arbPrice
    ) public {
        // At least two below YELLOW so an alert fires.
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);
        arbPrice  = bound(arbPrice,  1, PEG); // can be anywhere

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, arbPrice);

        monitor.react("");

        IPegKeeper.DepegAlert memory alert = pegKeeper.getLastAlert();
        assertEq(alert.ethereumPriceBps, ethPrice,  "ethereum price mismatch in alert");
        assertEq(alert.basePriceBps,     basePrice, "base price mismatch in alert");
        assertEq(alert.arbitrumPriceBps, arbPrice,  "arbitrum price mismatch in alert");
    }

    // ─── Fuzz: chainsAffected count is accurate ───────────────────────────────

    /// chainsAffected always equals the number of chains below YELLOW_THRESHOLD.
    function testFuzz_chainsAffectedCountIsAccurate(
        uint256 ethPrice,
        uint256 basePrice,
        uint256 arbPrice
    ) public {
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);
        arbPrice  = bound(arbPrice,  1, YELLOW_THRESHOLD);

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, arbPrice);

        // All three below threshold → chainsAffected == 3.
        monitor.react("");

        assertEq(pegKeeper.getLastAlert().chainsAffected, 3, "all three chains should count");
    }

    // ─── Fuzz: alert timestamp matches block.timestamp ────────────────────────

    function testFuzz_alertTimestampMatchesBlock(
        uint256 timestamp,
        uint256 ethPrice,
        uint256 basePrice
    ) public {
        timestamp = bound(timestamp, 1, type(uint48).max);
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);

        vm.warp(timestamp);

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, PEG);

        monitor.react("");

        assertEq(
            pegKeeper.getLastAlert().timestamp,
            block.timestamp,
            "alert timestamp must match block.timestamp"
        );
    }

    // ─── Fuzz: duplicate stage never re-dispatches ───────────────────────────

    /// If the stage doesn't change, pegKeeper.callCount stays the same.
    function testFuzz_sameStage_doesNotDispatchAgain(
        uint256 ethPrice,
        uint256 basePrice
    ) public {
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, PEG);

        monitor.react(""); // first call — fires alert
        uint256 countAfterFirst = pegKeeper.callCount();
        assertEq(countAfterFirst, 1);

        monitor.react(""); // second call — same prices, same stage → no new dispatch
        assertEq(pegKeeper.callCount(), countAfterFirst, "no re-dispatch for same stage");
    }

    // ─── Fuzz: full recovery to GREEN ────────────────────────────────────────

    /// After any depeg, restoring all chains to peg triggers a GREEN alert.
    function testFuzz_recovery_alwaysFiresGreenAlert(
        uint256 ethPrice,
        uint256 basePrice,
        uint256 arbPrice
    ) public {
        ethPrice  = bound(ethPrice,  1, YELLOW_THRESHOLD);
        basePrice = bound(basePrice, 1, YELLOW_THRESHOLD);
        arbPrice  = bound(arbPrice,  1, YELLOW_THRESHOLD);

        // Trigger a depeg
        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, arbPrice);
        monitor.react("");
        assertGt(uint8(monitor.currentStage()), 0, "should have left GREEN");

        // Full recovery
        feed.setPrice(CHAIN_ETHEREUM, PEG);
        feed.setPrice(CHAIN_BASE,     PEG);
        feed.setPrice(CHAIN_ARBITRUM, PEG);
        monitor.react("");

        assertEq(
            uint8(monitor.currentStage()),
            uint8(IPegKeeper.Stage.GREEN),
            "full recovery must restore GREEN"
        );
    }

    // ─── Fuzz: react() rejects malformed event data ───────────────────────────

    /// Any payload that is not 0 or 32 bytes long must revert.
    function testFuzz_react_revertsOnInvalidPayloadLength(uint256 len) public {
        len = bound(len, 1, 31); // lengths 1–31 are neither 0 nor 32
        bytes memory badData = new bytes(len);

        vm.expectRevert(ReactiveMonitor.InvalidEventData.selector);
        monitor.react(badData);
    }

    /// Any 32-byte payload encoding an unsupported chain ID (not 1, 2, or 3) must revert.
    function testFuzz_react_revertsOnUnsupportedChainHint(uint8 chainId) public {
        vm.assume(chainId != CHAIN_ETHEREUM && chainId != CHAIN_BASE && chainId != CHAIN_ARBITRUM);

        vm.expectRevert(ReactiveMonitor.InvalidEventData.selector);
        monitor.react(abi.encode(chainId));
    }
}
