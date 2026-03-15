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
    address internal constant CALLBACK_PROXY = 0x9291454c02678A65beD47E7A8874D5AC65751B84;
    address internal constant AUTHORIZED_RVM_ID = address(0xCAFE);

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

    function test_setHook_ownerCanUpdate() public {
        address newHook = address(0xBEEF);

        monitor.setHook(newHook);

        assertEq(monitor.hook(), newHook);
    }

    function test_setHook_nonOwnerReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ReactiveMonitor.NotOwner.selector);
        monitor.setHook(address(0xBEEF));
    }

    function test_setPriceFeed_ownerCanUpdate() public {
        MockFeed newFeed = new MockFeed();

        monitor.setPriceFeed(address(newFeed));

        assertEq(address(monitor.priceFeed()), address(newFeed));
    }

    function test_setPriceFeed_nonOwnerReverts() public {
        MockFeed newFeed = new MockFeed();

        vm.prank(address(0xDEAD));
        vm.expectRevert(ReactiveMonitor.NotOwner.selector);
        monitor.setPriceFeed(address(newFeed));
    }

    function test_setAuthorizedReactiveSender_ownerCanUpdate() public {
        monitor.setAuthorizedReactiveSender(AUTHORIZED_RVM_ID);

        assertEq(monitor.authorizedReactiveSender(), AUTHORIZED_RVM_ID);
    }

    function test_setAuthorizedReactiveSender_nonOwnerReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ReactiveMonitor.NotOwner.selector);
        monitor.setAuthorizedReactiveSender(AUTHORIZED_RVM_ID);
    }

    function test_receiveReactiveAlert_revertsIfNotCallbackProxy() public {
        IPegKeeper.DepegAlert memory alert = _alert(IPegKeeper.Stage.YELLOW);
        monitor.setAuthorizedReactiveSender(AUTHORIZED_RVM_ID);

        vm.expectRevert(ReactiveMonitor.NotCallbackProxy.selector);
        monitor.receiveReactiveAlert(AUTHORIZED_RVM_ID, alert);
    }

    function test_receiveReactiveAlert_revertsIfRvmIdNotAuthorized() public {
        monitor.setAuthorizedReactiveSender(AUTHORIZED_RVM_ID);

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(ReactiveMonitor.InvalidReactiveSender.selector);
        monitor.receiveReactiveAlert(address(0xDEAD), _alert(IPegKeeper.Stage.YELLOW));
    }

    function test_receiveReactiveAlert_forwardsAlertToPegKeeper() public {
        IPegKeeper.DepegAlert memory alert = _alert(IPegKeeper.Stage.ORANGE);
        monitor.setAuthorizedReactiveSender(AUTHORIZED_RVM_ID);

        vm.prank(CALLBACK_PROXY);
        monitor.receiveReactiveAlert(AUTHORIZED_RVM_ID, alert);

        assertEq(uint8(monitor.currentStage()), uint8(IPegKeeper.Stage.ORANGE));
        assertEq(uint8(pegKeeper.getLastAlert().stage), uint8(IPegKeeper.Stage.ORANGE));
        assertEq(pegKeeper.callCount(), 1);
    }

    function _alert(IPegKeeper.Stage stage) internal view returns (IPegKeeper.DepegAlert memory) {
        return IPegKeeper.DepegAlert({
            stage: stage,
            ethereumPriceBps: 9_970,
            basePriceBps: 9_960,
            arbitrumPriceBps: 9_950,
            chainsAffected: 2,
            timestamp: block.timestamp
        });
    }
}
