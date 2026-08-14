// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IForkProbe} from "./IForkProbe.sol";

/// @notice Ch 11 lab contract: a deliberately small owner-gated, time-gated
///         state machine whose tests demonstrate unit-test isolation and
///         mainnet-fork integration. NOT protocol code.
/// @dev The Ch 20 MeridianVault will need the same test shapes this probe
///      teaches: fresh-state isolation, time travel, and fork integration
///      against real tokens and oracles.
contract ForkProbe is IForkProbe {
    address public immutable owner;
    uint256 public value;
    uint256 public immutable lockUntil;

    /// @dev Probe lock period — the vault's accrual gates will be similar.
    uint256 public constant LOCK_DURATION = 7 days;
    /// @dev Probe accrual rate: 1e18 probe-units per second after lock expiry.
    uint256 public constant ACCRUAL_RATE = 1e18;

    constructor(address owner_) {
        owner = owner_;
        lockUntil = block.timestamp + LOCK_DURATION;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);
        _;
    }

    /// @notice Owner-gated state write (the access-control surface every test
    ///         must exercise both ways).
    function setValue(uint256 newValue) external onlyOwner {
        value = newValue;
        emit ValueSet(newValue);
    }

    /// @notice Unrestricted mutation — the isolation demo: two tests, one
    ///         mutates, the other must observe a fresh copy of the world.
    function poke() external {
        value += 1;
    }

    /// @notice Time-gated view — returns accrued probe-units after the lock.
    function accrue() external view returns (uint256) {
        if (block.timestamp < lockUntil) revert AccrualNotMature(lockUntil, block.timestamp);
        return (block.timestamp - lockUntil) * ACCRUAL_RATE;
    }
}
