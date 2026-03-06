// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPegKeeper} from "./interfaces/IPegKeeper.sol";

/// @title PegKeeper
/// @notice Uniswap v4 hook that gives stablecoin pools graduated depeg protection.
///         Deployed on Unichain. Receives cross-chain alerts from ReactiveMonitor
///         on Reactive Kopli and responds by adjusting fees and blocking deposits.
///
/// Hook flags required in the deployment address (least-significant 14 bits):
///   afterInitialize      bit 12  (0x1000)
///   beforeAddLiquidity   bit 11  (0x0800)
///   afterAddLiquidity    bit 10  (0x0400)
///   beforeSwap           bit  7  (0x0080)
///   Required mask = 0x1C80
///
/// The pool must be initialised with fee = LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000).
contract PegKeeper is IHooks, IPegKeeper {
    using PoolIdLibrary for PoolKey;

    // ─── Fee constants (hundredths of a bip; 1_000_000 = 100%) ──────────────

    uint24 public constant FEE_GREEN  =   100; // 0.01 %
    uint24 public constant FEE_YELLOW =   500; // 0.05 %
    uint24 public constant FEE_ORANGE =  3000; // 0.30 %
    uint24 public constant FEE_RED    = 10000; // 1.00 %

    // ─── LP protection profile ───────────────────────────────────────────────

    /// @notice Profile chosen by an LP at deposit time.
    /// Passed as abi-encoded hookData in the addLiquidity call.
    enum LPProfile { Conservative, Balanced, Aggressive }

    /// @dev Minimal position metadata stored for conservative positions only.
    struct PositionInfo {
        address owner;
        PoolId  poolId;
        int24   tickLower;
        int24   tickUpper;
    }

    // ─── Immutables ──────────────────────────────────────────────────────────

    IPoolManager public immutable poolManager;
    /// @notice The Reactive Network monitor authorised to call receiveAlert().
    address       public immutable reactiveMonitor;

    // ─── State ───────────────────────────────────────────────────────────────

    Stage public currentStage;

    /// @notice positionKey → LP profile
    mapping(bytes32 => LPProfile)    public  lpProfiles;
    /// @dev positionKey → info (conservative positions only, for withdrawal events)
    mapping(bytes32 => PositionInfo) private _posInfo;
    /// @dev ordered list of conservative position keys
    bytes32[]                        private _conservativeKeys;

    /// @notice Tracks which PoolIds have been registered via afterInitialize.
    mapping(PoolId => bool) public registeredPools;

    // ─── Events ──────────────────────────────────────────────────────────────

    /// @notice Fired whenever the protection stage changes.
    event StageUpdated(Stage indexed oldStage, Stage indexed newStage, uint256 timestamp);
    /// @notice Fired when a new pool registers with this hook.
    event PoolRegistered(PoolId indexed poolId);
    /// @notice Fired when an LP's protection profile is stored.
    event LPProfileRegistered(
        address indexed lp,
        PoolId  indexed poolId,
        int24   tickLower,
        int24   tickUpper,
        LPProfile profile
    );
    /// @notice Fired for every conservative LP position when stage transitions to RED.
    /// Off-chain systems and the LP themselves should treat this as a signal to exit.
    event ConservativeWithdrawalTriggered(
        PoolId  indexed poolId,
        address indexed lp,
        int24   tickLower,
        int24   tickUpper
    );

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotPoolManager();
    error NotReactiveMonitor();
    /// @notice Thrown in beforeAddLiquidity when the pool is in ORANGE or RED stage.
    error DepositsBlocked(Stage stage);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyReactiveMonitor() {
        if (msg.sender != reactiveMonitor) revert NotReactiveMonitor();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager, address _reactiveMonitor) {
        poolManager     = _poolManager;
        reactiveMonitor = _reactiveMonitor;
        currentStage    = Stage.GREEN;
    }

    // ─── IPegKeeper ──────────────────────────────────────────────────────────

    /// @inheritdoc IPegKeeper
    /// @dev Called by ReactiveMonitor via Reactive Network callback.
    ///      Updates the protection stage and emits per-position withdrawal events
    ///      when transitioning into RED for the first time.
    function receiveAlert(DepegAlert calldata alert) external onlyReactiveMonitor {
        Stage old = currentStage;
        currentStage = alert.stage;
        emit StageUpdated(old, alert.stage, alert.timestamp);

        if (alert.stage == Stage.RED && old != Stage.RED) {
            _emitConservativeWithdrawals();
        }
    }

    /// @inheritdoc IPegKeeper
    function getProtectionStage() external view returns (Stage) {
        return currentStage;
    }

    // ─── IHooks ──────────────────────────────────────────────────────────────

    /// @notice Registers the pool and sets the initial dynamic LP fee to GREEN.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        registeredPools[id] = true;
        poolManager.updateDynamicLPFee(key, FEE_GREEN);
        emit PoolRegistered(id);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Blocks new deposits when the pool is in ORANGE or RED stage.
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        Stage s = currentStage;
        if (s == Stage.ORANGE || s == Stage.RED) revert DepositsBlocked(s);
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Stores the LP's protection profile.
    ///         hookData must be abi.encode(LPProfile) — if empty, no profile is recorded.
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (hookData.length > 0) {
            LPProfile profile = abi.decode(hookData, (LPProfile));
            PoolId    pid     = key.toId();
            bytes32   posKey  = _positionKey(sender, pid, params.tickLower, params.tickUpper, params.salt);

            lpProfiles[posKey] = profile;

            if (profile == LPProfile.Conservative) {
                _posInfo[posKey] = PositionInfo(sender, pid, params.tickLower, params.tickUpper);
                _conservativeKeys.push(posKey);
            }

            emit LPProfileRegistered(sender, pid, params.tickLower, params.tickUpper, profile);
        }
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Returns a per-swap dynamic fee override matching the current protection stage.
    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = _feeForStage(currentStage) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    // ─── Unused hook stubs (must be present to satisfy IHooks) ───────────────

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function beforeRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterSwap(
        address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Returns the Hooks.Permissions struct describing which hooks this contract uses.
    ///         Used by deploy scripts and tests to mine the correct CREATE2 address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:              false,
            afterInitialize:               true,
            beforeAddLiquidity:            true,
            afterAddLiquidity:             true,
            beforeRemoveLiquidity:         false,
            afterRemoveLiquidity:          false,
            beforeSwap:                    true,
            afterSwap:                     false,
            beforeDonate:                  false,
            afterDonate:                   false,
            beforeSwapReturnDelta:         false,
            afterSwapReturnDelta:          false,
            afterAddLiquidityReturnDelta:  false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Number of conservative positions currently tracked.
    function conservativePositionCount() external view returns (uint256) {
        return _conservativeKeys.length;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _feeForStage(Stage stage) internal pure returns (uint24) {
        if (stage == Stage.GREEN)  return FEE_GREEN;
        if (stage == Stage.YELLOW) return FEE_YELLOW;
        if (stage == Stage.ORANGE) return FEE_ORANGE;
        return FEE_RED;
    }

    function _positionKey(
        address owner,
        PoolId  poolId,
        int24   tickLower,
        int24   tickUpper,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, poolId, tickLower, tickUpper, salt));
    }

    /// @dev Emits ConservativeWithdrawalTriggered for every registered conservative position.
    ///      Full on-chain auto-withdrawal would require the hook to hold LP positions directly
    ///      (acting as a position manager). For M1, the events serve as the authoritative
    ///      signal for off-chain systems and the LPs themselves to exit.
    function _emitConservativeWithdrawals() internal {
        uint256 len = _conservativeKeys.length;
        for (uint256 i = 0; i < len; i++) {
            PositionInfo memory info = _posInfo[_conservativeKeys[i]];
            emit ConservativeWithdrawalTriggered(info.poolId, info.owner, info.tickLower, info.tickUpper);
        }
    }
}
