// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Ch 11 lab interface — unit & fork testing probes. NOT protocol code.
/// @dev Pedagogical only (standing convention: probe/lab contracts are tested,
///      measured, and never enter the protocol's dependency graph).
interface IForkProbe {
    error NotOwner(address caller, address owner);
    error AccrualNotMature(uint256 lockUntil, uint256 now);

    event ValueSet(uint256 value);

    function setValue(uint256 value) external;
    function poke() external;
    function accrue() external view returns (uint256);
    function value() external view returns (uint256);
    function owner() external view returns (address);
    function lockUntil() external view returns (uint256);
}
