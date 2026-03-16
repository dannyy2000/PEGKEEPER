// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";
import {IReactiveMonitor} from "../src/interfaces/IReactiveMonitor.sol";
import {ReactiveSender} from "../src/ReactiveSender.sol";

contract MockReactiveSystemContract {
    struct Subscription {
        uint256 chainId;
        address feed;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription[] internal subscriptions;

    receive() external payable {}

    function subscribe(
        uint256 chainId,
        address feed,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        subscriptions.push(Subscription(chainId, feed, topic0, topic1, topic2, topic3));
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function getSubscription(uint256 index) external view returns (Subscription memory) {
        return subscriptions[index];
    }
}

contract ReactiveSenderTest is Test {
    address internal constant REACTIVE_SERVICE = address(0x0000000000000000000000000000000000fffFfF);
    uint256 internal constant DESTINATION_CHAIN_ID = 1301;
    address internal constant DESTINATION_RECEIVER = address(0x35067ef1c48207F633030BcB2c682f84e8918ec2);
    uint64 internal constant CALLBACK_GAS_LIMIT = 500_000;

    uint256 internal constant ETHEREUM_SEPOLIA = 11155111;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    address internal constant ETH_FEED = address(0x1111);
    address internal constant BASE_FEED = address(0x2222);
    address internal constant ARB_FEED = address(0x3333);

    ReactiveSender internal sender;

    event Callback(
        uint256 indexed chain_id,
        address indexed _contract,
        uint64 indexed gas_limit,
        bytes payload
    );

    function setUp() public {
        sender = new ReactiveSender(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            ReactiveSender.SourceConfig({chainId: ETHEREUM_SEPOLIA, feed: ETH_FEED}),
            ReactiveSender.SourceConfig({chainId: BASE_SEPOLIA, feed: BASE_FEED}),
            ReactiveSender.SourceConfig({chainId: ARBITRUM_SEPOLIA, feed: ARB_FEED})
        );
    }

    function test_constructor_revertsOnZeroReceiver() public {
        vm.expectRevert(ReactiveSender.InvalidReceiver.selector);
        new ReactiveSender(
            DESTINATION_CHAIN_ID,
            address(0),
            CALLBACK_GAS_LIMIT,
            ReactiveSender.SourceConfig({chainId: ETHEREUM_SEPOLIA, feed: ETH_FEED}),
            ReactiveSender.SourceConfig({chainId: BASE_SEPOLIA, feed: BASE_FEED}),
            ReactiveSender.SourceConfig({chainId: ARBITRUM_SEPOLIA, feed: ARB_FEED})
        );
    }

    function test_constructor_revertsOnZeroGasLimit() public {
        vm.expectRevert(ReactiveSender.InvalidGasLimit.selector);
        new ReactiveSender(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            0,
            ReactiveSender.SourceConfig({chainId: ETHEREUM_SEPOLIA, feed: ETH_FEED}),
            ReactiveSender.SourceConfig({chainId: BASE_SEPOLIA, feed: BASE_FEED}),
            ReactiveSender.SourceConfig({chainId: ARBITRUM_SEPOLIA, feed: ARB_FEED})
        );
    }

    function test_constructor_revertsOnZeroDestinationChain() public {
        vm.expectRevert(ReactiveSender.InvalidDestinationChain.selector);
        new ReactiveSender(
            0,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            ReactiveSender.SourceConfig({chainId: ETHEREUM_SEPOLIA, feed: ETH_FEED}),
            ReactiveSender.SourceConfig({chainId: BASE_SEPOLIA, feed: BASE_FEED}),
            ReactiveSender.SourceConfig({chainId: ARBITRUM_SEPOLIA, feed: ARB_FEED})
        );
    }

    function test_constructor_revertsOnInvalidSourceConfig() public {
        vm.expectRevert(ReactiveSender.InvalidSourceConfig.selector);
        new ReactiveSender(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            ReactiveSender.SourceConfig({chainId: 0, feed: ETH_FEED}),
            ReactiveSender.SourceConfig({chainId: BASE_SEPOLIA, feed: BASE_FEED}),
            ReactiveSender.SourceConfig({chainId: ARBITRUM_SEPOLIA, feed: ARB_FEED})
        );
    }

    function test_constructor_subscribesToAllSourcesOutsideVm() public {
        MockReactiveSystemContract mockService = new MockReactiveSystemContract();
        vm.etch(REACTIVE_SERVICE, address(mockService).code);
        MockReactiveSystemContract reactiveService = MockReactiveSystemContract(payable(REACTIVE_SERVICE));

        ReactiveSender liveSender = new ReactiveSender(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            ReactiveSender.SourceConfig({chainId: ETHEREUM_SEPOLIA, feed: ETH_FEED}),
            ReactiveSender.SourceConfig({chainId: BASE_SEPOLIA, feed: BASE_FEED}),
            ReactiveSender.SourceConfig({chainId: ARBITRUM_SEPOLIA, feed: ARB_FEED})
        );

        assertEq(address(liveSender).code.length > 0, true);
        assertEq(reactiveService.subscriptionCount(), 3);

        (uint256 chainId0, address feed0, uint256 topic00,,,) = _subscription(reactiveService, 0);
        (uint256 chainId1, address feed1, uint256 topic01,,,) = _subscription(reactiveService, 1);
        (uint256 chainId2, address feed2, uint256 topic02,,,) = _subscription(reactiveService, 2);

        assertEq(chainId0, ETHEREUM_SEPOLIA);
        assertEq(feed0, ETH_FEED);
        assertEq(topic00, senderTopic());

        assertEq(chainId1, BASE_SEPOLIA);
        assertEq(feed1, BASE_FEED);
        assertEq(topic01, senderTopic());

        assertEq(chainId2, ARBITRUM_SEPOLIA);
        assertEq(feed2, ARB_FEED);
        assertEq(topic02, senderTopic());
    }

    function test_react_revertsWhenNotVm() public {
        MockReactiveSystemContract mockService = new MockReactiveSystemContract();
        vm.etch(REACTIVE_SERVICE, address(mockService).code);

        ReactiveSender liveSender = new ReactiveSender(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            ReactiveSender.SourceConfig({chainId: ETHEREUM_SEPOLIA, feed: ETH_FEED}),
            ReactiveSender.SourceConfig({chainId: BASE_SEPOLIA, feed: BASE_FEED}),
            ReactiveSender.SourceConfig({chainId: ARBITRUM_SEPOLIA, feed: ARB_FEED})
        );

        vm.expectRevert("VM only");
        liveSender.react(_log(ETHEREUM_SEPOLIA, 10_000, 9_970));
    }

    function test_singleChainPressure_doesNotEmitCallback() public {
        vm.recordLogs();
        sender.react(_log(ETHEREUM_SEPOLIA, 10_000, 9_970));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    function test_twoChainsPressure_emitsYellowCallback() public {
        sender.react(_log(ETHEREUM_SEPOLIA, 10_000, 9_970));

        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage: IPegKeeper.Stage.YELLOW,
            ethereumPriceBps: 9_970,
            basePriceBps: 9_960,
            arbitrumPriceBps: 10_000,
            chainsAffected: 2,
            timestamp: block.timestamp
        });

        vm.expectEmit(true, true, true, true);
        emit Callback(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSelector(
                IReactiveMonitor.receiveReactiveAlert.selector,
                address(0),
                alert
            )
        );

        sender.react(_log(BASE_SEPOLIA, 10_000, 9_960));

        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.YELLOW));
    }

    function test_recovery_emitsGreenCallback() public {
        sender.react(_log(ETHEREUM_SEPOLIA, 10_000, 9_840));
        sender.react(_log(BASE_SEPOLIA, 10_000, 9_840));
        sender.react(_log(ARBITRUM_SEPOLIA, 10_000, 9_840));

        sender.react(_log(ETHEREUM_SEPOLIA, 9_840, 10_000));
        sender.react(_log(BASE_SEPOLIA, 9_840, 10_000));

        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage: IPegKeeper.Stage.GREEN,
            ethereumPriceBps: 10_000,
            basePriceBps: 10_000,
            arbitrumPriceBps: 10_000,
            chainsAffected: 0,
            timestamp: block.timestamp
        });

        vm.expectEmit(true, true, true, true);
        emit Callback(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSelector(
                IReactiveMonitor.receiveReactiveAlert.selector,
                address(0),
                alert
            )
        );

        sender.react(_log(ARBITRUM_SEPOLIA, 9_840, 10_000));

        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    function test_react_revertsOnMalformedData() public {
        vm.expectRevert(ReactiveSender.InvalidEventData.selector);
        sender.react(_malformedLog(ETHEREUM_SEPOLIA));
    }

    function test_react_revertsOnInvalidTopic() public {
        vm.expectRevert(ReactiveSender.InvalidEventTopic.selector);
        sender.react(_logWithTopic(ETHEREUM_SEPOLIA, 10_000, 9_970, uint256(123)));
    }

    function test_react_revertsOnUnsupportedSourceChain() public {
        vm.expectRevert(abi.encodeWithSelector(ReactiveSender.UnsupportedSourceChain.selector, uint256(1)));
        sender.react(_log(1, 10_000, 9_970));
    }

    function test_threeChainsPressure_emitsOrangeCallback() public {
        sender.react(_log(ETHEREUM_SEPOLIA, 10_000, 9_970));
        sender.react(_log(BASE_SEPOLIA, 10_000, 9_960));

        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage: IPegKeeper.Stage.ORANGE,
            ethereumPriceBps: 9_970,
            basePriceBps: 9_960,
            arbitrumPriceBps: 9_910,
            chainsAffected: 3,
            timestamp: block.timestamp
        });

        vm.recordLogs();
        sender.react(_log(ARBITRUM_SEPOLIA, 10_000, 9_910));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], keccak256("Callback(uint256,address,uint64,bytes)"));
        assertEq(logs[0].topics[1], bytes32(DESTINATION_CHAIN_ID));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(DESTINATION_RECEIVER))));
        assertEq(logs[0].topics[3], bytes32(uint256(CALLBACK_GAS_LIMIT)));
        assertEq(
            abi.decode(logs[0].data, (bytes)),
            abi.encodeWithSelector(
                IReactiveMonitor.receiveReactiveAlert.selector,
                address(0),
                alert
            )
        );

        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.ORANGE));
    }

    function test_sameStagePressure_doesNotEmitDuplicateCallback() public {
        sender.react(_log(ETHEREUM_SEPOLIA, 10_000, 9_970));
        sender.react(_log(BASE_SEPOLIA, 10_000, 9_960));
        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.YELLOW));

        vm.recordLogs();
        sender.react(_log(ARBITRUM_SEPOLIA, 10_000, 9_980));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.YELLOW));
    }

    function test_threeChainsPressure_emitsRedCallback() public {
        sender.react(_log(ETHEREUM_SEPOLIA, 10_000, 9_970));
        sender.react(_log(BASE_SEPOLIA, 10_000, 9_960));

        IPegKeeper.DepegAlert memory alert = IPegKeeper.DepegAlert({
            stage: IPegKeeper.Stage.RED,
            ethereumPriceBps: 9_970,
            basePriceBps: 9_960,
            arbitrumPriceBps: 9_840,
            chainsAffected: 3,
            timestamp: block.timestamp
        });

        vm.expectEmit(true, true, true, true);
        emit Callback(
            DESTINATION_CHAIN_ID,
            DESTINATION_RECEIVER,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSelector(
                IReactiveMonitor.receiveReactiveAlert.selector,
                address(0),
                alert
            )
        );

        sender.react(_log(ARBITRUM_SEPOLIA, 10_000, 9_840));
        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.RED));
    }

    function _log(
        uint256 chainId,
        uint256 oldPriceBps,
        uint256 newPriceBps
    ) internal pure returns (IReactive.LogRecord memory logRecord) {
        return _logWithTopic(chainId, oldPriceBps, newPriceBps, senderTopic());
    }

    function _logWithTopic(
        uint256 chainId,
        uint256 oldPriceBps,
        uint256 newPriceBps,
        uint256 topic0
    ) internal pure returns (IReactive.LogRecord memory logRecord) {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0),
            topic_0: topic0,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(oldPriceBps, newPriceBps),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _malformedLog(uint256 chainId) internal pure returns (IReactive.LogRecord memory logRecord) {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0),
            topic_0: senderTopic(),
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint256(1)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _subscription(MockReactiveSystemContract mockService, uint256 index)
        internal
        view
        returns (uint256 chainId, address feed, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3)
    {
        MockReactiveSystemContract.Subscription memory sub = mockService.getSubscription(index);
        return (sub.chainId, sub.feed, sub.topic0, sub.topic1, sub.topic2, sub.topic3);
    }

    function senderTopic() internal pure returns (uint256) {
        return uint256(keccak256("PriceUpdated(uint8,uint256,uint256)"));
    }
}
