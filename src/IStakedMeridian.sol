// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStakedMeridian
/// @notice I-prefix interface: the full failure surface in one file (Ch 2 lock).
interface IStakedMeridian {
    error ZeroShares();
    error ZeroAssets();
    error InsufficientBalance(uint256 have, uint256 want);
    error NotAuthorized(address caller);

    function notifyReward(uint256 amount) external;
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}
