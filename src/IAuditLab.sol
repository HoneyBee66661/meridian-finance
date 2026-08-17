// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAuditLab
/// @notice I-prefix interface — the audit target with intentional findings.
interface IAuditLab {
    error Unauthorized(address caller);
    error InsufficientBalance(uint256 have, uint256 want);

    function withdraw(uint256 amount) external;
    function setAdmin(address newAdmin) external;
    function transferTo(address to, uint256 amount) external;
    function balanceOf(address who) external view returns (uint256);
}
