// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUpgradeLab
/// @notice I-prefix interface — a minimal transparent proxy.
interface IUpgradeLab {
    error NotAdmin(address caller);
    error InvalidImplementation(address impl);

    function upgradeTo(address newImplementation) external;
    function admin() external view returns (address);
}
