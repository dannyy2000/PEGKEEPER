// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPegKeeper} from "./IPegKeeper.sol";

interface IReactiveMonitor {

    /// @notice Called by Reactive Network when a subscribed price feed event fires
    /// @dev Aggregates signals across chains — only fires alert if multiple chains show pressure
    function react(bytes calldata eventData) external;

    /// @notice Called on the destination chain by Reactive Network's callback proxy.
    /// @param rvmId The ReactVM identifier injected by Reactive Network into callback payloads.
    /// @param alert The depeg alert that should be forwarded to PegKeeper.
    function receiveReactiveAlert(address rvmId, IPegKeeper.DepegAlert calldata alert) external;

    /// @notice Set the PegKeeper hook address on Unichain that this monitor sends alerts to
    function setHook(address hook) external;

    /// @notice Set the authorized Reactive sender RVM identifier for cross-chain callbacks.
    function setAuthorizedReactiveSender(address rvmId) external;
}
