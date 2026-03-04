// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared interface between ReactiveMonitor (sends alert) and PegKeeper (receives alert)
/// @dev Both contracts import this — agree on this before splitting work
interface IPegKeeper {

    enum Stage { GREEN, YELLOW, ORANGE, RED }

    struct DepegAlert {
        Stage   stage;               // severity level calculated by ReactiveMonitor
        uint256 ethereumPriceBps;    // USDC price on Ethereum (e.g. 9970 = $0.997)
        uint256 basePriceBps;        // USDC price on Base
        uint256 arbitrumPriceBps;    // USDC price on Arbitrum
        uint8   chainsAffected;      // how many chains showing depeg pressure
        uint256 timestamp;           // when Reactive fired this alert
    }

    /// @notice Called by ReactiveMonitor via Reactive callback when depeg pressure is detected
    /// @dev Updates the pool's protection stage — triggers fee + range adjustments
    function receiveAlert(DepegAlert calldata alert) external;

    /// @notice Returns the current protection stage of the pool
    function getProtectionStage() external view returns (Stage);
}
