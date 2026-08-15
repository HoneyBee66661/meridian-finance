// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IReentrancyLab
/// @notice I-prefix interface — full failure surface (Ch 2 lock).
interface IReentrancyLab {
    error ReentrantCall();
    error InsufficientBalance(uint256 have, uint256 want);

    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function withdrawCEI(uint256 amount) external;
    function withdrawGuarded(uint256 amount) external;
    function transferTo(address to, uint256 amount) external;
    function balanceOf(address who) external view returns (uint256);
}
