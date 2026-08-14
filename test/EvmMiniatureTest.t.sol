// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EvmMiniature} from "../src/EvmMiniature.sol";

/// @notice Foundry lab for Chapter 1: EVM execution model semantics.
contract EvmMiniatureTest is Test {
    EvmMiniature internal mini;

    function setUp() public {
        mini = new EvmMiniature();
    }

    /// @notice Unit test: storage write + read roundtrip.
    function test_SstoreSloadRoundtrip() public {
        mini.sstore(7, 1234);
        assertEq(mini.sload(7), 1234);
    }

    /// @notice Unit test: clearing a slot reads back zero.
    function test_ClearSlot() public {
        mini.sstore(9, 99);
        mini.sstore(9, 0);
        assertEq(mini.sload(9), 0);
    }

    /// @notice Fuzz test: arbitrary slot/value roundtrip preserves value.
    /// @param slot Arbitrary storage slot.
    /// @param value Arbitrary value.
    function testFuzz_Roundtrip(uint256 slot, uint256 value) public {
        mini.sstore(slot, value);
        assertEq(mini.sload(slot), value);
    }

    /// @notice Invariant-style test: atomicity — a reverting call leaves
    ///         no partial state.
    function test_RevertIsAtomic() public {
        mini.sstore(0, 1);
        vm.expectRevert(bytes("atomicity demo"));
        mini.revertIsAtomic(true);
        // the pending write to slot 0 must be gone
        assertEq(mini.sload(0), 1, "slot 0 must retain pre-call value");
    }

    /// @notice Gas snapshot: measure the real cost asymmetry.
    function test_GasCostAsymmetry() public {
        uint256 setGas = gasleft();
        mini.sstore(42, 1);
        uint256 setUsed = setGas - gasleft();

        uint256 clearGas = gasleft();
        mini.sstore(42, 0);
        uint256 clearUsed = clearGas - gasleft();

        // Non-zero write must be dramatically more expensive than clear
        assertGt(setUsed, clearUsed, "set must cost more than clear");
        emit log_named_uint("gas: set (approx)", setUsed);
        emit log_named_uint("gas: clear (approx)", clearUsed);
    }
}
