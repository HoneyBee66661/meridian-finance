// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMathLab} from "../src/TickMathLab.sol";

/// @dev Internal-library calls are inlined into the caller's frame, so their
///      reverts cannot be caught by `vm.expectRevert` (which watches the next
///      EXTERNAL call). The harness exposes the two functions externally so the
///      revert surface is testable (standard Foundry harness pattern).
contract TickMathLabHarness {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return TickMathLab.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) external pure returns (int24) {
        return TickMathLab.getTickAtSqrtRatio(sqrtPriceX96);
    }
}

/// @notice Ch 19 tick-math tests — the tick ↔ sqrtPriceX96 conversions that
///         underlie all of concentrated liquidity. Pins the fixed-point
///         boundaries, the round-trip identities (bound over vm.assume), the
///         monotonicity of the price curve, and the price↔tick relationship for
///         a real-world price (2,000).
/// @dev Methodology per locked conventions: `bound` over `vm.assume`;
///      parameter-exact vm.expectRevert; warm-up calls before gasleft() deltas;
///      gas probes log-only. Q64.96: sqrtPriceX96 = sqrt(P) · 2^96, so
///      P ∈ [2^-128, 2^128] maps to sqrtPriceX96 ∈ [2^32, 2^160).
contract TickMathLabTest is Test {
    using Math for uint256;

    uint256 internal constant Q96 = 79228162514264337593543950336; // 2^96
    uint256 internal constant Q192 = 6277101735386680763835789423207666416102355444464034512896; // 2^192

    // ── pinned boundary values ───────────────────────────────────────────────

    /// @dev tick 0 → price 1 → sqrtPriceX96 = 2^96 exactly.
    function test_tickMath_pinned_tickZero_isOnePrice() public {
        assertEq(TickMathLab.getSqrtRatioAtTick(0), Q96);
    }

    /// @dev getSqrtRatioAtTick(±MAX_TICK) hits the documented boundaries:
    ///      MIN_SQRT_RATIO = 4295128739 (the real v3-core constant, 2^32 + 161,443
    ///      — NOT 2^32), MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342.
    function test_tickMath_pinned_extremes() public {
        assertEq(TickMathLab.getSqrtRatioAtTick(TickMathLab.MIN_TICK), TickMathLab.MIN_SQRT_RATIO);
        assertEq(TickMathLab.getSqrtRatioAtTick(TickMathLab.MAX_TICK), TickMathLab.MAX_SQRT_RATIO);
        assertEq(TickMathLab.MIN_SQRT_RATIO, 4_295_128_739); // 2^32 + 161,443
    }

    /// @dev Inverse at the natural mid-point: getTickAtSqrtRatio(2^96) == 0.
    function test_tickMath_pinned_midpoint_tickIsZero() public {
        assertEq(TickMathLab.getTickAtSqrtRatio(uint160(Q96)), 0);
    }

    /// @dev A real-world price: P = 2,000 → tick = floor(log_1.0001(2000)) ≈ 76,012
    ///      (ln 2000 / ln 1.0001 ≈ 76012.8). getTickAtSqrtRatio(sqrt(2000)·2^96)
    ///      must land in {76012, 76013}.
    function test_tickMath_pinned_price2000() public {
        uint160 sqrtP = uint160(Math.sqrt(2_000 * Q192)); // sqrt(2000)·2^96, floored
        int24 t = TickMathLab.getTickAtSqrtRatio(sqrtP);
        assertGe(t, 76_012);
        assertLe(t, 76_013);
        // And the ratio at that tick brackets sqrtP (prices are quantized to
        // ticks — sub-tick precision is not representable): ratio(t) <= sqrtP
        // < ratio(t+1), i.e. t is the greatest tick whose price is <= 2,000.
        uint256 ratioLow = TickMathLab.getSqrtRatioAtTick(t);
        uint256 ratioHigh = TickMathLab.getSqrtRatioAtTick(t + 1);
        assertGe(sqrtP, ratioLow);
        assertLt(sqrtP, ratioHigh);
    }

    // ── round trips (fuzz, bound over vm.assume) ─────────────────────────────

    /// @dev tick → ratio → tick is EXACT for every in-range tick (the Q128→Q96
    ///      conversion rounds up precisely so the inverse is lossless). The max
    ///      tick is excluded: getSqrtRatioAtTick(MAX_TICK) = MAX_SQRT_RATIO, and
    ///      the ratio's upper bound is exclusive by design (v3-core 'R'), so the
    ///      round-trip identity holds on [MIN_TICK, MAX_TICK − 1).
    function testFuzz_tickMath_sqrtRatioAtTick_roundTrip(int24 tick) public {
        tick = int24(bound(tick, TickMathLab.MIN_TICK, TickMathLab.MAX_TICK - 1));
        assertEq(TickMathLab.getTickAtSqrtRatio(TickMathLab.getSqrtRatioAtTick(tick)), tick);
    }

    /// @dev ratio → tick → ratio: getTickAtSqrtRatio returns the greatest tick
    ///      with ratio(t) <= p, so p must lie in [ratio(t), ratio(t+1)).
    function testFuzz_tickMath_getTickAtSqrtRatio_roundTrip(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(
            bound(sqrtPriceX96, TickMathLab.MIN_SQRT_RATIO, TickMathLab.MAX_SQRT_RATIO - 1)
        );
        int24 t = TickMathLab.getTickAtSqrtRatio(sqrtPriceX96);
        uint160 ratioT = TickMathLab.getSqrtRatioAtTick(t);
        uint160 ratioNext = TickMathLab.getSqrtRatioAtTick(t + 1);
        assertGe(sqrtPriceX96, ratioT);
        assertLt(sqrtPriceX96, ratioNext);
    }

    /// @dev The price curve is strictly monotonic in the tick: a larger tick
    ///      always means a larger price.
    function testFuzz_tickMath_monotonic(int24 tickA, int24 tickB) public {
        tickA = int24(bound(tickA, TickMathLab.MIN_TICK, TickMathLab.MAX_TICK - 1));
        tickB = int24(bound(tickB, tickA + 1, TickMathLab.MAX_TICK));
        assertLt(TickMathLab.getSqrtRatioAtTick(tickA), TickMathLab.getSqrtRatioAtTick(tickB));
    }

    /// @dev Negative ticks invert: ratio(t)·ratio(−t) = 2^192 in exact arithmetic
    ///      (sqrt(P)·sqrt(1/P) = 1), but each ratio is a floored/rounded Q96
    ///      integer, so the product is off by at most ~up+down wei — which grows
    ///      with sqrt(P): ~2^97 at small ticks, ~2^160 near MAX_TICK. The honest
    ///      bound is the sum of the two ratios (+2 for rounding-up edges), not a
    ///      fixed wei tolerance.
    function testFuzz_tickMath_reciprocal(int24 tick) public {
        tick = int24(bound(tick, 1, TickMathLab.MAX_TICK - 1));
        uint256 up = TickMathLab.getSqrtRatioAtTick(tick);
        uint256 down = TickMathLab.getSqrtRatioAtTick(-tick);
        uint256 product = up * down; // ratio(t)·ratio(−t) ≈ 2^192 (< 2^256, safe)
        uint256 diff = product <= Q192 ? Q192 - product : product - Q192;
        assertLe(diff, up + down + 2);
    }

    // ── revert surface (through the harness: internal-library reverts are
    //    inlined into the caller's frame, invisible to vm.expectRevert) ────────

    TickMathLabHarness internal harness;

    function setUp() public {
        harness = new TickMathLabHarness();
    }

    function test_tickMath_reverts_aboveMaxTick() public {
        vm.expectRevert(
            abi.encodeWithSelector(TickMathLab.InvalidTick.selector, TickMathLab.MAX_TICK + 1)
        );
        harness.getSqrtRatioAtTick(TickMathLab.MAX_TICK + 1);
    }

    function test_tickMath_reverts_belowMinTick() public {
        vm.expectRevert(
            abi.encodeWithSelector(TickMathLab.InvalidTick.selector, TickMathLab.MIN_TICK - 1)
        );
        harness.getSqrtRatioAtTick(TickMathLab.MIN_TICK - 1);
    }

    function test_tickMath_reverts_ratioBelowMin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                TickMathLab.InvalidSqrtRatio.selector, TickMathLab.MIN_SQRT_RATIO - 1
            )
        );
        harness.getTickAtSqrtRatio(TickMathLab.MIN_SQRT_RATIO - 1);
    }

    /// @dev The max ratio is EXCLUSIVE: the price can never reach the max tick's
    ///      ratio (that would be 2^128 exactly).
    function test_tickMath_reverts_ratioAtOrAboveMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                TickMathLab.InvalidSqrtRatio.selector, TickMathLab.MAX_SQRT_RATIO
            )
        );
        harness.getTickAtSqrtRatio(TickMathLab.MAX_SQRT_RATIO);
    }

    // ── gas probes (log-only, warm-up first) ─────────────────────────────────

    function test_gas_getSqrtRatioAtTick() public {
        TickMathLab.getSqrtRatioAtTick(76_010); // warm-up (cold code load)
        uint256 best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 100; ++i) {
                TickMathLab.getSqrtRatioAtTick(int24(int256(i)) - 50);
            }
            uint256 avg = (start - gasleft()) / 100;
            if (avg < best) best = avg;
        }
        console2.log("getSqrtRatioAtTick gas (100 calls, min-of-3):", best);
    }

    function test_gas_getTickAtSqrtRatio() public {
        TickMathLab.getTickAtSqrtRatio(uint160(Q96));
        uint256 best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 100; ++i) {
                TickMathLab.getTickAtSqrtRatio(uint160(Q96 + i));
            }
            uint256 avg = (start - gasleft()) / 100;
            if (avg < best) best = avg;
        }
        console2.log("getTickAtSqrtRatio gas (100 calls, min-of-3):", best);
    }
}
