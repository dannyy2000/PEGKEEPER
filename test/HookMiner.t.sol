// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookMiner} from "../script/HookMiner.sol";

contract HookMinerHarness {
    function find(
        address deployer,
        uint160 flags,
        uint160 flagMask,
        bytes memory initCode
    ) external pure returns (address hookAddress, bytes32 salt) {
        return HookMiner.find(deployer, flags, flagMask, initCode);
    }
}

contract HookMinerTest is Test {
    HookMinerHarness internal harness;

    function setUp() public {
        harness = new HookMinerHarness();
    }

    function test_find_returnsAddressMatchingRequiredFlags() public view {
        bytes memory initCode = abi.encodePacked(type(HookMinerHarness).creationCode);
        uint160 flags = 0x1C80;
        uint160 flagMask = 0x3FFF;

        (address hookAddress,) = harness.find(address(this), flags, flagMask, initCode);

        assertEq(uint160(hookAddress) & flagMask, flags);
    }

    function test_find_isDeterministicForSameInputs() public view {
        bytes memory initCode = abi.encodePacked(type(HookMinerHarness).creationCode);

        (address hookAddressA, bytes32 saltA) = harness.find(address(this), 0x1C80, 0x3FFF, initCode);
        (address hookAddressB, bytes32 saltB) = harness.find(address(this), 0x1C80, 0x3FFF, initCode);

        assertEq(hookAddressA, hookAddressB);
        assertEq(saltA, saltB);
    }

    function test_find_changesWhenInitCodeChanges() public view {
        bytes memory initCodeA = abi.encodePacked(type(HookMinerHarness).creationCode);
        bytes memory initCodeB = abi.encodePacked(type(HookMinerHarness).creationCode, uint256(1));

        (address hookAddressA, bytes32 saltA) = harness.find(address(this), 0x1C80, 0x3FFF, initCodeA);
        (address hookAddressB, bytes32 saltB) = harness.find(address(this), 0x1C80, 0x3FFF, initCodeB);

        assertTrue(hookAddressA != hookAddressB || saltA != saltB);
    }

    function test_find_withZeroFlagsCanReturnFirstSalt() public view {
        bytes memory initCode = abi.encodePacked(type(HookMinerHarness).creationCode);

        (, bytes32 salt) = harness.find(address(this), 0, 0, initCode);

        assertEq(uint256(salt), 0);
    }
}
