// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPegKeeper} from "./interfaces/IPegKeeper.sol";
import {IReactiveMonitor} from "./interfaces/IReactiveMonitor.sol";

interface IPriceFeed {
    function getPrice(uint8 chainId) external view returns (uint256);
}

/// @title ReactiveMonitor
/// @notice Aggregates depeg signals across Ethereum, Base, and Arbitrum.
/// @dev Intended to run on Reactive Network and call PegKeeper on Unichain.
contract ReactiveMonitor is IReactiveMonitor {
    error NotOwner();
    error InvalidHook();
    error InvalidPriceFeed();
    error InvalidEventData();
    error NotCallbackProxy();
    error InvalidReactiveSender();

    uint8 public constant CHAIN_ETHEREUM = 1;
    uint8 public constant CHAIN_BASE = 2;
    uint8 public constant CHAIN_ARBITRUM = 3;
    address public constant UNICHAIN_CALLBACK_PROXY = 0x9291454c02678A65beD47E7A8874D5AC65751B84;

    uint256 public constant PEG_BPS = 10_000;
    uint256 public constant YELLOW_THRESHOLD_BPS = 9_990; // <= 0.9990
    uint256 public constant ORANGE_THRESHOLD_BPS = 9_950; // <= 0.9950
    uint256 public constant RED_THRESHOLD_BPS = 9_850; // <  0.9850

    address public owner;
    address public hook;
    address public authorizedReactiveSender;
    IPriceFeed public priceFeed;
    IPegKeeper.Stage public currentStage;

    event HookUpdated(address indexed oldHook, address indexed newHook);
    event PriceFeedUpdated(address indexed oldPriceFeed, address indexed newPriceFeed);
    event AuthorizedReactiveSenderUpdated(address indexed oldRvmId, address indexed newRvmId);
    event AlertDispatched(
        IPegKeeper.Stage indexed stage,
        uint8 indexed chainsAffected,
        uint256 ethereumPriceBps,
        uint256 basePriceBps,
        uint256 arbitrumPriceBps,
        uint256 timestamp
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address hook_, address priceFeed_) {
        if (hook_ == address(0)) revert InvalidHook();
        if (priceFeed_ == address(0)) revert InvalidPriceFeed();

        owner = msg.sender;
        hook = hook_;
        priceFeed = IPriceFeed(priceFeed_);
        currentStage = IPegKeeper.Stage.GREEN;
    }

    /// @inheritdoc IReactiveMonitor
    function react(bytes calldata eventData) external override {
        // Optional chain hint payload: abi.encode(uint8 chainId).
        // This makes malformed webhook data fail fast while still allowing empty payloads.
        if (eventData.length > 0) {
            if (eventData.length != 32) revert InvalidEventData();
            uint8 chainId = abi.decode(eventData, (uint8));
            if (!_isSupportedChain(chainId)) revert InvalidEventData();
        }
        _evaluateAndDispatch();
    }

    /// @inheritdoc IReactiveMonitor
    function receiveReactiveAlert(address rvmId, IPegKeeper.DepegAlert calldata alert) external override {
        if (msg.sender != UNICHAIN_CALLBACK_PROXY) revert NotCallbackProxy();
        if (rvmId == address(0) || rvmId != authorizedReactiveSender) revert InvalidReactiveSender();

        _dispatchAlert(alert);
    }

    /// @inheritdoc IReactiveMonitor
    function setHook(address hook_) external override onlyOwner {
        if (hook_ == address(0)) revert InvalidHook();
        address oldHook = hook;
        hook = hook_;
        emit HookUpdated(oldHook, hook_);
    }

    /// @inheritdoc IReactiveMonitor
    function setAuthorizedReactiveSender(address rvmId) external override onlyOwner {
        if (rvmId == address(0)) revert InvalidReactiveSender();
        address oldRvmId = authorizedReactiveSender;
        authorizedReactiveSender = rvmId;
        emit AuthorizedReactiveSenderUpdated(oldRvmId, rvmId);
    }

    function setPriceFeed(address priceFeed_) external onlyOwner {
        if (priceFeed_ == address(0)) revert InvalidPriceFeed();
        address oldPriceFeed = address(priceFeed);
        priceFeed = IPriceFeed(priceFeed_);
        emit PriceFeedUpdated(oldPriceFeed, priceFeed_);
    }

    function _evaluateAndDispatch() internal {
        uint256 eth = priceFeed.getPrice(CHAIN_ETHEREUM);
        uint256 base = priceFeed.getPrice(CHAIN_BASE);
        uint256 arb = priceFeed.getPrice(CHAIN_ARBITRUM);

        uint8 chainsAffected = 0;
        uint256 worst = PEG_BPS;

        if (eth <= YELLOW_THRESHOLD_BPS) {
            chainsAffected++;
            if (eth < worst) worst = eth;
        }
        if (base <= YELLOW_THRESHOLD_BPS) {
            chainsAffected++;
            if (base < worst) worst = base;
        }
        if (arb <= YELLOW_THRESHOLD_BPS) {
            chainsAffected++;
            if (arb < worst) worst = arb;
        }

        if (chainsAffected < 2) {
            // Single-chain pressure is treated as noise.
            // We only recover to GREEN on full normalization.
            if (chainsAffected == 0 && currentStage != IPegKeeper.Stage.GREEN) {
                _dispatch(
                    IPegKeeper.Stage.GREEN,
                    eth,
                    base,
                    arb,
                    0
                );
            }
            return;
        }

        IPegKeeper.Stage next = IPegKeeper.Stage.YELLOW;
        if (worst < RED_THRESHOLD_BPS) {
            next = IPegKeeper.Stage.RED;
        } else if (worst <= ORANGE_THRESHOLD_BPS) {
            next = IPegKeeper.Stage.ORANGE;
        }

        if (next != currentStage) {
            _dispatch(next, eth, base, arb, chainsAffected);
        }
    }

    function _dispatch(
        IPegKeeper.Stage nextStage,
        uint256 eth,
        uint256 base,
        uint256 arb,
        uint8 chainsAffected
    ) internal {
        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage: nextStage,
            ethereumPriceBps: eth,
            basePriceBps: base,
            arbitrumPriceBps: arb,
            chainsAffected: chainsAffected,
            timestamp: block.timestamp
        });

        _dispatchAlert(alert);
    }

    function _dispatchAlert(IPegKeeper.DepegAlert memory alert) internal {
        currentStage = alert.stage;
        IPegKeeper(hook).receiveAlert(alert);
        emit AlertDispatched(
            alert.stage,
            alert.chainsAffected,
            alert.ethereumPriceBps,
            alert.basePriceBps,
            alert.arbitrumPriceBps,
            alert.timestamp
        );
    }

    function _isSupportedChain(uint8 chainId) internal pure returns (bool) {
        return chainId == CHAIN_ETHEREUM || chainId == CHAIN_BASE || chainId == CHAIN_ARBITRUM;
    }
}
