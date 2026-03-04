// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Uniswap v4 hook deployed on Unichain
// Hooks used: afterInitialize, beforeSwap, beforeAddLiquidity, afterAddLiquidity
//
// afterInitialize    — register pool with protection system
// beforeSwap         — apply dynamic fee based on current Stage
// beforeAddLiquidity — block deposits when Stage is ORANGE or RED
// afterAddLiquidity  — register LP protection profile (Conservative / Balanced / Aggressive)
// receiveAlert()     — called by ReactiveMonitor via Reactive callback, updates Stage
//
// At RED stage: auto-withdraw Conservative LPs before crisis hits
// Implements IPegKeeper
