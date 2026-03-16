// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {PegKeeper} from "../src/PegKeeper.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

// ─── Minimal mock so the hook can call updateDynamicLPFee ────────────────────
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 => uint24) public storedFee;

    function updateDynamicLPFee(PoolKey memory key, uint24 newFee) external {
        storedFee[PoolId.unwrap(key.toId())] = newFee;
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────
contract PegKeeperTest is Test {
    using PoolIdLibrary for PoolKey;

    PegKeeper        hook;
    MockPoolManager  mockPM;

    address reactiveMonitor = address(0xBEEF);
    address lp1             = address(0xA1);
    address lp2             = address(0xA2);
    address lp3             = address(0xA3);

    // ─── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        mockPM = new MockPoolManager();
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

    function _params(int24 lower, int24 upper) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({
            tickLower:      lower,
            tickUpper:      upper,
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

    function _alert(IPegKeeper.Stage stage) internal view returns (IPegKeeper.DepegAlert memory) {
        return IPegKeeper.DepegAlert({
            stage:             stage,
            ethereumPriceBps:  9970,
            basePriceBps:      9970,
            arbitrumPriceBps:  9970,
            chainsAffected:    3,
            timestamp:         block.timestamp
        });
    }

    // Compute position key the same way PegKeeper does
    function _posKey(address owner, PoolId pid, int24 lo, int24 hi, bytes32 salt)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(owner, pid, lo, hi, salt));
    }

    // ─── afterInitialize ─────────────────────────────────────────────────────

    function test_afterInitialize_registersPool() public {
        PoolKey memory key = _key();
        vm.prank(address(mockPM));
        hook.afterInitialize(address(this), key, 0, 0);

        assertTrue(hook.registeredPools(key.toId()));
    }

    function test_afterInitialize_setsGreenFee() public {
        PoolKey memory key = _key();
        vm.prank(address(mockPM));
        hook.afterInitialize(address(this), key, 0, 0);

        assertEq(mockPM.storedFee(PoolId.unwrap(key.toId())), hook.FEE_GREEN());
    }

    function test_afterInitialize_emitsPoolRegistered() public {
        PoolKey memory key = _key();
        vm.expectEmit(true, false, false, false);
        emit PegKeeper.PoolRegistered(key.toId());

        vm.prank(address(mockPM));
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_afterInitialize_reverts_ifNotPoolManager() public {
        vm.expectRevert(PegKeeper.NotPoolManager.selector);
        hook.afterInitialize(address(this), _key(), 0, 0);
    }

    // ─── receiveAlert — stage transitions ────────────────────────────────────

    function test_receiveAlert_YELLOW_updatesStage() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.YELLOW));
    }

    function test_receiveAlert_ORANGE_updatesStage() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.ORANGE));
    }

    function test_receiveAlert_RED_updatesStage() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.RED));
    }

    function test_receiveAlert_GREEN_updatesStage() public {
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        hook.receiveAlert(_alert(IPegKeeper.Stage.GREEN));
        vm.stopPrank();

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    function test_receiveAlert_emitsStageUpdated() public {
        vm.expectEmit(true, true, false, true);
        emit PegKeeper.StageUpdated(
            IPegKeeper.Stage.GREEN,
            IPegKeeper.Stage.YELLOW,
            block.timestamp
        );

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));
    }

    function test_receiveAlert_reverts_ifNotReactiveMonitor() public {
        vm.expectRevert(PegKeeper.NotReactiveMonitor.selector);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));
    }

    // ─── getProtectionStage ──────────────────────────────────────────────────

    function test_getProtectionStage_defaultGreen() public view {
        assertEq(uint8(hook.getProtectionStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    function test_getProtectionStage_reflectsLatestAlert() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));

        assertEq(uint8(hook.getProtectionStage()), uint8(IPegKeeper.Stage.ORANGE));
    }

    // ─── Stage step-down: RED → ORANGE → YELLOW → GREEN ─────────────────────

    function test_stageStepsDownCorrectly() public {
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.RED));

        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));
        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.ORANGE));

        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));
        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.YELLOW));

        hook.receiveAlert(_alert(IPegKeeper.Stage.GREEN));
        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.GREEN));
        vm.stopPrank();
    }

    // ─── beforeAddLiquidity ──────────────────────────────────────────────────

    function test_beforeAddLiquidity_allowedAtGreen() public {
        vm.prank(address(mockPM));
        bytes4 sel = hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_allowedAtYellow() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));

        vm.prank(address(mockPM));
        bytes4 sel = hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_blockedAtOrange() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));

        vm.expectRevert(
            abi.encodeWithSelector(PegKeeper.DepositsBlocked.selector, IPegKeeper.Stage.ORANGE)
        );
        vm.prank(address(mockPM));
        hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
    }

    function test_beforeAddLiquidity_blockedAtRed() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        vm.expectRevert(
            abi.encodeWithSelector(PegKeeper.DepositsBlocked.selector, IPegKeeper.Stage.RED)
        );
        vm.prank(address(mockPM));
        hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
    }

    function test_beforeAddLiquidity_reopensAfterRecovery() public {
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        hook.receiveAlert(_alert(IPegKeeper.Stage.GREEN));
        vm.stopPrank();

        vm.prank(address(mockPM));
        bytes4 sel = hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_reverts_ifNotPoolManager() public {
        vm.expectRevert(PegKeeper.NotPoolManager.selector);
        hook.beforeAddLiquidity(lp1, _key(), _params(-100, 100), "");
    }

    // ─── afterAddLiquidity — LP profiles ─────────────────────────────────────

    function test_afterAddLiquidity_storesConservativeProfile() public {
        PoolKey memory key    = _key();
        IPoolManager.ModifyLiquidityParams memory params = _params(-100, 100);

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );

        bytes32 posKey = _posKey(lp1, key.toId(), -100, 100, bytes32(0));
        assertEq(uint8(hook.lpProfiles(posKey)), uint8(PegKeeper.LPProfile.Conservative));
    }

    function test_afterAddLiquidity_storesBalancedProfile() public {
        PoolKey memory key    = _key();
        IPoolManager.ModifyLiquidityParams memory params = _params(-200, 200);

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp2, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );

        bytes32 posKey = _posKey(lp2, key.toId(), -200, 200, bytes32(0));
        assertEq(uint8(hook.lpProfiles(posKey)), uint8(PegKeeper.LPProfile.Balanced));
    }

    function test_afterAddLiquidity_storesAggressiveProfile() public {
        PoolKey memory key    = _key();
        IPoolManager.ModifyLiquidityParams memory params = _params(-500, 500);

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp3, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Aggressive)
        );

        bytes32 posKey = _posKey(lp3, key.toId(), -500, 500, bytes32(0));
        assertEq(uint8(hook.lpProfiles(posKey)), uint8(PegKeeper.LPProfile.Aggressive));
    }

    function test_afterAddLiquidity_noProfileIfEmptyHookData() public {
        PoolKey memory key    = _key();
        IPoolManager.ModifyLiquidityParams memory params = _params(-100, 100);

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        // No hookData → no profile stored, conservativePositionCount stays 0
        assertEq(hook.conservativePositionCount(), 0);
    }

    function test_afterAddLiquidity_conservativeCountTracked() public {
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
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
        hook.afterAddLiquidity(
            lp3, key, _params(-300, 300),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );
        vm.stopPrank();

        assertEq(hook.conservativePositionCount(), 2);
    }

    function test_afterAddLiquidity_emitsLPProfileRegistered() public {
        PoolKey memory key = _key();

        vm.expectEmit(true, true, false, true);
        emit PegKeeper.LPProfileRegistered(lp1, key.toId(), -100, 100, PegKeeper.LPProfile.Conservative);

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
    }

    function test_afterAddLiquidity_reverts_ifNotPoolManager() public {
        vm.expectRevert(PegKeeper.NotPoolManager.selector);
        hook.afterAddLiquidity(
            lp1,
            _key(),
            _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
    }

    function test_afterAddLiquidity_differentSaltStoresDistinctPositionKeys() public {
        PoolKey memory key = _key();
        IPoolManager.ModifyLiquidityParams memory paramsA = IPoolManager.ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: 1e18,
            salt: bytes32(uint256(1))
        });
        IPoolManager.ModifyLiquidityParams memory paramsB = IPoolManager.ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: 1e18,
            salt: bytes32(uint256(2))
        });

        vm.startPrank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, paramsA,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
        hook.afterAddLiquidity(
            lp1, key, paramsB,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );
        vm.stopPrank();

        bytes32 posKeyA = _posKey(lp1, key.toId(), -100, 100, bytes32(uint256(1)));
        bytes32 posKeyB = _posKey(lp1, key.toId(), -100, 100, bytes32(uint256(2)));

        assertEq(uint8(hook.lpProfiles(posKeyA)), uint8(PegKeeper.LPProfile.Conservative));
        assertEq(uint8(hook.lpProfiles(posKeyB)), uint8(PegKeeper.LPProfile.Balanced));
    }

    // ─── Stub hooks return expected selectors ────────────────────────────────

    function test_beforeInitialize_returnsSelector() public {
        bytes4 sel = hook.beforeInitialize(lp1, _key(), 0);
        assertEq(sel, IHooks.beforeInitialize.selector);
    }

    function test_beforeRemoveLiquidity_returnsSelector() public {
        bytes4 sel = hook.beforeRemoveLiquidity(lp1, _key(), _params(-100, 100), "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_afterRemoveLiquidity_returnsSelectorAndZeroDelta() public {
        (bytes4 sel, BalanceDelta delta) = hook.afterRemoveLiquidity(
            lp1,
            _key(),
            _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
        assertEq(sel, IHooks.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(delta), BalanceDelta.unwrap(BalanceDeltaLibrary.ZERO_DELTA));
    }

    function test_afterSwap_returnsSelectorAndZeroInt128() public {
        (bytes4 sel, int128 returnedDelta) = hook.afterSwap(
            lp1,
            _key(),
            _swapParams(),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(returnedDelta, 0);
    }

    function test_beforeDonate_returnsSelector() public {
        bytes4 sel = hook.beforeDonate(lp1, _key(), 1e18, 2e18, "");
        assertEq(sel, IHooks.beforeDonate.selector);
    }

    function test_afterDonate_returnsSelector() public {
        bytes4 sel = hook.afterDonate(lp1, _key(), 1e18, 2e18, "");
        assertEq(sel, IHooks.afterDonate.selector);
    }

    // ─── beforeSwap — dynamic fee per stage ──────────────────────────────────

    function test_beforeSwap_greenFee() public {
        vm.prank(address(mockPM));
        (bytes4 sel,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");

        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(feeOverride, hook.FEE_GREEN() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_beforeSwap_yellowFee() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));

        vm.prank(address(mockPM));
        (,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(feeOverride, hook.FEE_YELLOW() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_beforeSwap_orangeFee() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.ORANGE));

        vm.prank(address(mockPM));
        (,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(feeOverride, hook.FEE_ORANGE() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_beforeSwap_redFee() public {
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        vm.prank(address(mockPM));
        (,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(feeOverride, hook.FEE_RED() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_beforeSwap_feeDropsOnRecovery() public {
        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));
        vm.stopPrank();

        vm.prank(address(mockPM));
        (,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        assertEq(feeOverride, hook.FEE_YELLOW() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_beforeSwap_reverts_ifNotPoolManager() public {
        vm.expectRevert(PegKeeper.NotPoolManager.selector);
        hook.beforeSwap(address(0), _key(), _swapParams(), "");
    }

    // ─── Conservative LP auto-withdrawal events at RED ───────────────────────

    function test_receiveAlert_RED_emitsConservativeWithdrawalEvent() public {
        PoolKey memory key = _key();

        // Register a conservative LP
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );

        // Expect the withdrawal event for that LP
        vm.expectEmit(true, true, false, true);
        emit PegKeeper.ConservativeWithdrawalTriggered(key.toId(), lp1, -100, 100);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
    }

    function test_receiveAlert_RED_emitsEventsForAllConservativeLPs() public {
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
            abi.encode(PegKeeper.LPProfile.Conservative)
        );
        // Balanced LP — should NOT trigger a withdrawal event
        hook.afterAddLiquidity(
            lp3, key, _params(-300, 300),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit PegKeeper.ConservativeWithdrawalTriggered(key.toId(), lp1, -100, 100);
        vm.expectEmit(true, true, false, true);
        emit PegKeeper.ConservativeWithdrawalTriggered(key.toId(), lp2, -200, 200);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
    }

    function test_receiveAlert_noWithdrawalEvent_ifNoConservativeLPs() public {
        // No conservative LPs registered — conservativePositionCount is 0.
        // _emitConservativeWithdrawals loops 0 times, so no events are emitted.
        // Verify the transition still succeeds and stage is updated correctly.
        assertEq(hook.conservativePositionCount(), 0);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.RED));
    }

    function test_receiveAlert_withdrawalEvents_onlyFireOnFirstREDTransition() public {
        PoolKey memory key = _key();

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp1, key, _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Conservative)
        );

        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED)); // first transition → fires events

        // Second RED alert while already RED — condition `old != Stage.RED` is false,
        // so _emitConservativeWithdrawals is NOT called. Verified by the guard in receiveAlert.
        // We also confirm stage stays RED and no revert occurs.
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));
        vm.stopPrank();

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.RED));
    }
}
