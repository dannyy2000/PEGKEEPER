// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IReactiveMonitor {

    /// @notice Called by Reactive Network when a subscribed price feed event fires
    /// @dev Aggregates signals across chains — only fires alert if multiple chains show pressure
    function react(bytes calldata eventData) external;

    /// @notice Set the PegKeeper hook address on Unichain that this monitor sends alerts to
    function setHook(address hook) external;
}
