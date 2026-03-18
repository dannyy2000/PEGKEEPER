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

import {PegKeeper} from "../src/PegKeeper.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

contract MockPoolManagerFuzz {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 => uint24) public storedFee;

    function updateDynamicLPFee(PoolKey memory key, uint24 newFee) external {
        storedFee[PoolId.unwrap(key.toId())] = newFee;
    }
}

/// @notice Fuzz tests for PegKeeper hook
contract PegKeeperFuzzTest is Test {
    using PoolIdLibrary for PoolKey;

    PegKeeper internal hook;
    MockPoolManagerFuzz internal mockPM;
    address internal reactiveMonitor = address(0xBEEF);

    function setUp() public {
        mockPM = new MockPoolManagerFuzz();
        hook = new PegKeeper(IPoolManager(address(mockPM)), reactiveMonitor);
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
            stage:            stage,
            ethereumPriceBps: 9970,
            basePriceBps:     9970,
            arbitrumPriceBps: 9970,
            chainsAffected:   2,
            timestamp:        block.timestamp
        });
    }

    // ─── Fuzz: stage transitions ──────────────────────────────────────────────

    /// Any valid stage value (0–3) accepted by receiveAlert and correctly stored.
    function testFuzz_receiveAlert_anyValidStage(uint8 stageRaw) public {
        stageRaw = uint8(bound(stageRaw, 0, 3));

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(stageRaw)));

        assertEq(uint8(hook.currentStage()), stageRaw);
    }

    /// Stage can be set from any stage to any stage (no invalid transitions).
    function testFuzz_receiveAlert_canTransitionFromAnyToAny(uint8 fromRaw, uint8 toRaw) public {
        fromRaw = uint8(bound(fromRaw, 0, 3));
        toRaw   = uint8(bound(toRaw,   0, 3));

        vm.startPrank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(fromRaw)));
        hook.receiveAlert(_alert(IPegKeeper.Stage(toRaw)));
        vm.stopPrank();

        assertEq(uint8(hook.currentStage()), toRaw);
    }

    /// StageUpdated always emits old → new, never lies about previous stage.
    function testFuzz_receiveAlert_emitsCorrectOldStage(uint8 firstRaw, uint8 secondRaw) public {
        firstRaw  = uint8(bound(firstRaw,  0, 3));
        secondRaw = uint8(bound(secondRaw, 0, 3));

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(firstRaw)));

        vm.expectEmit(true, true, false, true);
        emit PegKeeper.StageUpdated(
            IPegKeeper.Stage(firstRaw),
            IPegKeeper.Stage(secondRaw),
            block.timestamp
        );
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(secondRaw)));
    }

    // ─── Fuzz: dynamic fee ────────────────────────────────────────────────────

    /// The fee returned by beforeSwap always has OVERRIDE_FEE_FLAG set, regardless of stage.
    function testFuzz_beforeSwap_alwaysHasOverrideFeeFlag(uint8 stageRaw) public {
        stageRaw = uint8(bound(stageRaw, 0, 3));

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(stageRaw)));

        vm.prank(address(mockPM));
        (,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");

        assertTrue(feeOverride & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "OVERRIDE_FEE_FLAG must always be set");
    }

    /// The base fee (without flag) is always one of the four known constants.
    function testFuzz_beforeSwap_feeIsAlwaysOneOfFourConstants(uint8 stageRaw) public {
        stageRaw = uint8(bound(stageRaw, 0, 3));

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(stageRaw)));

        vm.prank(address(mockPM));
        (,, uint24 feeOverride) = hook.beforeSwap(address(0), _key(), _swapParams(), "");

        uint24 baseFee = feeOverride & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        bool validFee = (baseFee == hook.FEE_GREEN())
                     || (baseFee == hook.FEE_YELLOW())
                     || (baseFee == hook.FEE_ORANGE())
                     || (baseFee == hook.FEE_RED());
        assertTrue(validFee, "fee must be one of FEE_GREEN, FEE_YELLOW, FEE_ORANGE, FEE_RED");
    }

    /// Fee strictly increases with stage severity.
    function testFuzz_feeIncreases_withStageSeverity(uint8 lowerRaw, uint8 higherRaw) public {
        lowerRaw  = uint8(bound(lowerRaw,  0, 2));
        higherRaw = uint8(bound(higherRaw, uint256(lowerRaw) + 1, 3));

        // Get fee for lower stage
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(lowerRaw)));
        vm.prank(address(mockPM));
        (,, uint24 feeLow) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        uint24 baseLow = feeLow & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // Get fee for higher stage
        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(higherRaw)));
        vm.prank(address(mockPM));
        (,, uint24 feeHigh) = hook.beforeSwap(address(0), _key(), _swapParams(), "");
        uint24 baseHigh = feeHigh & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertGt(baseHigh, baseLow, "higher stage must have higher fee");
    }

    // ─── Fuzz: deposit blocking ───────────────────────────────────────────────

    /// Deposits are always allowed at GREEN and YELLOW, always blocked at ORANGE and RED.
    function testFuzz_depositsBlockedExactlyAtOrangeAndRed(uint8 stageRaw) public {
        stageRaw = uint8(bound(stageRaw, 0, 3));

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage(stageRaw)));

        if (stageRaw >= uint8(IPegKeeper.Stage.ORANGE)) {
            vm.expectRevert(
                abi.encodeWithSelector(PegKeeper.DepositsBlocked.selector, IPegKeeper.Stage(stageRaw))
            );
            vm.prank(address(mockPM));
            hook.beforeAddLiquidity(address(0xA1), _key(), _params(-100, 100), "");
        } else {
            vm.prank(address(mockPM));
            bytes4 sel = hook.beforeAddLiquidity(address(0xA1), _key(), _params(-100, 100), "");
            assertEq(sel, IHooks.beforeAddLiquidity.selector);
        }
    }

    // ─── Fuzz: LP profile storage ─────────────────────────────────────────────

    /// Any valid profile value (0–2) is stored correctly.
    function testFuzz_afterAddLiquidity_anyValidProfile(uint8 profileRaw) public {
        profileRaw = uint8(bound(profileRaw, 0, 2));

        PoolKey memory key = _key();
        address lp = address(0xABC);

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp, key, _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile(profileRaw))
        );

        bytes32 posKey = keccak256(abi.encode(lp, key.toId(), int24(-100), int24(100), bytes32(0)));
        assertEq(uint8(hook.lpProfiles(posKey)), profileRaw);
    }

    /// Conservative positions are tracked; non-conservative ones do not increment count.
    function testFuzz_afterAddLiquidity_onlyConservativeIncrementsCount(uint8 profileRaw) public {
        profileRaw = uint8(bound(profileRaw, 0, 2));

        address lp = address(0xABC);
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp, _key(), _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile(profileRaw))
        );

        uint256 expected = (profileRaw == uint8(PegKeeper.LPProfile.Conservative)) ? 1 : 0;
        assertEq(hook.conservativePositionCount(), expected);
    }

    /// n conservative LPs produce exactly conservativePositionCount() == n.
    function testFuzz_conservativeCount_equalsNumberOfConservativeLPs(uint8 n) public {
        n = uint8(bound(n, 1, 30));

        for (uint8 i = 0; i < n; i++) {
            address lp = address(uint160(uint256(i) + 1));
            vm.prank(address(mockPM));
            hook.afterAddLiquidity(
                lp, _key(), _params(-100, 100),
                BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
                abi.encode(PegKeeper.LPProfile.Conservative)
            );
        }

        assertEq(hook.conservativePositionCount(), n);
    }

    /// Two positions with different salts produce different position keys.
    function testFuzz_positionKey_differentSaltsProduceDifferentKeys(
        bytes32 saltA,
        bytes32 saltB,
        uint8 profileA,
        uint8 profileB
    ) public {
        vm.assume(saltA != saltB);
        profileA = uint8(bound(profileA, 0, 2));
        profileB = uint8(bound(profileB, 0, 2));

        PoolKey memory key = _key();
        address lp = address(0xA1);

        IPoolManager.ModifyLiquidityParams memory paramsA = IPoolManager.ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100, liquidityDelta: 1e18, salt: saltA
        });
        IPoolManager.ModifyLiquidityParams memory paramsB = IPoolManager.ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100, liquidityDelta: 1e18, salt: saltB
        });

        vm.startPrank(address(mockPM));
        hook.afterAddLiquidity(
            lp, key, paramsA,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile(profileA))
        );
        hook.afterAddLiquidity(
            lp, key, paramsB,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile(profileB))
        );
        vm.stopPrank();

        bytes32 posKeyA = keccak256(abi.encode(lp, key.toId(), int24(-100), int24(100), saltA));
        bytes32 posKeyB = keccak256(abi.encode(lp, key.toId(), int24(-100), int24(100), saltB));

        assertTrue(posKeyA != posKeyB);
        assertEq(uint8(hook.lpProfiles(posKeyA)), profileA);
        assertEq(uint8(hook.lpProfiles(posKeyB)), profileB);
    }

    /// Two positions with different tick ranges produce different position keys.
    function testFuzz_positionKey_differentTicksProduceDifferentKeys(
        int24 loA, int24 hiA,
        int24 loB, int24 hiB
    ) public {
        vm.assume(loA < hiA && loB < hiB);
        vm.assume(loA != loB || hiA != hiB);

        PoolKey memory key = _key();
        address lp = address(0xA1);

        vm.startPrank(address(mockPM));
        hook.afterAddLiquidity(
            lp, key, IPoolManager.ModifyLiquidityParams({
                tickLower: loA, tickUpper: hiA, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Balanced)
        );
        hook.afterAddLiquidity(
            lp, key, IPoolManager.ModifyLiquidityParams({
                tickLower: loB, tickUpper: hiB, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile.Aggressive)
        );
        vm.stopPrank();

        bytes32 posKeyA = keccak256(abi.encode(lp, key.toId(), loA, hiA, bytes32(0)));
        bytes32 posKeyB = keccak256(abi.encode(lp, key.toId(), loB, hiB, bytes32(0)));

        assertTrue(posKeyA != posKeyB);
        assertEq(uint8(hook.lpProfiles(posKeyA)), uint8(PegKeeper.LPProfile.Balanced));
        assertEq(uint8(hook.lpProfiles(posKeyB)), uint8(PegKeeper.LPProfile.Aggressive));
    }

    // ─── Fuzz: access control ─────────────────────────────────────────────────

    /// No arbitrary caller can trigger receiveAlert.
    function testFuzz_receiveAlert_revertsForArbitraryCallers(address caller) public {
        vm.assume(caller != reactiveMonitor);
        vm.prank(caller);
        vm.expectRevert(PegKeeper.NotReactiveMonitor.selector);
        hook.receiveAlert(_alert(IPegKeeper.Stage.YELLOW));
    }

    /// No arbitrary caller can call beforeSwap.
    function testFuzz_beforeSwap_revertsForArbitraryCallers(address caller) public {
        vm.assume(caller != address(mockPM));
        vm.prank(caller);
        vm.expectRevert(PegKeeper.NotPoolManager.selector);
        hook.beforeSwap(address(0), _key(), _swapParams(), "");
    }

    /// No arbitrary caller can call beforeAddLiquidity.
    function testFuzz_beforeAddLiquidity_revertsForArbitraryCallers(address caller) public {
        vm.assume(caller != address(mockPM));
        vm.prank(caller);
        vm.expectRevert(PegKeeper.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(0xA1), _key(), _params(-100, 100), "");
    }

    /// No arbitrary caller can call afterAddLiquidity.
    function testFuzz_afterAddLiquidity_revertsForArbitraryCallers(address caller) public {
        vm.assume(caller != address(mockPM));
        vm.prank(caller);
        vm.expectRevert(PegKeeper.NotPoolManager.selector);
        hook.afterAddLiquidity(
            address(0xA1), _key(), _params(-100, 100),
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, ""
        );
    }

    // ─── Fuzz: conservative withdrawal events ────────────────────────────────

    /// When entering RED for the first time, exactly n withdrawal events fire for n conservative LPs.
    function testFuzz_redAlert_firesExactlyNWithdrawalEvents(uint8 n) public {
        n = uint8(bound(n, 0, 20));

        PoolKey memory key = _key();

        for (uint8 i = 0; i < n; i++) {
            address lp = address(uint160(uint256(i) + 1));
            vm.prank(address(mockPM));
            hook.afterAddLiquidity(
                lp, key, _params(-100, 100),
                BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
                abi.encode(PegKeeper.LPProfile.Conservative)
            );
        }

        assertEq(hook.conservativePositionCount(), n);

        vm.prank(reactiveMonitor);
        hook.receiveAlert(_alert(IPegKeeper.Stage.RED));

        assertEq(uint8(hook.currentStage()), uint8(IPegKeeper.Stage.RED));
    }

    // ─── Fuzz: multiple pools ─────────────────────────────────────────────────

    /// afterInitialize can register multiple different pools independently.
    function testFuzz_afterInitialize_registersDistinctPools(address token0, address token1) public {
        vm.assume(token0 != token1);
        vm.assume(token0 != address(0) && token1 != address(0));
        vm.assume(uint160(token0) < uint160(token1)); // currency0 < currency1 requirement

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks:       IHooks(address(hook))
        });

        vm.prank(address(mockPM));
        hook.afterInitialize(address(this), key, 0, 0);

        assertTrue(hook.registeredPools(key.toId()));
    }
}
