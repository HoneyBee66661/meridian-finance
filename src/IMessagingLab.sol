// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMessagingLab
/// @notice I-prefix interface — a generalized message-passing receiver.
interface IMessagingLab {
    error UnauthorizedSource(address sender);
    error Replay(bytes32 hash);
    error UnauthorizedPayload(bytes4 selector);
    error InvalidAmount(uint256 amount, uint256 max);

    function receiveMessage(address sourceSender, bytes calldata payload) external;
}
