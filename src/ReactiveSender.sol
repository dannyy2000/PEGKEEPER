// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

import {IPegKeeper} from "./interfaces/IPegKeeper.sol";
import {IReactiveMonitor} from "./interfaces/IReactiveMonitor.sol";

/// @title ReactiveSender
/// @notice Kopli-side Reactive contract that watches mock feed price update events
///         across source chains and dispatches cross-chain alerts to Unichain.
contract ReactiveSender is IReactive, AbstractReactive {
    address internal constant SYSTEM_CONTRACT_HELPER = address(0x64);
    error InvalidReceiver();
    error InvalidDestinationChain();
    error InvalidGasLimit();
    error InvalidSourceConfig();
    error InvalidEventTopic();
    error InvalidEventData();
    error UnsupportedSourceChain(uint256 chainId);

    uint256 public constant PEG_BPS = 10_000;
    uint256 public constant YELLOW_THRESHOLD_BPS = 9_990;
    uint256 public constant ORANGE_THRESHOLD_BPS = 9_950;
    uint256 public constant RED_THRESHOLD_BPS = 9_850;
    uint256 public constant PRICE_UPDATED_TOPIC = uint256(keccak256("PriceUpdated(uint8,uint256,uint256)"));

    struct SourceConfig {
        uint256 chainId;
        address feed;
    }

    uint256 public immutable destinationChainId;
    address public immutable destinationReceiver;
    uint64 public immutable callbackGasLimit;

    uint256 public immutable ethereumSourceChainId;
    uint256 public immutable baseSourceChainId;
    uint256 public immutable arbitrumSourceChainId;

    uint256 public ethereumPriceBps = PEG_BPS;
    uint256 public basePriceBps = PEG_BPS;
    uint256 public arbitrumPriceBps = PEG_BPS;

    IPegKeeper.Stage public currentStage;

    event AlertCallbackRequested(
        IPegKeeper.Stage indexed stage,
        uint8 indexed chainsAffected,
        uint256 ethereumPriceBps,
        uint256 basePriceBps,
        uint256 arbitrumPriceBps,
        uint256 timestamp
    );

    constructor(
        uint256 destinationChainId_,
        address destinationReceiver_,
        uint64 callbackGasLimit_,
        SourceConfig memory ethereumSource_,
        SourceConfig memory baseSource_,
        SourceConfig memory arbitrumSource_
    ) payable {
        if (destinationReceiver_ == address(0)) revert InvalidReceiver();
        if (destinationChainId_ == 0) revert InvalidDestinationChain();
        if (callbackGasLimit_ == 0) revert InvalidGasLimit();
        if (
            ethereumSource_.chainId == 0 || ethereumSource_.feed == address(0)
                || baseSource_.chainId == 0 || baseSource_.feed == address(0)
                || arbitrumSource_.chainId == 0 || arbitrumSource_.feed == address(0)
        ) revert InvalidSourceConfig();

        destinationChainId = destinationChainId_;
        destinationReceiver = destinationReceiver_;
        callbackGasLimit = callbackGasLimit_;

        ethereumSourceChainId = ethereumSource_.chainId;
        baseSourceChainId = baseSource_.chainId;
        arbitrumSourceChainId = arbitrumSource_.chainId;
        currentStage = IPegKeeper.Stage.GREEN;

        // Lasna currently charges subscription debt through the 0x64 system helper.
        addAuthorizedSender(SYSTEM_CONTRACT_HELPER);

        if (!vm) {
            _subscribe(ethereumSource_);
            _subscribe(baseSource_);
            _subscribe(arbitrumSource_);
        }
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log) external override vmOnly {
        if (log.topic_0 != PRICE_UPDATED_TOPIC) revert InvalidEventTopic();
        if (log.data.length != 64) revert InvalidEventData();

        (, uint256 newPriceBps) = abi.decode(log.data, (uint256, uint256));
        _storePrice(log.chain_id, newPriceBps);
        _evaluateAndDispatch();
    }

    function _subscribe(SourceConfig memory source) internal {
        service.subscribe(
            source.chainId,
            source.feed,
            PRICE_UPDATED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _storePrice(uint256 chainId, uint256 newPriceBps) internal {
        if (chainId == ethereumSourceChainId) {
            ethereumPriceBps = newPriceBps;
            return;
        }
        if (chainId == baseSourceChainId) {
            basePriceBps = newPriceBps;
            return;
        }
        if (chainId == arbitrumSourceChainId) {
            arbitrumPriceBps = newPriceBps;
            return;
        }
        revert UnsupportedSourceChain(chainId);
    }

    function _evaluateAndDispatch() internal {
        uint8 chainsAffected = 0;
        uint256 worst = PEG_BPS;

        if (ethereumPriceBps <= YELLOW_THRESHOLD_BPS) {
            chainsAffected++;
            if (ethereumPriceBps < worst) worst = ethereumPriceBps;
        }
        if (basePriceBps <= YELLOW_THRESHOLD_BPS) {
            chainsAffected++;
            if (basePriceBps < worst) worst = basePriceBps;
        }
        if (arbitrumPriceBps <= YELLOW_THRESHOLD_BPS) {
            chainsAffected++;
            if (arbitrumPriceBps < worst) worst = arbitrumPriceBps;
        }

        if (chainsAffected < 2) {
            if (chainsAffected == 0 && currentStage != IPegKeeper.Stage.GREEN) {
                _dispatch(IPegKeeper.Stage.GREEN, 0);
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
            _dispatch(next, chainsAffected);
        }
    }

    function _dispatch(IPegKeeper.Stage nextStage, uint8 chainsAffected) internal {
        currentStage = nextStage;

        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage: nextStage,
            ethereumPriceBps: ethereumPriceBps,
            basePriceBps: basePriceBps,
            arbitrumPriceBps: arbitrumPriceBps,
            chainsAffected: chainsAffected,
            timestamp: block.timestamp
        });

        emit Callback(
            destinationChainId,
            destinationReceiver,
            callbackGasLimit,
            abi.encodeWithSelector(
                IReactiveMonitor.receiveReactiveAlert.selector,
                address(0),
                alert
            )
        );

        emit AlertCallbackRequested(
            nextStage,
            chainsAffected,
            ethereumPriceBps,
            basePriceBps,
            arbitrumPriceBps,
            block.timestamp
        );
    }

}
