// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Unit tests for ReactiveMonitor (Reactive contract)
//
// Test cases:
// - single chain price drop ($0.997 on Ethereum only) → no alert fired
// - two chains showing pressure → alert fired
// - three chains showing pressure → alert fired at higher severity
// - price $0.997 on 2 chains → YELLOW alert
// - price $0.991 on 3 chains → ORANGE alert
// - price $0.984 on 3 chains → RED alert
// - chainsAffected field populated correctly in DepegAlert
// - timestamp populated correctly
// - recovery: prices back to $1.00 → GREEN alert fired
