// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReentrancyLab} from "./IReentrancyLab.sol";

/// @title ReentrancyLab
/// @notice Pedagogical measurement contract: the three shapes side by side.
/// @dev NOT part of the Meridian protocol — a lab, per standing convention.
contract ReentrancyLab is IReentrancyLab {
    mapping(address => uint256) public balances;
    // No storage guard variable: the guard lives in EIP-1153 transient
    // storage (slot 0 of the per-transaction transient store), set and
    // checked via tstore/tload inline assembly (^0.8.24 predates the
    // `transient` keyword of 0.8.28).

    constructor() {
        balances[msg.sender] = 100 ether;
        // seed a second account so cross-function tests have a victim
        balances[address(0xBEEF)] = 100 ether;
    }

    /// @dev Honest funding path: sets balances[msg.sender], so the classic
    ///      drain test attacks against a REAL balance entry.
    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    /// @dev VULNERABLE (classic): write after external call.
    function withdraw(uint256 amount) external {
        if (balances[msg.sender] < amount) {
            revert InsufficientBalance(balances[msg.sender], amount);
        }
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "push failed");
        balances[msg.sender] -= amount; // too late
    }

    /// @dev CEI: write before the call. Classic family killed.
    function withdrawCEI(uint256 amount) external {
        if (balances[msg.sender] < amount) {
            revert InsufficientBalance(balances[msg.sender], amount);
        }
        balances[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "push failed");
    }

    /// @dev CEI + REAL EIP-1153 transient guard for the cross-function family.
    ///      tstore slot 0 is auto-cleared at tx end — no storage slot, no
    ///      manual release, no stuck-guard class. The tload check and the
    ///      tstore set run back-to-back with no external call between them,
    ///      so the guard is atomic within this frame; a reentrant frame sees
    ///      the flag and reverts with the declared ReentrantCall error.
    function withdrawGuarded(uint256 amount) external {
        uint256 guard;
        assembly {
            guard := tload(0)
            tstore(0, 1)
        }
        if (guard != 0) revert ReentrantCall();
        if (balances[msg.sender] < amount) {
            revert InsufficientBalance(balances[msg.sender], amount);
        }
        balances[msg.sender] -= amount;
        (bool ok, bytes memory ret) = msg.sender.call{value: amount}("");
        if (!ok) {
            // propagate the inner revert reason (e.g. ReentrantCall)
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
    }

    /// @dev A second entry point sharing `balances` — cross-function twin.
    ///      Guarded: re-entry from withdrawGuarded's call is rejected.
    function transferTo(address to, uint256 amount) external {
        uint256 guard;
        assembly {
            guard := tload(0)
            tstore(0, 1)
        }
        if (guard != 0) revert ReentrantCall();
        if (balances[msg.sender] < amount) {
            revert InsufficientBalance(balances[msg.sender], amount);
        }
        balances[msg.sender] -= amount;
        balances[to] += amount;
        // tstore slot 0 auto-cleared at tx end — no manual release needed.
    }

    function balanceOf(address who) external view returns (uint256) {
        return balances[who];
    }

    receive() external payable {}
}
