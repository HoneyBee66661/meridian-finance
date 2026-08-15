// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IIndexLab
/// @notice I-prefix interface — the event-surface lab (Ch 37).
interface IIndexLab {
    event Borrow(address indexed user, uint256 amount, uint256 blockNumber);
    event Repay(address indexed user, uint256 amount, uint256 blockNumber);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    function borrow(uint256 amount) external;
    function repay(uint256 amount) external;
    function liquidate(address user, uint256 amount) external;
    function debtOf(address user) external view returns (uint256);
}
