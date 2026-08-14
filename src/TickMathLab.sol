// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Ch 19 tick math lab
/// @notice A faithful pure-Solidity port of Uniswap v3-core `TickMath.sol`:
///         fixed-point conversions between a tick index (price = 1.0001^tick)
///         and the Q64.96 `sqrtPriceX96 = sqrt(price) · 2^96` representation.
/// @dev LAB ONLY, NOT protocol. The assembly in the original is replaced with
///      Solidity shifts so the algorithm is legible; every constant is
///      byte-for-byte from v3-core (0xfe5dee046a99a2a811c461f1969c3053 at bit
///      0x80 is the easy one to get wrong). Round-trip correctness is pinned by
///      fuzz tests. Q64.96: 96 fractional bits (Ch 4 fixed-point tie-in);
///      prices span [2^-128, 2^128], so sqrtPriceX96 spans [2^32, 2^160).
library TickMathLab {
    /// @dev The minimum tick, from log base 1.0001 of 2^-128.
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick, from log base 1.0001 of 2^128.
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev The minimum value getSqrtRatioAtTick returns: getSqrtRatioAtTick(MIN_TICK) = 2^32.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value getSqrtRatioAtTick returns: getSqrtRatioAtTick(MAX_TICK) = 2^160.
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @dev Reverts when |tick| exceeds MAX_TICK (the v3-core 'T' require).
    error InvalidTick(int24 tick);
    /// @dev Reverts when sqrtPriceX96 is outside [MIN_SQRT_RATIO, MAX_SQRT_RATIO)
    ///      (the v3-core 'R' require; the max is exclusive by design).
    error InvalidSqrtRatio(uint160 sqrtPriceX96);

    /// @notice Computes sqrt(1.0001^tick) · 2^96 as a Q64.96 fixed point.
    /// @dev Faithful port: binary decomposition of 1.0001^absTick into the
    ///      precomputed constants 1.0001^(2^k) in Q128, then scale Q128→Q96
    ///      rounding UP so getTickAtSqrtRatio(getSqrtRatioAtTick(t)) == t always.
    /// @param tick The tick index (price = 1.0001^tick).
    /// @return sqrtPriceX96 The Q64.96 sqrt price.
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert InvalidTick(tick);

            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001 // 1.0001^1
                : 0x100000000000000000000000000000000; // 1.0
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Scale Q128 → Q96 rounding up, so the inverse conversion is exact.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @notice Computes the greatest tick with getSqrtRatioAtTick(tick) <= sqrtPriceX96.
    /// @dev Faithful port of the v3-core log2-with-14-fractional-bits algorithm.
    /// @param sqrtPriceX96 The Q64.96 sqrt price.
    /// @return tick The greatest tick whose ratio does not exceed the input.
    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        unchecked {
            if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 >= MAX_SQRT_RATIO) {
                revert InvalidSqrtRatio(sqrtPriceX96);
            }
            uint256 ratio = uint256(sqrtPriceX96) << 32; // Q128

            // Find the position of the most significant set bit of `ratio`.
            uint256 r = ratio;
            uint256 msb = 0;
            if (r > 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) {
                r >>= 128;
                msb += 128;
            }
            if (r > 0xFFFFFFFFFFFFFFFF) {
                r >>= 64;
                msb += 64;
            }
            if (r > 0xFFFFFFFF) {
                r >>= 32;
                msb += 32;
            }
            if (r > 0xFFFF) {
                r >>= 16;
                msb += 16;
            }
            if (r > 0xFF) {
                r >>= 8;
                msb += 8;
            }
            if (r > 0xF) {
                r >>= 4;
                msb += 4;
            }
            if (r > 0x3) {
                r >>= 2;
                msb += 2;
            }
            if (r > 0x1) {
                r >>= 1;
                msb += 1;
            }

            // Normalize ratio into [2^127, 2^128) so the fractional loop below
            // extracts log2 bits one at a time.
            if (msb >= 128) r = ratio >> (msb - 127);
            else r = ratio << (127 - msb);

            int256 log2 = (int256(msb) - 128) << 64;

            // 14 extra bits of log2 precision (bit 63 down to bit 50).
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 63);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 62);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 61);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 60);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 59);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 58);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 57);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 56);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 55);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 54);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 53);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 52);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 51);
                r >>= f;
            }
            r = (r * r) >> 127;
            {
                uint256 f = r >> 128;
                log2 |= int256(f << 50);
            }

            // log2 is now log2(sqrt(price))·2^64. Convert to tick:
            // tick = 2·log2(sqrt(price))/log2(1.0001), scaled by 2^128.
            int256 logSqrt10001 = log2 * 255738958999603826347141; // Q128.128 number

            int24 tickLow = int24((logSqrt10001 - 3402992956809132418596140100660247210) >> 128);
            int24 tickHi = int24((logSqrt10001 + 291339464771989622907027621153398088495) >> 128);

            tick = tickLow == tickHi ? tickLow : getSqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
        }
    }
}
