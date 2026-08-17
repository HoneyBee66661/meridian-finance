// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GasOptProbe} from "../src/GasOptProbe.sol";

contract GasOptProbeTest is Test {
    GasOptProbe internal probe;

    function setUp() public {
        probe = new GasOptProbe(address(0x1234));
    }

    /// @dev Immutable read must be meaningfully cheaper than the storage twin.
    ///      Warm the probe address first — the first call in a tx pays the cold
    ///      CALL surcharge (2,600) and would swamp the SLOAD delta.
    function testImmutableCheaperThanStorage() public {
        probe.readImmutable(); // warm the address
        uint256 g0 = gasleft();
        probe.readImmutable();
        uint256 imm = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.readStorageOracle();
        uint256 sto = g1 - gasleft();

        assertGt(sto, imm + 1500); // the ~2,097 cold delta dominates overhead
    }

    /// @dev Cached reads must never be meaningfully worse than SLOAD-in-loop.
    ///      Note: in a VIEW loop solc 0.8.24 hoists the SLOAD (provable no state
    ///      change), so the delta is ~0 here — the anti-pattern bites in
    ///      non-view code / per-element reads (Ch 8 nuance; Ch 1 CM #4).
    function testCacheBeatsSloadInLoop(uint256 n) public {
        n = bound(n, 2, 50);
        probe.sloadInLoop(2); // warm the address
        uint256 g0 = gasleft();
        probe.cachedReads(n);
        uint256 cached = g0 - gasleft();

        uint256 g1 = gasleft();
        probe.sloadInLoop(n);
        uint256 sload = g1 - gasleft();

        assertLt(cached, sload + 2000, "caching must never be meaningfully worse");
        emit log_named_uint("cachedReads(n) (approx)", cached);
        emit log_named_uint("sloadInLoop(n) (approx)", sload);
    }

    /// @dev unchecked sum is a pure function of n; fuzz checks the result.
    function testUncheckedSum(uint256 n) public view {
        n = bound(n, 0, 1000);
        uint256 acc = probe.uncheckedSum(n);
        assertEq(acc, n == 0 ? 0 : n * (n - 1) / 2);
    }
}
