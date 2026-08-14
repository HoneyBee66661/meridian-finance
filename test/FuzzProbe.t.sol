// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {FuzzProbe} from "../src/FuzzProbe.sol";

/// @notice Ch 12 fuzz lab — single-call properties over sampled inputs.
/// @dev Methodology (locked Ch 10/12): `bound` for ranges, `vm.assume` only
///      for logical preconditions; no gas assertions in fuzz code (Ch 8);
///      deterministic under a pinned `[fuzz] seed` (Ch 12: CI pins the seed).
contract FuzzProbeTest is Test {
    FuzzProbe internal probe;

    function setUp() public {
        probe = new FuzzProbe();
    }

    /// @dev Floor correctness: mulDivFloor is the largest q with q*d <= a*b.
    ///      Domain bounded to [0, 2^128) so a*b never overflows checked math;
    ///      full-precision mulDiv (OZ Math, Ch 4/20) is the production answer.
    function testFuzz_mulDiv_floorCorrect(uint256 a, uint256 b, uint256 d) public {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);
        d = bound(d, 1, type(uint128).max); // bound excludes 0 — no assume needed
        uint256 q = probe.mulDivFloor(a, b, d);
        assertLe(q * d, a * b);
        assertGt((q + 1) * d, a * b);
    }

    /// @dev The overflow surface: naive a*b/d overflows where full precision
    ///      would not — pinned as the Panic 0x11 revert (Ch 4 batchOverflow
    ///      class), the reason production uses mulDiv.
    function test_mulDiv_naiveOverflows() public {
        vm.expectRevert(stdError.arithmeticError);
        probe.mulDivFloor(type(uint256).max, type(uint256).max, 1);
    }

    /// @dev Checked sum reverts EXACTLY where the unchecked sum wraps: no third
    ///      outcome. The property pins checked-vs-unchecked semantics (Ch 4).
    function testFuzz_sum_checkedRevertsExactlyOnOverflow(uint256[] calldata xs) public {
        uint256 uncheckedSum = probe.sumUnchecked(xs);
        try probe.sumChecked(xs) returns (uint256 checkedSum) {
            assertEq(checkedSum, uncheckedSum);
        } catch (bytes memory err) {
            assertEq(err, stdError.arithmeticError);
        }
    }

    /// @dev Narrowing cast truncates the low bits: uint8(x) == x % 256.
    function testFuzz_toUint8_truncation(uint256 x) public {
        assertEq(uint256(probe.toUint8(x)), x % 256);
    }

    /// @dev `bound` semantics: deterministic fold into [min, max], no rejects.
    function testFuzz_bound_keepsDomain(uint256 x) public {
        uint256 y = bound(x, 100, 200);
        assertGe(y, 100);
        assertLe(y, 200);
    }
}
