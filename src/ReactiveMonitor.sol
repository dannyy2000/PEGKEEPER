// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Reactive Smart Contract deployed on Reactive Kopli
// Subscribes to price feed events on Ethereum, Base, and Arbitrum simultaneously
//
// react() fires on every price update event across all 3 chains
// Aggregates signals — single chain price drop is ignored (noise)
// Only sends alert to PegKeeper when multiple chains show depeg pressure
// Calculates Stage (YELLOW / ORANGE / RED) based on price depth + chains affected
// Sends DepegAlert callback to PegKeeper on Unichain
// Implements IReactiveMonitor
