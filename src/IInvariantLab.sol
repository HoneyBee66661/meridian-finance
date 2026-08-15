// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IInvariantLab
/// @notice I-prefix interface — full failure surface (Ch 2 lock).
interface IInvariantLab {
    error ZeroShares();
    error ZeroAssets();

    function deposit(uint256 assets) external returns (uint256 shares);
    function redeem(uint256 shares) external returns (uint256 assets);
    function totalAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function roundTrip(uint256 assets) external view returns (uint256);
    function setUseCeil(bool v) external;
}
