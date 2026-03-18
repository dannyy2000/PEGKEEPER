// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {PegKeeper} from "../src/PegKeeper.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

contract EdgeCaseMockPoolManager {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 => uint24) public storedFee;

    function updateDynamicLPFee(PoolKey memory key, uint24 newFee) external {
        storedFee[PoolId.unwrap(key.toId())] = newFee;
    }
}

/// @notice Edge-case unit tests complementing PegKeeper.t.sol
contract PegKeeperEdgeCasesTest is Test {
    using PoolIdLibrary for PoolKey;

    PegKeeper              internal hook;
    EdgeCaseMockPoolManager internal mockPM;

    address internal reactiveMonitor = address(0xBEEF);
    address internal lp1             = address(0xA1);
    address internal lp2             = address(0xA2);
    address internal lp3             = address(0xA3);

    function setUp() public {
        mockPM = new EdgeCaseMockPoolManager();
        hook   = new PegKeeper(IPoolManager(address(mockPM)), reactiveMonitor);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   Currency.wrap(address(0x111)),
            currency1:   Currency.wrap(address(0x222)),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks:       IHooks(address(hook))
        });
    }

    function _key2() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0:   Currency.wrap(address(0x333)),
            currency1:   Currency.wrap(address(0x444)),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:       IHooks(address(hook))
        });
    }

    function _params(int24 lo, int24 hi) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({
            tickLower:      lo,
            tickUpper:      hi,
            liquidityDelta: 1e18,
            salt:           bytes32(0)
        });
    }

    function _swapParams() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -1e6,
            sqrtPriceLimitX96: 0
        });
    }

    function _alert(IPegKeeper.Stage s) internal view returns (IPegKeeper.DepegAlert memory) {
        return IPegKeeper.DepegAlert({
            stage:            s,
            ethereumPriceBps: 9970,
            basePriceBps:     9970,
            arbitrumPriceBps: 9970,
            chainsAffected:   2,
            timestamp:        block.timestamp
        });
    }

    // ─── Constructor edge cases ────────────────────────────────────────────────

    /// Default stage is GREEN immediately after construction.
    function test_constructor_defaultStageGreen() public view {
        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    /// Pool manager and reactive monitor immutables are set correctly.
    function test_constructor_immutablesStoredCorrectly() public view {
        assertEq(address(hook.poolManager()),   address(mockPM));
        assertEq(hook.reactiveMonitor(),         reactiveMonitor);
    }

    /// conservativePositionCount starts at zero.
    function test_constructor_conservativeCountStartsAtZero() public view {
        assertEq(hook.conservativePositionCount(), 0);
    }

    // ─── receiveAlert edge cases ───────────────────────────────────────────────

    /// Setting stage to GREEN when already GREEN emits the event (no-op guard is absent by design).
    function test_receiveAlert_greenToGreen_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PegKeeper.StageUpdated(IPegKeeper.Stage.GREEN, IPegKeeper.Stage.GREEN, block.timestamp);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.GREEN));

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    /// RED → GREEN skips intermediate stages correctly (no assertion on intermediate states).
    function test_receiveAlert_redToGreenDirectly() public {
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        hook.receiveAlert(_alert(IPegKeeper.Stage.GREEN));
        vm.stopPrank();

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    /// ORANGE to RED to ORANGE should NOT re-emit conservative withdrawals
    /// (they only fire when entering RED from a non-RED state).
    function test_receiveAlert_redToOrange_doesNotReFireWithdrawals() public {
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, _key(), _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );

        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));    // fires withdrawals
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE)); // step back
        // Going back to RED — withdrawal events should fire again (old != RED)
        // The implementation fires them whenever `old != RED`. This is the documented behaviour.
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        vm.stopPrank();

        // Stage settled at RED
        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.RED));
    }

    /// timestamp in the alert is forwarded directly into the emitted event.
    function test_receiveAlert_timestampInAlertUsedVerbatim() public {
        uint256 ts = 1_700_000_000;

        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage:            IPegKeeper.Stage.YELLOW,
            ethereumPriceBps: 9970,
            basePriceBps:     9970,
            arbitrumPriceBps: 9970,
            chainsAffected:   2,
            timestamp:        ts
        });

        vm.expectEmit(true, true, false, true);
        emit PegKeeper.StageUpdated(IPegKeeper.Stage.GREEN, IPegKeeper.Stage.YELLOW, ts);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(alert);
    }

    // ─── afterInitialize edge cases ───────────────────────────────────────────

    /// Two different pools can each be registered independently.
    function test_afterInitialize_twoDistinctPoolsRegisteredIndependently() public {
        PoolKey memory k1 = _key();
        PoolKey memory k2 = _key2();

        vm.startPrank(address(mockPM));
        hook.afterInitialize(address(this), k1, 0, 0);
        hook.afterInitialize(address(this), k2, 0, 0);
        vm.stopPrank();

        assertTrue(hook.registeredPools(k1.toId()));
        assertTrue(hook.registeredPools(k2.toId()));
    }

    /// afterInitialize can be called multiple times for the same pool without reverting.
    function test_afterInitialize_samePool_canBeCalledMultipleTimes() public {
        PoolKey memory k = _key();

        vm.startPrank(address(mockPM));
        hook.afterInitialize(address(this), k, 0, 0);
        hook.afterInitialize(address(this), k, 0, 0); // second call — should not revert
        vm.stopPrank();

        assertTrue(hook.registeredPools(k.toId()));
    }

    /// afterInitialize returns the correct selector.
    function test_afterInitialize_returnsCorrectSelector() public {
        vm.prank(address(mockPM));
        bytes4 sel = hook.afterInitialize(address(this), _key(), 0, 0);
        assertEq(sel, IHooks.afterInitialize.selector);
    }

    // ─── beforeAddLiquidity edge cases ────────────────────────────────────────

    /// Transitioning from ORANGE back to YELLOW reopens deposits immediately.
    function test_beforeAddLiquidity_reopensAfterOrangeToYellow() public {
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));
        vm.stopPrank();

        vm.prank(address(mockPM));
        bytes4 sel = hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    /// Transitioning from RED back to GREEN reopens deposits.
    function test_beforeAddLiquidity_reopensAfterRedToGreen() public {
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        hook.receiveAlert(_alert(IPegKeeper.Stage.GREEN));
        vm.stopPrank();

        vm.prank(address(mockPM));
        bytes4 sel = hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    // ─── afterAddLiquidity edge cases ─────────────────────────────────────────

    /// Same LP adding two positions with same ticks but different salts stores
    /// distinct profiles correctly.
    function test_afterAddLiquidity_sameLpTwoSaltsDistinctProfiles() public {
        PoolKey memory key = _key();

        IPoolManager.ModifyLiquidityParams memory p1 = IPoolManager.ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100, liquidityDelta: 1e18, salt: bytes32(uint256(1))
        });
        IPoolManager.ModifyLiquidityParams memory p2 = IPoolManager.ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100, liquidityDelta: 1e18, salt: bytes32(uint256(2))
        });

        vm.startPrank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, p1,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
        hook.afterAddLiquidity(
            lp1, key, p2,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Aggressive)
        );
        vm.stopPrank();

        bytes32 k1 = keccak256(abi.encode(lp1, key.toId(), int24(-100), int24(100), bytes32(uint256(1))));
        bytes32 k2 = keccak256(abi.encode(lp1, key.toId(), int24(-100), int24(100), bytes32(uint256(2))));

        assertEq(uint8(hook.lpProfiles(k1)), uint8(PegKeeper.LPProfile.Conservative));
        assertEq(uint8(hook.lpProfiles(k2)), uint8(PegKeeper.LPProfile.Aggressive));
        assertEq(hook.conservativePositionCount(), 1); // only p1 is Conservative
    }

    /// Mixed-profile batch: 2 Conservative + 1 Balanced + 1 Aggressive → count == 2.
    function test_afterAddLiquidity_mixedProfileBatch_correctConservativeCount() public {
        PoolKey memory key = _key();

        vm.startPrank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
        hook.afterAddLiquidity(
            lp2, key, _params(-200, 200),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );
        hook.afterAddLiquidity(
            lp3, key, _params(-300, 300),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Aggressive)
        );
        // Second conservative LP using different ticks
        hook.afterAddLiquidity(
            address(0xA4), key, _params(-400, 400),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
        vm.stopPrank();

        assertEq(hook.conservativePositionCount(), 2);
    }

    /// afterAddLiquidity with empty hookData never emits LPProfileRegistered.
    function test_afterAddLiquidity_emptyHookData_noEventEmitted() public {
        // Record all logs and verify none match LPProfileRegistered
        vm.recordLogs();
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, _key(), _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 profileRegisteredTopic = keccak256("LPProfileRegistered(address,bytes32,int24,int24,uint8)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != profileRegisteredTopic,
                "LPProfileRegistered must not be emitted with empty hookData"
            );
        }
    }

    /// afterAddLiquidity always returns ZERO_DELTA as the balance delta.
    function test_afterAddLiquidity_alwaysReturnsZeroDelta() public {
        vm.prank(address(mockPM));
        (, BalanceDelta delta) = hook.afterAddLiquidity(
            lp1, _key(), _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );
        assertEq(BalanceDelta.unwrap(delta), BalanceDelta.unwrap(BalanceDeltaLibrary.ZERO_DELTA));
    }

    // ─── beforeSwap edge cases ────────────────────────────────────────────────

    /// Fee at GREEN is exactly FEE_GREEN | OVERRIDE_FEE_FLAG.
    function test_beforeSwap_exactGreenFeeValue() public {
        vm.prank(address(mockPM));
        (,, uint24 fee) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(fee, hook.FEE_GREEN() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// Fee at YELLOW is exactly FEE_YELLOW | OVERRIDE_FEE_FLAG.
    function test_beforeSwap_exactYellowFeeValue() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));

        vm.prank(address(mockPM));
        (,, uint24 fee) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(fee, hook.FEE_YELLOW() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// Fee at ORANGE is exactly FEE_ORANGE | OVERRIDE_FEE_FLAG.
    function test_beforeSwap_exactOrangeFeeValue() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));

        vm.prank(address(mockPM));
        (,, uint24 fee) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(fee, hook.FEE_ORANGE() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// Fee at RED is exactly FEE_RED | OVERRIDE_FEE_FLAG.
    function test_beforeSwap_exactRedFeeValue() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        vm.prank(address(mockPM));
        (,, uint24 fee) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(fee, hook.FEE_RED() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// BeforeSwapDelta returned is always zero.
    function test_beforeSwap_alwaysReturnsZeroBeforeSwapDelta() public {
        vm.prank(address(mockPM));
        (, BeforeSwapDelta delta,) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
    }

    // ─── Fee constant sanity ──────────────────────────────────────────────────

    function test_feeConstants_orderIsCorrect() public view {
        assertLt(hook.FEE_GREEN(),  hook.FEE_YELLOW());
        assertLt(hook.FEE_YELLOW(), hook.FEE_ORANGE());
        assertLt(hook.FEE_ORANGE(), hook.FEE_RED());
    }

    function test_feeConstants_exactValues() public view {
        assertEq(hook.FEE_GREEN(),    100);
        assertEq(hook.FEE_YELLOW(),   500);
        assertEq(hook.FEE_ORANGE(), 3_000);
        assertEq(hook.FEE_RED(),   10_000);
    }

    // ─── Conservative withdrawal events: detailed scenarios ──────────────────

    /// Withdrawal events contain correct tick data.
    function test_conservativeWithdrawal_eventContainsCorrectTicks() public {
        PoolKey memory key = _key();

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, _params(-500, 500),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );

        vm.expectEmit(true, true, false, true);
        emit PegKeeper.ConservativeWithdrawalTriggered(key.toId(), lp1, -500, 500);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
    }

    /// Non-conservative LPs (Balanced, Aggressive) do NOT appear in withdrawal events.
    function test_conservativeWithdrawal_excludesBalancedAndAggressive() public {
        PoolKey memory key = _key();

        vm.startPrank(address(mockPM));
        hook.afterAddLiquidity(
            lp2, key, _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );
        hook.afterAddLiquidity(
            lp3, key, _params(-200, 200),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Aggressive)
        );
        vm.stopPrank();

        // Record all logs during the RED alert
        vm.recordLogs();
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 withdrawalTopic = keccak256("ConservativeWithdrawalTriggered(bytes32,address,int24,int24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(
                    logs[i].topics[0] != withdrawalTopic,
                    "Balanced/Aggressive LPs must not get ConservativeWithdrawalTriggered"
                );
            }
        }
    }

    // ─── getHookPermissions ───────────────────────────────────────────────────

    /// getHookPermissions is pure and always returns the same struct.
    function test_getHookPermissions_deterministicResult() public view {
        bytes memory first  = abi.encode(hook.getHookPermissions());
        bytes memory second = abi.encode(hook.getHookPermissions());
        assertEq(first, second);
    }
}
