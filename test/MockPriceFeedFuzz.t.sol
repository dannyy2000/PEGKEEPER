// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockPriceFeed} from "../src/MockPriceFeed.sol";

/// @notice Fuzz tests for MockPriceFeed
contract MockPriceFeedFuzzTest is Test {
    MockPriceFeed internal feed;

    uint8 internal constant CHAIN_ETHEREUM = 1;
    uint8 internal constant CHAIN_BASE     = 2;
    uint8 internal constant CHAIN_ARBITRUM = 3;

    function setUp() public {
        feed = new MockPriceFeed();
    }

    // ─── Fuzz: valid price round-trips ────────────────────────────────────────

    /// Any price in [1, MAX_PRICE_BPS] stores and retrieves without loss.
    function testFuzz_setPrice_validRange_ethereum(uint256 price) public {
        price = bound(price, 1, feed.MAX_PRICE_BPS());

        feed.setPrice(CHAIN_ETHEREUM, price);

        assertEq(feed.getPrice(CHAIN_ETHEREUM), price);
    }

    function testFuzz_setPrice_validRange_base(uint256 price) public {
        price = bound(price, 1, feed.MAX_PRICE_BPS());

        feed.setPrice(CHAIN_BASE, price);

        assertEq(feed.getPrice(CHAIN_BASE), price);
    }

    function testFuzz_setPrice_validRange_arbitrum(uint256 price) public {
        price = bound(price, 1, feed.MAX_PRICE_BPS());

        feed.setPrice(CHAIN_ARBITRUM, price);

        assertEq(feed.getPrice(CHAIN_ARBITRUM), price);
    }

    /// Independent prices on different chains don't interfere with each other.
    function testFuzz_setPrice_chainsAreIndependent(
        uint256 ethPrice,
        uint256 basePrice,
        uint256 arbPrice
    ) public {
        ethPrice  = bound(ethPrice,  1, feed.MAX_PRICE_BPS());
        basePrice = bound(basePrice, 1, feed.MAX_PRICE_BPS());
        arbPrice  = bound(arbPrice,  1, feed.MAX_PRICE_BPS());

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, arbPrice);

        assertEq(feed.getPrice(CHAIN_ETHEREUM), ethPrice);
        assertEq(feed.getPrice(CHAIN_BASE),     basePrice);
        assertEq(feed.getPrice(CHAIN_ARBITRUM), arbPrice);

        (uint256 e, uint256 b, uint256 a) = feed.getAllPrices();
        assertEq(e, ethPrice);
        assertEq(b, basePrice);
        assertEq(a, arbPrice);
    }

    /// Prices can be updated multiple times; only the latest value is retained.
    function testFuzz_setPrice_overwrite_retainsLatestValue(
        uint256 firstPrice,
        uint256 secondPrice
    ) public {
        firstPrice  = bound(firstPrice,  1, feed.MAX_PRICE_BPS());
        secondPrice = bound(secondPrice, 1, feed.MAX_PRICE_BPS());

        feed.setPrice(CHAIN_ETHEREUM, firstPrice);
        feed.setPrice(CHAIN_ETHEREUM, secondPrice);

        assertEq(feed.getPrice(CHAIN_ETHEREUM), secondPrice);
    }

    // ─── Fuzz: price at boundary values ──────────────────────────────────────

    /// Setting price to exactly 1 (minimum) works.
    function testFuzz_setPrice_minimumPrice_accepted(uint8 chainId) public {
        chainId = _validChain(chainId);
        feed.setPrice(chainId, 1);
        assertEq(feed.getPrice(chainId), 1);
    }

    /// Setting price to exactly MAX_PRICE_BPS works.
    function testFuzz_setPrice_maximumPrice_accepted(uint8 chainId) public {
        chainId = _validChain(chainId);
        feed.setPrice(chainId, feed.MAX_PRICE_BPS());
        assertEq(feed.getPrice(chainId), feed.MAX_PRICE_BPS());
    }

    // ─── Fuzz: invalid chain reverts ─────────────────────────────────────────

    /// Any chain ID outside {1, 2, 3} must revert on setPrice.
    function testFuzz_setPrice_invalidChain_reverts(uint8 chainId, uint256 price) public {
        vm.assume(chainId != CHAIN_ETHEREUM && chainId != CHAIN_BASE && chainId != CHAIN_ARBITRUM);
        price = bound(price, 1, feed.MAX_PRICE_BPS());

        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidChain.selector, chainId));
        feed.setPrice(chainId, price);
    }

    /// Any chain ID outside {1, 2, 3} must revert on getPrice.
    function testFuzz_getPrice_invalidChain_reverts(uint8 chainId) public {
        vm.assume(chainId != CHAIN_ETHEREUM && chainId != CHAIN_BASE && chainId != CHAIN_ARBITRUM);

        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidChain.selector, chainId));
        feed.getPrice(chainId);
    }

    // ─── Fuzz: invalid price reverts ─────────────────────────────────────────

    /// Price of 0 always reverts.
    function testFuzz_setPrice_zeroPriceReverts(uint8 chainId) public {
        chainId = _validChain(chainId);

        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidPrice.selector, uint256(0)));
        feed.setPrice(chainId, 0);
    }

    /// Price above MAX_PRICE_BPS always reverts.
    function testFuzz_setPrice_aboveMaxReverts(uint8 chainId, uint256 price) public {
        chainId = _validChain(chainId);
        price   = bound(price, feed.MAX_PRICE_BPS() + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.InvalidPrice.selector, price));
        feed.setPrice(chainId, price);
    }

    // ─── Fuzz: PriceUpdated event contents ───────────────────────────────────

    /// PriceUpdated emits the correct old and new prices.
    function testFuzz_setPrice_emitsPriceUpdated_withCorrectValues(
        uint8 chainId,
        uint256 oldPrice,
        uint256 newPrice
    ) public {
        chainId  = _validChain(chainId);
        oldPrice = bound(oldPrice, 1, feed.MAX_PRICE_BPS());
        newPrice = bound(newPrice, 1, feed.MAX_PRICE_BPS());

        // Prime the old price
        feed.setPrice(chainId, oldPrice);

        // Now expect the event with correct old → new
        vm.expectEmit(true, false, false, true);
        emit MockPriceFeed.PriceUpdated(chainId, oldPrice, newPrice);

        feed.setPrice(chainId, newPrice);
    }

    // ─── Fuzz: getAllPrices consistency with getPrice ─────────────────────────

    /// getAllPrices always returns the same values as three individual getPrice calls.
    function testFuzz_getAllPrices_matchesIndividualGetPrice(
        uint256 ethPrice,
        uint256 basePrice,
        uint256 arbPrice
    ) public {
        ethPrice  = bound(ethPrice,  1, feed.MAX_PRICE_BPS());
        basePrice = bound(basePrice, 1, feed.MAX_PRICE_BPS());
        arbPrice  = bound(arbPrice,  1, feed.MAX_PRICE_BPS());

        feed.setPrice(CHAIN_ETHEREUM, ethPrice);
        feed.setPrice(CHAIN_BASE,     basePrice);
        feed.setPrice(CHAIN_ARBITRUM, arbPrice);

        (uint256 ge, uint256 gb, uint256 ga) = feed.getAllPrices();

        assertEq(ge, feed.getPrice(CHAIN_ETHEREUM));
        assertEq(gb, feed.getPrice(CHAIN_BASE));
        assertEq(ga, feed.getPrice(CHAIN_ARBITRUM));
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    /// Map an arbitrary uint8 to a valid chain ID via modulo.
    function _validChain(uint8 raw) internal pure returns (uint8) {
        return uint8((uint256(raw) % 3) + 1); // maps to 1, 2, or 3
    }
}
