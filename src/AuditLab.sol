// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAuditLab} from "./IAuditLab.sol";

/// @title AuditLab
/// @notice Pedagogical audit target with THREE intentional findings
///         (see AuditLabTest + the report in docs/mini-audit.md).
/// @dev NOT part of the protocol — an audit exercise.
contract AuditLab is IAuditLab {
    mapping(address => uint256) public balances;
    address public admin;

    constructor() {
        admin = msg.sender;
        balances[msg.sender] = 100 ether;
    }

    /// @dev The deposit path: funds the contract AND credits balances[msg.sender].
    ///      Without it no balance entry can ever be credited and the findings
    ///      (and Exercise 2) are not exercisable.
    receive() external payable {
        balances[msg.sender] += msg.value;
    }

    /// @dev FINDING 1 (Critical): admin can be changed by anyone (no gate) —
    ///      the unguarded admin key, the severity ladder's Critical example.
    function setAdmin(address newAdmin) external {
        admin = newAdmin;
    }

    /// @dev FINDING 2 (Critical): CEI violation — the transfer (interaction)
    ///      precedes the balance write (effect), with no balance require and
    ///      no reentrancy guard. A reentrant caller exploits the stale
    ///      balance; an overdraw underflows.
    function withdraw(uint256 amount) external {
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "push failed");
        balances[msg.sender] -= amount; // effect AFTER the interaction
    }

    /// @dev FINDING 3 (Medium): recipient balance updated before sender —
    ///      the cross-function reentrancy twin of Finding 2 (Ch 24): a
    ///      mid-withdraw transferTo moves the stale (not-yet-decremented)
    ///      balance.
    function transferTo(address to, uint256 amount) external {
        balances[to] += amount;
        balances[msg.sender] -= amount;
    }

    function balanceOf(address who) external view returns (uint256) {
        return balances[who];
    }
}
