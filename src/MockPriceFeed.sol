// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Fake price feed for testing and demo
// Replaces real Chainlink/price feed during tests
// Exposes setter so tests can push any price to any chain
// e.g. setPrice(chain, priceBps) to simulate USDC at $0.991 on Ethereum
// Used in both PegKeeper.t.sol and ReactiveMonitor.t.sol
