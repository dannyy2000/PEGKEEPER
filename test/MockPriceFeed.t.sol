// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockPriceFeed} from "../src/MockPriceFeed.sol";

contract MockPriceFeedTest is Test {
    MockPriceFeed internal feed;

    function setUp() public {
        feed = new MockPriceFeed();
    }

    function test_constructor_setsAllPricesToPeg() public view {
        (uint256 ethPrice, uint256 basePrice, uint256 arbPrice) = feed.getAllPrices();

        assertEq(ethPrice, 10_000);
        assertEq(basePrice, 10_000);
        assertEq(arbPrice, 10_000);
    }

    function test_getPrice_returnsUpdatedValue() public {
        feed.setPrice(feed.CHAIN_ETHEREUM(), 9_975);

        assertEq(feed.getPrice(feed.CHAIN_ETHEREUM()), 9_975);
    }

    function test_setPrice_emitsPriceUpdated() public {
        vm.expectEmit(true, false, false, true);
        emit MockPriceFeed.PriceUpdated(feed.CHAIN_BASE(), 10_000, 9_950);

        feed.setPrice(feed.CHAIN_BASE(), 9_950);
    }

    function test_setPrice_revertsOnUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidChain.selector, uint8(99)));
        feed.setPrice(99, 10_000);
    }

    function test_setPrice_revertsOnZeroPrice() public {
        uint8 chainId = feed.CHAIN_ARBITRUM();
        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidPrice.selector, uint256(0)));
        feed.setPrice(chainId, 0);
    }

    function test_setPrice_revertsAboveMaxPrice() public {
        uint8 chainId = feed.CHAIN_ARBITRUM();
        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidPrice.selector, uint256(20_001)));
        feed.setPrice(chainId, 20_001);
    }

    function test_getPrice_revertsOnUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidChain.selector, uint8(0)));
        feed.getPrice(0);
    }

    function test_getAllPrices_reflectsMixedChainUpdates() public {
        feed.setPrice(feed.CHAIN_ETHEREUM(), 9_980);
        feed.setPrice(feed.CHAIN_BASE(), 9_970);
        feed.setPrice(feed.CHAIN_ARBITRUM(), 9_960);

        (uint256 ethPrice, uint256 basePrice, uint256 arbPrice) = feed.getAllPrices();

        assertEq(ethPrice, 9_980);
        assertEq(basePrice, 9_970);
        assertEq(arbPrice, 9_960);
    }
}
