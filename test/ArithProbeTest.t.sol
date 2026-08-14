// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol"; // explicit import — Test does not re-export it (Ch 16 finding)
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IArithProbe} from "../src/IArithProbe.sol";
import {ArithProbe} from "../src/ArithProbe.sol";

/// @dev Wraps the OZ v5 Math.mulDiv as an external call so the fuzz can compare
///      the lab implementation against the reference library (internal-library
///      calls are inlined and cannot be try/catch'd).
contract OZMathHarness {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return Math.mulDiv(a, b, denominator);
    }
}

/// @notice Ch 4 lab tests — integer arithmetic & units. RECONSTRUCTED 2026-08-14
///         from the chapter spec + ledger (VPS-era original commit 11fd311 lost).
///         Methodology per locked conventions: parameter-exact vm.expectRevert,
///         bound over vm.assume, warm-up before gasleft() deltas, gas probes
///         asserted as inequalities + logged (--gas-report distorts gasleft()).
contract ArithProbeTest is Test {
    ArithProbe internal probe;
    OZMathHarness internal oz;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    function setUp() public {
        probe = new ArithProbe();
        oz = new OZMathHarness();
    }

    // ── checked vs unchecked ─────────────────────────────────────────────────

    function test_checkedSum_overflow_revertsPanic0x11() public {
        uint256[] memory xs = new uint256[](2);
        xs[0] = type(uint256).max;
        xs[1] = 1;
        vm.expectRevert(stdError.arithmeticError); // Panic 0x11
        probe.checkedSum(xs);
    }

    function test_uncheckedSum_wraps_maxPlusOne() public {
        uint256[] memory xs = new uint256[](2);
        xs[0] = type(uint256).max;
        xs[1] = 1;
        assertEq(probe.uncheckedSum(xs), 0); // wraps mod 2^256 — batchOverflow class
    }

    function testFuzz_checkedMatchesUnchecked_whenNoOverflow(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) public {
        uint256 cap = type(uint256).max / 4;
        a = bound(a, 0, cap);
        b = bound(b, 0, cap);
        c = bound(c, 0, cap);
        d = bound(d, 0, cap);
        uint256[] memory xs = new uint256[](4);
        xs[0] = a;
        xs[1] = b;
        xs[2] = c;
        xs[3] = d;
        assertEq(probe.checkedSum(xs), probe.uncheckedSum(xs)); // sum ≤ max, no divergence
    }

    // ── rounding ─────────────────────────────────────────────────────────────

    function test_ceilDiv_basics() public {
        assertEq(probe.ceilDiv(5, 2), 3);
        assertEq(probe.ceilDiv(4, 2), 2);
        assertEq(probe.ceilDiv(7, 3), 3);
        assertEq(probe.ceilDiv(1, 1), 1);
        assertEq(probe.ceilDiv(0, 5), 0);
        assertEq(probe.ceilDiv(2, 3), 1);
    }

    function test_ceilDiv_maxValue_noOverflow() public {
        // (a + b - 1)/b would wrap for a = max; (a - 1)/b + 1 does not.
        assertEq(probe.ceilDiv(type(uint256).max, 1), type(uint256).max);
        assertEq(probe.ceilDiv(type(uint256).max - 1, 2), (type(uint256).max - 2) / 2 + 1);
        assertEq(probe.ceilDiv(type(uint256).max, type(uint256).max), 1);
    }

    function test_ceilDiv_divByZero_panics0x12() public {
        vm.expectRevert(stdError.divisionError); // Panic 0x12
        probe.ceilDiv(5, 0);
    }

    function test_ceilDiv_zeroOverZero_panics0x12() public {
        // 0/0 must NOT silently return 0 — the b == 0 guard fires first.
        vm.expectRevert(stdError.divisionError);
        probe.ceilDiv(0, 0);
    }

    function testFuzz_ceilDiv_identity(uint256 a, uint256 b) public {
        b = bound(b, 1, type(uint256).max);
        uint256 expected = a == 0 ? 0 : (a - 1) / b + 1;
        assertEq(probe.ceilDiv(a, b), expected);
    }

    // ── mulDiv ───────────────────────────────────────────────────────────────

    function test_mulDiv_phantomOverflow_handles() public {
        // a·b = 2^260 (overflows uint256), quotient 2^196 — representable.
        assertEq(probe.mulDiv(2 ** 130, 2 ** 130, 2 ** 64), 2 ** 196);
    }

    function test_mulDivNaive_phantomOverflow_reverts() public {
        vm.expectRevert(stdError.arithmeticError); // naive (a·b)/c reverts — the trap
        probe.mulDivNaive(2 ** 130, 2 ** 130, 2 ** 64);
    }

    function test_mulDiv_exactDivision() public {
        assertEq(probe.mulDiv(6, 7, 2), 21);
        assertEq(probe.mulDiv(2 ** 100, 2 ** 100, 2 ** 50), 2 ** 150);
        assertEq(probe.mulDiv(1e18, 1e18, 1e18), 1e18); // WAD·WAD / WAD
    }

    function test_mulDiv_floors() public {
        assertEq(probe.mulDiv(7, 7, 3), 16); // 49/3 = 16.33 → 16 (floor)
        assertEq(probe.mulDiv(5, 5, 2), 12); // 25/2 = 12.5 → 12
        assertEq(probe.mulDiv(1, 1, 3), 0);
    }

    function test_mulDiv_quotientOverflow_revertsCustomError() public {
        // quotient = 2^260 ≥ 2^256 — not representable.
        vm.expectRevert(
            abi.encodeWithSelector(IArithProbe.MulDivOverflow.selector, 2 ** 130, 2 ** 130, 1)
        );
        probe.mulDiv(2 ** 130, 2 ** 130, 1);
    }

    function test_mulDiv_knownVectors_slowPath() public {
        // (2^256-1)·(2^256-1)/ (2^256-1) = 2^256-1 — exercises the 512-bit path.
        assertEq(
            probe.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max
        );
        assertEq(probe.mulDiv(type(uint256).max, 1, type(uint256).max), 1);
        // 2^128·2^128/2^128 = 2^128 — 512-bit product, exact slow-path result.
        assertEq(probe.mulDiv(2 ** 128, 2 ** 128, 2 ** 128), 2 ** 128);
        // 2^192·2^192/(2^256−1) = 2^128 — quotient fits, product does not.
        assertEq(probe.mulDiv(2 ** 192, 2 ** 192, type(uint256).max), 2 ** 128);
    }

    function testFuzz_mulDiv_agreesWithNaive(uint256 a, uint256 b, uint256 d) public {
        a = bound(a, 0, 2 ** 127 - 1);
        b = bound(b, 0, 2 ** 127 - 1); // product ≤ 2^254 fits
        d = bound(d, 1, type(uint256).max);
        assertEq(probe.mulDiv(a, b, d), (a * b) / d);
    }

    function testFuzz_mulDiv_floorIdentity(uint256 a, uint256 b, uint256 d) public {
        a = bound(a, 0, 2 ** 127 - 1);
        b = bound(b, 0, 2 ** 127 - 1);
        d = bound(d, 1, type(uint256).max);
        uint256 q = probe.mulDiv(a, b, d);
        // q·d ≤ a·b < (q+1)·d — the floor sandwich, on the fitting domain.
        assertLe(q * d, a * b);
        assertGt((q + 1) * d, a * b);
        // And q·d + (a·b mod d) == a·b.
        assertEq(q * d + (a * b) % d, a * b);
    }

    function testFuzz_mulDiv_matchesOZReference(uint256 a, uint256 b, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        try oz.mulDiv(a, b, d) returns (uint256 expected) {
            assertEq(probe.mulDiv(a, b, d), expected); // full-range agreement
        } catch {
            // OZ reverts MathOverflowedMulDiv ⇔ quotient ≥ 2^256; the lab must
            // revert its own parameterized MulDivOverflow on the SAME inputs.
            vm.expectRevert(abi.encodeWithSelector(IArithProbe.MulDivOverflow.selector, a, b, d));
            probe.mulDiv(a, b, d);
        }
    }

    // ── WAD/RAY scaling ──────────────────────────────────────────────────────

    function test_wad_scaling() public {
        assertEq(probe.toWad(1, 6), 1e12); // 1 USDC raw unit → 1e12 WAD
        assertEq(probe.toWad(123, 18), 123); // 18dp: no scaling
        assertEq(probe.fromWad(1e12, 6), 1); // 1e12 WAD → 1 USDC raw unit
        assertEq(probe.fromWad(1e18, 6), 1e6); // 1 full token WAD → 1e6 USDC raw units
        assertEq(probe.fromWad(1e18, 18), 1e18); // 18dp: no scaling
    }

    function test_wad_truncation() public {
        // fromWad floors (user-received direction, locked rounding policy).
        assertEq(probe.fromWad(1e12 + 99, 6), 1);
        assertEq(probe.fromWad(0, 6), 0);
        assertEq(probe.toWad(0, 6), 0);
    }

    function testFuzz_wad_equalsMulDiv(uint256 x, uint8 decimals) public {
        decimals = uint8(bound(decimals, 0, 18));
        x = bound(x, 0, type(uint256).max / 10 ** 18); // keep x·10^18 in range
        assertEq(probe.toWad(x, decimals), x * 10 ** (18 - decimals));
    }

    // ── decimals ─────────────────────────────────────────────────────────────

    function test_decimals_above18_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IArithProbe.DecimalsAbove18.selector, 19));
        probe.toWad(1, 19);
        vm.expectRevert(abi.encodeWithSelector(IArithProbe.DecimalsAbove18.selector, 24));
        probe.fromWad(1, 24);
    }

    function test_decimals_roundTrip_exact() public {
        // toWad multiplies exactly, so the round trip is lossless.
        assertEq(probe.fromWad(probe.toWad(123_456, 6), 6), 123_456);
        assertEq(probe.fromWad(probe.toWad(7, 0), 0), 7);
    }

    function testFuzz_decimals_roundTrip(uint256 x, uint8 decimals) public {
        x = bound(x, 0, 2 ** 100);
        decimals = uint8(bound(decimals, 0, 18));
        assertEq(probe.fromWad(probe.toWad(x, decimals), decimals), x);
    }

    // ── rates (per-second linear + r²/2 borrower-favorable bias) ─────────────

    function test_rates_zeroRate_isZero() public {
        assertEq(probe.accrue(0, SECONDS_PER_YEAR), 0);
        assertEq(probe.accrueQuadratic(0, 1e12), 0);
    }

    function test_rates_perSecondConversion() public {
        // 5% annual in RAY → per-second rate (floor), and the flooring error
        // over one year is < one second's accrual (a RAY-second).
        uint256 annual = (5 * RAY) / 100;
        uint256 perSecond = annual / SECONDS_PER_YEAR;
        uint256 oneYear = probe.accrueLinear(perSecond, SECONDS_PER_YEAR);
        assertLe(annual - oneYear, perSecond); // truncation < 1 second of rate
        assertEq(perSecond * SECONDS_PER_YEAR + (annual % SECONDS_PER_YEAR), annual);
    }

    function test_rates_oneYear_biasTermPinned() public {
        // accrue = linear + floor((linear)²/2RAY): the one-year result differs
        // from nominal by exactly the r²/2 correction term (borrower-favorable).
        uint256 annual = (5 * RAY) / 100;
        uint256 perSecond = annual / SECONDS_PER_YEAR;
        uint256 linear = probe.accrueLinear(perSecond, SECONDS_PER_YEAR);
        uint256 total = probe.accrue(perSecond, SECONDS_PER_YEAR);
        uint256 bias = probe.accrueQuadratic(perSecond, SECONDS_PER_YEAR);
        assertEq(bias, probe.mulDiv(linear, linear, 2 * RAY));
        assertEq(total, linear + bias);
        assertGt(total, linear); // borrower-favorable: bias is strictly positive
    }

    function testFuzz_rates_nonDecreasing(uint256 r, uint256 t1, uint256 t2) public {
        r = bound(r, 0, RAY); // ≤ 100% per second — sane domain
        t1 = bound(t1, 0, SECONDS_PER_YEAR);
        t2 = bound(t2, 0, SECONDS_PER_YEAR);
        if (t1 <= t2) {
            assertLe(probe.accrue(r, t1), probe.accrue(r, t2));
        } else {
            assertLe(probe.accrue(r, t2), probe.accrue(r, t1));
        }
    }

    // ── gas (min-delta, warm-up first, asserted as inequalities + logged) ────

    function test_gas_checkedVsUnchecked() public {
        uint256[] memory xs = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            xs[i] = 1;
        }
        probe.checkedSum(xs); // warm-up (cold code load)
        probe.uncheckedSum(xs);
        uint256 checked = _measureChecked(xs);
        uint256 uncheckedGas = _measureUnchecked(xs);
        emit log_named_uint("checkedSum gas (20 calls, min-of-3)", checked);
        emit log_named_uint("uncheckedSum gas (20 calls, min-of-3)", uncheckedGas);
        assertGt(checked, uncheckedGas); // the overflow branch costs ~63 gas/element
    }

    function test_gas_mulDiv_fastVsSlow() public {
        // Fast path: product fits (2^254). Slow path: product 2^260.
        uint256 aF = 2 ** 127;
        uint256 bF = 2 ** 127;
        uint256 dF = 2 ** 64;
        uint256 aS = 2 ** 130;
        uint256 bS = 2 ** 130;
        uint256 dS = 2 ** 64;
        probe.mulDiv(aF, bF, dF); // warm-up both paths
        probe.mulDiv(aS, bS, dS);
        uint256 fast = _measureMulDiv(aF, bF, dF);
        uint256 slow = _measureMulDiv(aS, bS, dS);
        emit log_named_uint("mulDiv fast-path gas (100 calls, min-of-3)", fast);
        emit log_named_uint("mulDiv slow-path gas (100 calls, min-of-3)", slow);
        assertLt(fast, slow); // single DIV beats the Newton-inverse machinery
    }

    function test_gas_mulDiv_naiveVsFull() public {
        uint256 a = 2 ** 127 - 1;
        uint256 b = 2 ** 127 - 1;
        uint256 d = 2 ** 64;
        probe.mulDiv(a, b, d); // warm-up
        probe.mulDivNaive(a, b, d);
        uint256 naive = _measureNaive(a, b, d);
        uint256 full = _measureMulDiv(a, b, d);
        emit log_named_uint("mulDivNaive gas (100 calls, min-of-3)", naive);
        emit log_named_uint("mulDiv full gas (100 calls, min-of-3)", full);
        // The prod1 == 0 fast path makes full ≈ naive on the fitting domain —
        // that IS the design (you never pay for the 512-bit machinery when the
        // product fits). Assert full is not meaningfully more expensive.
        assertLe(full, naive + 100);
    }

    // ── measurement helpers ──────────────────────────────────────────────────

    function _measureChecked(uint256[] memory xs) internal returns (uint256 best) {
        best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 20; ++i) {
                probe.checkedSum(xs);
            }
            uint256 avg = (start - gasleft()) / 20;
            if (avg < best) best = avg;
        }
    }

    function _measureUnchecked(uint256[] memory xs) internal returns (uint256 best) {
        best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 20; ++i) {
                probe.uncheckedSum(xs);
            }
            uint256 avg = (start - gasleft()) / 20;
            if (avg < best) best = avg;
        }
    }

    function _measureMulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256 best) {
        best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 100; ++i) {
                probe.mulDiv(a, b, d);
            }
            uint256 avg = (start - gasleft()) / 100;
            if (avg < best) best = avg;
        }
    }

    function _measureNaive(uint256 a, uint256 b, uint256 d) internal returns (uint256 best) {
        best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 100; ++i) {
                probe.mulDivNaive(a, b, d);
            }
            uint256 avg = (start - gasleft()) / 100;
            if (avg < best) best = avg;
        }
    }
}
