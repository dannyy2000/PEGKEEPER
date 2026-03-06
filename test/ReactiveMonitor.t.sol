// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReactiveMonitor} from "../src/ReactiveMonitor.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

contract MockPegKeeper is IPegKeeper {
    DepegAlert public lastAlert;
    uint256 public callCount;
    Stage public current;

    function receiveAlert(DepegAlert calldata alert) external override {
        lastAlert = alert;
        current = alert.stage;
        callCount++;
    }

    function getProtectionStage() external view override returns (Stage) {
        return current;
    }

    function getLastAlert() external view returns (DepegAlert memory) {
        return lastAlert;
    }
}

contract MockFeed {
    mapping(uint8 => uint256) internal _prices;

    function setPrice(uint8 chainId, uint256 priceBps) external {
        _prices[chainId] = priceBps;
    }

    function getPrice(uint8 chainId) external view returns (uint256) {
        return _prices[chainId];
    }
}

contract ReactiveMonitorTest is Test {
    uint8 internal constant CHAIN_ETHEREUM = 1;
    uint8 internal constant CHAIN_BASE = 2;
    uint8 internal constant CHAIN_ARBITRUM = 3;

    MockPegKeeper internal pegKeeper;
    MockFeed internal feed;
    ReactiveMonitor internal monitor;

    function setUp() public {
        pegKeeper = new MockPegKeeper();
        feed = new MockFeed();

        feed.setPrice(CHAIN_ETHEREUM, 10_000);
        feed.setPrice(CHAIN_BASE, 10_000);
        feed.setPrice(CHAIN_ARBITRUM, 10_000);

        monitor = new ReactiveMonitor(address(pegKeeper), address(feed));
    }

    function _react() internal {
        monitor.react(abi.encode(CHAIN_ETHEREUM));
    }

    function test_singleChainPriceDrop_ignored() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_970); // $0.997

        _react();

        assertEq(pegKeeper.callCount(), 0);
        assertEq(uint8(monitor.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    function test_twoChainsPressure_firesAlert() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_970);
        feed.setPrice(CHAIN_BASE, 9_970);

        _react();

        assertEq(pegKeeper.callCount(), 1);
        IPegKeeper.DepegAlert memory alert = pegKeeper.getLastAlert();
        assertEq(uint8(alert.stage), uint8(IPegKeeper.Stage.YELLOW));
        assertEq(alert.chainsAffected, 2);
    }

    function test_threeChainsPressure_escalatesHigherThanYellow() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_910);
        feed.setPrice(CHAIN_BASE, 9_910);
        feed.setPrice(CHAIN_ARBITRUM, 9_910);

        _react();

        assertEq(pegKeeper.callCount(), 1);
        IPegKeeper.DepegAlert memory alert = pegKeeper.getLastAlert();
        assertEq(uint8(alert.stage), uint8(IPegKeeper.Stage.ORANGE));
        assertEq(alert.chainsAffected, 3);
    }

    function test_price0997OnTwoChains_setsYellow() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_970);
        feed.setPrice(CHAIN_BASE, 9_970);

        _react();

        assertEq(uint8(pegKeeper.getLastAlert().stage), uint8(IPegKeeper.Stage.YELLOW));
    }

    function test_price0991OnThreeChains_setsOrange() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_910);
        feed.setPrice(CHAIN_BASE, 9_910);
        feed.setPrice(CHAIN_ARBITRUM, 9_910);

        _react();

        assertEq(uint8(pegKeeper.getLastAlert().stage), uint8(IPegKeeper.Stage.ORANGE));
    }

    function test_price0984OnThreeChains_setsRed() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_840);
        feed.setPrice(CHAIN_BASE, 9_840);
        feed.setPrice(CHAIN_ARBITRUM, 9_840);

        _react();

        assertEq(uint8(pegKeeper.getLastAlert().stage), uint8(IPegKeeper.Stage.RED));
    }

    function test_alertPopulatesChainsAffected() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_970);
        feed.setPrice(CHAIN_BASE, 9_960);

        _react();

        assertEq(pegKeeper.getLastAlert().chainsAffected, 2);
    }

    function test_alertPopulatesTimestamp() public {
        vm.warp(1_234_567);
        feed.setPrice(CHAIN_ETHEREUM, 9_970);
        feed.setPrice(CHAIN_BASE, 9_970);

        _react();

        assertEq(pegKeeper.getLastAlert().timestamp, block.timestamp);
    }

    function test_recoveryBackToPeg_firesGreenAlert() public {
        feed.setPrice(CHAIN_ETHEREUM, 9_840);
        feed.setPrice(CHAIN_BASE, 9_840);
        feed.setPrice(CHAIN_ARBITRUM, 9_840);
        _react();
        assertEq(uint8(monitor.currentStage()), uint8(IPegKeeper.Stage.RED));

        feed.setPrice(CHAIN_ETHEREUM, 10_000);
        feed.setPrice(CHAIN_BASE, 10_000);
        feed.setPrice(CHAIN_ARBITRUM, 10_000);
        _react();

        assertEq(pegKeeper.callCount(), 2);
        IPegKeeper.DepegAlert memory alert = pegKeeper.getLastAlert();
        assertEq(uint8(alert.stage), uint8(IPegKeeper.Stage.GREEN));
        assertEq(alert.chainsAffected, 0);
    }

    function test_react_revertsOnMalformedEventData() public {
        vm.expectRevert(ReactiveMonitor.InvalidEventData.selector);
        monitor.react(hex"01");
    }

    function test_react_revertsOnUnsupportedChainHint() public {
        vm.expectRevert(ReactiveMonitor.InvalidEventData.selector);
        monitor.react(abi.encode(uint8(99)));
    }
}
