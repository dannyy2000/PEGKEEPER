// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../src/MockERC20.sol";

contract MockERC20Test is Test {
    MockERC20 internal token;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new MockERC20("Mock Token", "MOCK", 6, 1_000_000);
    }

    function test_constructor_setsMetadataAndInitialSupply() public view {
        assertEq(token.name(), "Mock Token");
        assertEq(token.symbol(), "MOCK");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 1_000_000);
        assertEq(token.balanceOf(address(this)), 1_000_000);
    }

    function test_constructor_withZeroSupplyLeavesBalancesEmpty() public {
        MockERC20 emptyToken = new MockERC20("Zero", "ZERO", 18, 0);

        assertEq(emptyToken.totalSupply(), 0);
        assertEq(emptyToken.balanceOf(address(this)), 0);
    }

    function test_mint_increasesSupplyAndRecipientBalance() public {
        token.mint(alice, 250);

        assertEq(token.totalSupply(), 1_000_250);
        assertEq(token.balanceOf(alice), 250);
    }

    function test_approve_setsAllowanceAndReturnsTrue() public {
        bool ok = token.approve(alice, 777);

        assertTrue(ok);
        assertEq(token.allowance(address(this), alice), 777);
    }

    function test_transfer_movesBalanceAndReturnsTrue() public {
        bool ok = token.transfer(alice, 500);

        assertTrue(ok);
        assertEq(token.balanceOf(address(this)), 999_500);
        assertEq(token.balanceOf(alice), 500);
    }

    function test_transferFrom_usesAllowanceAndMovesBalance() public {
        token.transfer(alice, 1_000);

        vm.prank(alice);
        token.approve(address(this), 400);

        bool ok = token.transferFrom(alice, bob, 400);

        assertTrue(ok);
        assertEq(token.allowance(alice, address(this)), 0);
        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(bob), 400);
    }

    function test_transferFrom_partialSpendLeavesRemainingAllowance() public {
        token.transfer(alice, 1_000);

        vm.prank(alice);
        token.approve(address(this), 700);

        token.transferFrom(alice, bob, 250);

        assertEq(token.allowance(alice, address(this)), 450);
        assertEq(token.balanceOf(alice), 750);
        assertEq(token.balanceOf(bob), 250);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
    }

    function test_transferFrom_revertsWhenAllowanceTooLow() public {
        token.transfer(alice, 100);

        vm.prank(alice);
        token.approve(address(this), 10);

        vm.expectRevert();
        token.transferFrom(alice, bob, 50);
    }
}
