// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PegKeeper} from "../src/PegKeeper.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract MockPoolManagerMinimal {}

contract PegKeeperExtrasTest is Test {
    PegKeeper hook;
    address reactiveMonitor = address(0xBEEF);

    function setUp() public {
        // Use address cast to IPoolManager but we don't call into it in these tests
        hook = new PegKeeper(IPoolManager(address(0x1234)), reactiveMonitor);
    }

    /// @notice Ensure constructor sets immutables and initial stage correctly
    function test_constructor_setsImmutablesAndInitialStage() public {
        assertEq(address(hook.poolManager()), address(IPoolManager(address(0x1234))));
        assertEq(hook.reactiveMonitor(), reactiveMonitor);
        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    /// @notice Validate the getHookPermissions helper returns exactly the intended Permissions
    function test_getHookPermissions_flagsMatchExpected() public {
        Hooks.Permissions memory p = hook.getHookPermissions();

        // Expected according to contract comments / implementation
        assertEq(p.beforeInitialize, false);
        assertEq(p.afterInitialize, true);
        assertEq(p.beforeAddLiquidity, true);
        assertEq(p.afterAddLiquidity, true);
        assertEq(p.beforeRemoveLiquidity, false);
        assertEq(p.afterRemoveLiquidity, false);
        assertEq(p.beforeSwap, true);
        assertEq(p.afterSwap, false);
        assertEq(p.beforeDonate, false);
        assertEq(p.afterDonate, false);
        assertEq(p.beforeSwapReturnDelta, false);
        assertEq(p.afterSwapReturnDelta, false);
        assertEq(p.afterAddLiquidityReturnDelta, false);
        assertEq(p.afterRemoveLiquidityReturnDelta, false);
    }
}
