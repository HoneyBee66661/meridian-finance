// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GasProbe} from "../src/GasProbe.sol";

/// @notice Foundry lab for Chapter 7: pin deltas, not absolutes. Plain
///         `forge test -vvv` only — `--gas-report` distorts `gasleft()`.
contract GasProbeTest is Test {
    GasProbe internal probe;

    function setUp() public {
        probe = new GasProbe();
    }

    /// @dev Cold read must beat warm read by the ~2,000 EIP-2929 delta.
    function testColdVsWarmRead() public {
        probe.setSlot(1, 42); // warms slot 1 AND the probe address this tx
        uint256 g0 = gasleft();
        probe.getSlot(1); // warm: ~100 + call overhead
        uint256 warm = g0 - gasleft();
        uint256 g1 = gasleft();
        probe.getSlot(2); // cold: ~2,100 + overhead
        uint256 cold = g1 - gasleft();
        assertGt(cold, warm + 1500); // the 2,000 delta dominates overhead
    }

    /// @dev gasleft() sees only the 2,900 charge; the 4,800 refund lands at tx end.
    function testClearRefundIsInvisibleToGasleft() public {
        probe.sstoreClear();
        // No assertion possible via gasleft() — documents the trap (Ch 7).
    }

    /// @dev First touch in a tx: cold set (22,100 + 2,100) must dwarf a warm reset (2,900).
    function testSstoreSetVsResetDelta() public {
        uint256 g0 = gasleft();
        probe.sstoreSet(); // cold set: 0 -> 1
        uint256 setCold = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.sstoreReset(); // warm reset: 1 -> 2
        uint256 resetWarm = g1 - gasleft();

        assertGt(setCold, resetWarm + 15000, "cold set must dwarf warm reset");
        emit log_named_uint("cold set (approx)", setCold);
        emit log_named_uint("warm reset (approx)", resetWarm);
    }

    /// @dev Dirty restore (2,900 + 100 net) must be at most ~reset + small delta;
    ///      the restore refund (2,800) is invisible to gasleft() mid-tx.
    function testDirtyRestoreVsReset() public {
        probe.sstoreSet(); // warm the scalar (now 1)
        uint256 g0 = gasleft();
        probe.sstoreDirtyRestore(); // 2 -> 1 (restore path)
        uint256 restore = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.sstoreReset(); // 1 -> 2 (plain reset)
        uint256 reset = g1 - gasleft();

        // restore charges 2,900 (write) minus the 2,800 refund, credited at tx
        // end — so mid-tx it looks like a full write. Loose sanity bound only.
        assertLt(restore, reset + 3000);
    }

    /// @dev Clear-then-set in one tx: second write is a reset, not a fresh set.
    function testClearThenSetSecondWriteIsWarm() public {
        probe.sstoreSet(); // warm the scalar (1)
        uint256 g0 = gasleft();
        probe.sstoreClearThenSet(); // 1 -> 0 -> 1
        uint256 both = g0 - gasleft();
        emit log_named_uint("clear+set (approx)", both);
        assertLt(both, 40000, "two warm writes, not a cold set");
    }

    /// @dev Second read of the same slot in one call is warm: two reads must
    ///      cost less than two cold reads (2,100 x2).
    function testTouchTwiceSecondReadWarm() public {
        probe.setSlot(5, 7); // warm slot 5
        uint256 g0 = gasleft();
        (uint256 a, uint256 b) = probe.touchTwice(5);
        uint256 used = g0 - gasleft();
        assertEq(a, b);
        assertLt(used, 2000, "two warm reads stay under one cold read");
        emit log_named_uint("two reads of warm slot (approx)", used);
    }

    /// @dev Memory expansion grows superlinearly (3w + w²/512). Warm the
    ///      address first so the cold CALL surcharge does not swamp the delta.
    function testMemoryExpansionGrows() public {
        probe.growMemory(1); // warm the address
        uint256 g0 = gasleft();
        probe.growMemory(16);
        uint256 small = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.growMemory(512);
        uint256 big = g1 - gasleft();

        assertGt(big, small + 500, "expansion must grow with words");
        emit log_named_uint("expand 16 words (approx)", small);
        emit log_named_uint("expand 512 words (approx)", big);
    }
}
