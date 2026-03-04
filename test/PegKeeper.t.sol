// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Unit tests for PegKeeper hook logic
//
// Test cases:
// - receiveAlert(YELLOW) → fee updates to 0.05%
// - receiveAlert(ORANGE) → fee updates to 0.30%, deposits blocked
// - receiveAlert(RED)    → fee updates to max, deposits blocked, Conservative LPs withdrawn
// - receiveAlert(GREEN)  → fee returns to 0.01%, deposits re-open
// - beforeAddLiquidity at GREEN → deposit allowed
// - beforeAddLiquidity at ORANGE → deposit blocked
// - afterAddLiquidity → LP profile stored correctly
// - beforeSwap at GREEN  → 0.01% fee applied
// - beforeSwap at YELLOW → 0.05% fee applied
// - beforeSwap at RED    → max fee applied
// - stage steps back down correctly: RED → ORANGE → YELLOW → GREEN on recovery alerts
