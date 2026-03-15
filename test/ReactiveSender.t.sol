// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {IPegKeeper} from "../src/interfaces/IPegKeeper.sol";
import {IReactiveMonitor} from "../src/interfaces/IReactiveMonitor.sol";
import {ReactiveSender} from "../src/ReactiveSender.sol";

contract ReactiveSenderTest is Test {
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

    function test_singleChainPressure_doesNotEmitCallback() public {
        vm.recordLogs();
        sender.react(_log(ETHEREUM_SEPOLIA, 9_970));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    function test_twoChainsPressure_emitsYellowCallback() public {
        sender.react(_log(ETHEREUM_SEPOLIA, 9_970));

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

        sender.react(_log(BASE_SEPOLIA, 9_960));

        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.YELLOW));
    }

    function test_recovery_emitsGreenCallback() public {
        sender.react(_log(ETHEREUM_SEPOLIA, 9_840));
        sender.react(_log(BASE_SEPOLIA, 9_840));
        sender.react(_log(ARBITRUM_SEPOLIA, 9_840));

        sender.react(_log(ETHEREUM_SEPOLIA, 10_000));
        sender.react(_log(BASE_SEPOLIA, 10_000));

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

        sender.react(_log(ARBITRUM_SEPOLIA, 10_000));

        assertEq(uint8(sender.currentStage()), uint8(IPegKeeper.Stage.GREEN));
    }

    function test_react_revertsOnNonPositiveAnswer() public {
        vm.expectRevert(abi.encodeWithSelector(ReactiveSender.InvalidAnswer.selector, int256(0)));
        sender.react(_rawLog(ETHEREUM_SEPOLIA, 0));
    }

    function _log(uint256 chainId, uint256 priceBps) internal pure returns (IReactive.LogRecord memory logRecord) {
        return _rawLog(chainId, _answerFromBps(priceBps));
    }

    function _rawLog(uint256 chainId, uint256 answer) internal pure returns (IReactive.LogRecord memory logRecord) {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0),
            topic_0: senderTopic(),
            topic_1: answer,
            topic_2: 1,
            topic_3: 0,
            data: abi.encode(uint256(1_234_567)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function senderTopic() internal pure returns (uint256) {
        return uint256(keccak256("AnswerUpdated(int256,uint256,uint256)"));
    }

    function _answerFromBps(uint256 priceBps) internal pure returns (uint256) {
        return (priceBps * 1e8) / 10_000;
    }
}
