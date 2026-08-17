// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBridgeLab
/// @notice I-prefix interface — full failure surface (Ch 2 lock).
interface IBridgeLab {
    error UnauthorizedSender(address sender);
    error UnauthorizedPayload(bytes4 selector);
    error MessageReplay(bytes32 hash);
    error InvalidMarket(address market);
    error ValueOutOfBounds(uint256 value);

    function executeMessage(address sourceSender, bytes calldata payload) external;
}
