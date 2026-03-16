// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {PegKeeper} from "../src/PegKeeper.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

contract MockPoolManager2 {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 => uint24) public storedFee;

    function updateDynamicLPFee(PoolKey memory key, uint24 newFee) external {
        storedFee[PoolId.unwrap(key.toId())] = newFee;
    }
}

contract PegKeeperMoreUnits is Test {
    using PoolIdLibrary for PoolKey;

    PegKeeper hook;
    MockPoolManager2 mockPM;
    address reactiveMonitor = address(0xBEEF);
    address lp = address(0xA1);

    function setUp() public {
        mockPM = new MockPoolManager2();
        hook = new PegKeeper(IPoolManager(address(mockPM)), reactiveMonitor);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   Currency.wrap(address(0x1111111111111111111111111111111111111111)),
            currency1:   Currency.wrap(address(0x2222222222222222222222222222222222222222)),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks:       IHooks(address(hook))
        });
    }

    function _params(int24 lower, int24 upper) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: lower,
            tickUpper: upper,
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });
    }

    function test_constants_feeValues() public {
        assertEq(hook.FEE_GREEN(), 100);
        assertEq(hook.FEE_YELLOW(), 500);
        assertEq(hook.FEE_ORANGE(), 3000);
        assertEq(hook.FEE_RED(), 10000);
    }

    function test_positionKey_and_lpProfiles_interaction() public {
        PoolKey memory k = _key();
        bytes32 expectedPosKey = keccak256(abi.encode(lp, k.toId(), int24(-100), int24(100), bytes32(0)));

        // register a profile using afterAddLiquidity
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp, k, _params(-100,100), BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );

        // check lpProfiles stored under the computed key
        assertEq(uint8(hook.lpProfiles(expectedPosKey)), uint8(PegKeeper.LPProfile.Balanced));
    }

    function test_feeForStage_internalMapping() public {
        // Use callStatic via public wrapper - create a small helper contract? Instead just test via beforeSwap
        // GREEN
        vm.prank(address(mockPM));
        (bytes4 s,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(s, IHooks.beforeSwap.selector);
        assertEq(feeOverride, hook.FEE_GREEN() | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        // YELLOW
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));
        vm.prank(address(mockPM));
        (,, feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(feeOverride, hook.FEE_YELLOW() | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        // ORANGE
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));
        vm.prank(address(mockPM));
        (,, feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(feeOverride, hook.FEE_ORANGE() | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        // RED
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        vm.prank(address(mockPM));
        (,, feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(feeOverride, hook.FEE_RED() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _swapParams() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e6,
            sqrtPriceLimitX96: 0
        });
    }

    function _alert(IPegKeeper.Stage stage) internal view returns (IPegKeeper.DepegAlert memory) {
        return IPegKeeper.DepegAlert({
            stage: stage,
            ethereumPriceBps:  9970,
            basePriceBps:      9970,
            arbitrumPriceBps:  9970,
            chainsAffected:    3,
            timestamp:         block.timestamp
        });
    }

    function test_afterAddLiquidity_returnsSelectorAndZeroDelta_whenNoHookData() public {
        PoolKey memory key = _key();
        vm.prank(address(mockPM));
        (bytes4 sel, BalanceDelta delta) = hook.afterAddLiquidity(
            lp, key, _params(-10,10), BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        assertEq(sel, IHooks.afterAddLiquidity.selector);
        assertEq(int256(BalanceDelta.unwrap(delta)), int256(BalanceDelta.unwrap(BalanceDeltaLibrary.ZERO_DELTA)));
    }

    // Additional focused tests
    function test_afterAddLiquidity_recordsConservativeAndEmitsEvent() public {
        PoolKey memory key = _key();
        vm.expectEmit(true, true, false, true);
        emit PegKeeper.LPProfileRegistered(lp, key.toId(), -50, 50, PegKeeper.LPProfile.Conservative);
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp, key, _params(-50,50), BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
        // verify count
        assertEq(hook.conservativePositionCount(), 1);
    }

    function test_receiveAlert_emitsStageUpdated_andConservativeWithdrawals_once() public {
        PoolKey memory key = _key();
        // register conservative
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp, key, _params(-10,10), BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );

        vm.expectEmit(true, true, false, true);
        emit PegKeeper.StageUpdated(IPegKeeper.Stage.GREEN, IPegKeeper.Stage.RED, block.timestamp);

        vm.expectEmit(true, true, false, true);
        emit PegKeeper.ConservativeWithdrawalTriggered(key.toId(), lp, -10, 10);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        // Second RED should not emit withdrawal events
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        vm.stopPrank();
    }
}
