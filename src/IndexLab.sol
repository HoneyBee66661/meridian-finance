// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIndexLab} from "./IIndexLab.sol";

/// @title IndexLab
/// @notice Pedagogical event-surface contract: emits the exact events a
///         subgraph folds (Ch 37). Event conventions per Ch 2 lock:
///         past-tense names, indexed where queried, data carries the payload.
/// @dev NOT part of the protocol.
contract IndexLab is IIndexLab {
    mapping(address => uint256) public debts;

    function borrow(uint256 amount) external {
        debts[msg.sender] += amount;
        emit Borrow(msg.sender, amount, block.number);
    }

    function repay(uint256 amount) external {
        debts[msg.sender] -= amount;
        emit Repay(msg.sender, amount, block.number);
    }

    function liquidate(address user, uint256 amount) external {
        debts[user] -= amount;
        emit Liquidation(user, msg.sender, amount, amount); // collateral simplified
    }

    function debtOf(address user) external view returns (uint256) {
        return debts[user];
    }
}
