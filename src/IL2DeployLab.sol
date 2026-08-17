// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IL2DeployLab
/// @notice I-prefix interface — the L2 deployment's cross-chain market.
interface IL2DeployLab {
    error UnauthorizedSender(address sender);
    error UnauthorizedPayload(bytes4 selector);
    error OracleStale(uint256 timestamp, uint256 maxAge);

    function executeCrossMessage(address sourceSender, bytes calldata payload) external;
    function setOraclePrice(uint256 price, uint256 timestamp) external;
    function healthOf(address user) external view returns (uint256);
}
