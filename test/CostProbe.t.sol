// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CostProbe} from "../src/CostProbe.sol";

/// @notice Lab for Project 1.1: measure the EVM cost model with `gasleft()`
///         deltas (loop-amplified min-delta methodology, Ch 1/2).
/// @dev Plain `forge test -vvv` only — never `--gas-report` here: it distorts
///      `gasleft()`-based measurements.
contract CostProbeTest is Test {
    CostProbe internal probe;

    function setUp() public {
        probe = new CostProbe();
    }

    /// @dev Loop-amplified min-delta for a state-changing probe function.
    function _minDelta(address target, bytes4 sig, uint256 k) internal returns (uint256) {
        uint256 best = type(uint256).max;
        for (uint256 i; i < 8; ++i) {
            uint256 g0 = gasleft();
            (bool ok,) = target.call(abi.encodeWithSelector(sig, k));
            require(ok, "call failed");
            uint256 used = g0 - gasleft();
            if (used < best) best = used;
        }
        return best;
    }

    /// @dev Fresh (cold) SSTORE set must beat clear by roughly the EIP-2929/2200
    ///      gap (22,100 vs 5,000 cold on first touch, plus overhead).
    function test_FreshSetCostsMoreThanClear() public {
        // fresh slot each run: set then clear the same fresh slot in one tx
        uint256 g0 = gasleft();
        probe.writeSlot(1, 7);
        uint256 setUsed = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.clearSlot(1);
        uint256 clearUsed = g1 - gasleft();

        assertGt(setUsed, clearUsed, "set must cost more than clear");
        emit log_named_uint("cold set (approx)", setUsed);
        emit log_named_uint("cold clear (approx)", clearUsed);
    }

    /// @dev Second read of the same slot in one tx must be warm (< cold).
    function test_WarmReadCheaperThanColdRead() public {
        probe.readSlot(3); // warm the slot
        uint256 g0 = gasleft();
        probe.readSlot(3);
        uint256 warm = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.readSlot(4);
        uint256 cold = g1 - gasleft();

        assertGt(cold, warm, "cold read must cost more than warm");
        emit log_named_uint("warm read (approx)", warm);
        emit log_named_uint("cold read (approx)", cold);
    }

    /// @dev Memory expansion is quadratic-ish (3w + w^2/512): 1024 words must
    ///      cost meaningfully more than 64 words.
    function test_MemoryExpansionScales() public {
        uint256 g0 = gasleft();
        probe.expandMemory(64);
        uint256 small = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.expandMemory(1024);
        uint256 big = g1 - gasleft();

        assertGt(big, small);
        emit log_named_uint("expand 64 words (approx)", small);
        emit log_named_uint("expand 1024 words (approx)", big);
    }
}
