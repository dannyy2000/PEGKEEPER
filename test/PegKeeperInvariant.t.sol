// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {PegKeeper} from "../src/PegKeeper.sol";
import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";

// ─── Mock pool manager ─────────────────────────────────────────────────────────

contract InvariantMockPoolManager {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 => uint24) public storedFee;

    function updateDynamicLPFee(PoolKey memory key, uint24 newFee) external {
        storedFee[PoolId.unwrap(key.toId())] = newFee;
    }
}

// ─── Handler: randomised state machine for PegKeeper ─────────────────────────

contract PegKeeperHandler is Test {
    using PoolIdLibrary for PoolKey;

    PegKeeper public hook;
    InvariantMockPoolManager public mockPM;
    address public reactiveMonitor = address(0xBEEF);

    /// Ghost: number of Conservative positions ever deposited.
    uint256 public ghost_conservativeDeposited;

    PoolKey internal _poolKey;

    constructor() {
        mockPM = new InvariantMockPoolManager();
        hook   = new PegKeeper(IPoolManager(address(mockPM)), reactiveMonitor);

        _poolKey = PoolKey({
            currency0:   Currency.wrap(address(0x111)),
            currency1:   Currency.wrap(address(0x222)),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks:       IHooks(address(hook))
        });

        // Initialise pool so registeredPools[id] == true
        vm.prank(address(mockPM));
        hook.afterInitialize(address(this), _poolKey, 0, 0);
    }

    function getKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    // ── Helper: call beforeSwap as pool manager; returns the fee override ─────

    function callBeforeSwap() external returns (uint24 feeOverride) {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -1e6,
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(mockPM));
        (,, feeOverride) = hook.beforeSwap(address(0), _poolKey, sp, "");
    }

    /// Helper: try adding liquidity as pool manager; returns true if it succeeded.
    function tryAddLiquidity() external returns (bool succeeded) {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower:      -100,
            tickUpper:      100,
            liquidityDelta: 1e18,
            salt:           bytes32(0)
        });
        vm.prank(address(mockPM));
        try hook.beforeAddLiquidity(address(0xA1), _poolKey, params, "") {
            succeeded = true;
        } catch {
            succeeded = false;
        }
    }

    // ── Actions called by the fuzzer ──────────────────────────────────────────

    /// Push any stage to the hook.
    function receiveAlert(uint8 stageRaw) external {
        stageRaw = uint8(bound(stageRaw, 0, 3));

        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage:            IPegKeeper.Stage(stageRaw),
            ethereumPriceBps: 9970,
            basePriceBps:     9970,
            arbitrumPriceBps: 9970,
            chainsAffected:   2,
            timestamp:        block.timestamp
        });

        vm.prank(reactiveMonitor);
        hook.receiveAlert(alert);
    }

    /// Add liquidity with a given profile if the stage allows it.
    function addLiquidity(address lp, uint8 profileRaw, int24 lo, int24 hi, bytes32 salt) external {
        lp = address(uint160(bound(uint256(uint160(lp)), 1, type(uint160).max)));
        profileRaw = uint8(bound(profileRaw, 0, 2));

        // If ORANGE or RED, deposits are blocked — skip silently.
        if (uint8(hook.currentStage()) >= uint8(IPegKeeper.Stage.ORANGE)) return;

        // Ensure valid tick ordering
        lo = int24(bound(lo, -887272, 887271));
        hi = int24(bound(hi, int256(lo) + 1, 887272));

        if (profileRaw == uint8(PegKeeper.LPProfile.Conservative)) {
            ghost_conservativeDeposited++;
        }

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower:      lo,
            tickUpper:      hi,
            liquidityDelta: 1e18,
            salt:           salt
        });

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp, _poolKey, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(PegKeeper.LPProfile(profileRaw))
        );
    }

    /// Execute a swap (reads fee, doesn't need real tokens).
    function swap() external {
        vm.prank(address(mockPM));
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -1e6,
            sqrtPriceLimitX96: 0
        });
        hook.beforeSwap(address(0), _poolKey, sp, "");
    }
}

// ─── Invariant test contract ───────────────────────────────────────────────────

contract PegKeeperInvariantTest is StdInvariant, Test {
    PegKeeperHandler internal handler;

    function setUp() public {
        handler = new PegKeeperHandler();
        targetContract(address(handler));
    }

    // ── Invariant 1: stage is always a valid enum value (0-3) ─────────────────

    function invariant_stageMustBeValidEnum() public view {
        uint8 stage = uint8(handler.hook().currentStage());
        assertLe(stage, 3, "currentStage must be 0-3");
    }

    // ── Invariant 2: fee returned by beforeSwap always has OVERRIDE_FEE_FLAG ──
    // Delegated to handler.callBeforeSwap() so vm.prank works correctly.

    function invariant_feeAlwaysHasOverrideFeeFlag() public {
        uint24 feeOverride = handler.callBeforeSwap();
        assertTrue(
            feeOverride & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0,
            "OVERRIDE_FEE_FLAG must always be set in beforeSwap return"
        );
    }

    // ── Invariant 3: conservativePositionCount() >= ghost count ──────────────

    function invariant_conservativeCountAtLeastGhostCount() public view {
        assertGe(
            handler.hook().conservativePositionCount(),
            handler.ghost_conservativeDeposited(),
            "conservativePositionCount must be >= number of conservative deposits"
        );
    }

    // ── Invariant 4: base fee matches the expected constant for current stage ─

    function invariant_feeMatchesCurrentStage() public {
        uint8 stage = uint8(handler.hook().currentStage());
        uint24 feeOverride = handler.callBeforeSwap();
        uint24 baseFee = feeOverride & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        PegKeeper hook = handler.hook();
        if (stage == 0) assertEq(baseFee, hook.FEE_GREEN(),  "GREEN stage must use FEE_GREEN");
        if (stage == 1) assertEq(baseFee, hook.FEE_YELLOW(), "YELLOW stage must use FEE_YELLOW");
        if (stage == 2) assertEq(baseFee, hook.FEE_ORANGE(), "ORANGE stage must use FEE_ORANGE");
        if (stage == 3) assertEq(baseFee, hook.FEE_RED(),    "RED stage must use FEE_RED");
    }

    // ── Invariant 5: deposits are always blocked at ORANGE and RED ────────────
    // Delegated to handler.tryAddLiquidity() so vm.prank works correctly.

    function invariant_depositsBlockedAtOrangeAndRed() public {
        uint8 stage = uint8(handler.hook().currentStage());
        if (stage < 2) return; // GREEN / YELLOW — deposits allowed, skip

        bool succeeded = handler.tryAddLiquidity();
        assertFalse(succeeded, "deposits must be blocked at ORANGE and RED");
    }

    // ── Invariant 6: getProtectionStage() always matches currentStage ─────────

    function invariant_getProtectionStageMatchesCurrentStage() public view {
        assertEq(
            uint8(handler.hook().getProtectionStage()),
            uint8(handler.hook().currentStage()),
            "getProtectionStage() must match currentStage"
        );
    }

    // ── Invariant 7: poolManager and reactiveMonitor immutables never change ──

    function invariant_immutablesNeverChange() public view {
        assertEq(
            address(handler.hook().poolManager()),
            address(handler.mockPM()),
            "poolManager immutable changed"
        );
        assertEq(
            handler.hook().reactiveMonitor(),
            handler.reactiveMonitor(),
            "reactiveMonitor immutable changed"
        );
    }
}
