// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IArithProbe} from "./IArithProbe.sol";

/// @title ArithProbe
/// @notice Ch 4 lab — integer arithmetic & units: checked/unchecked semantics,
///         rounding direction, full-precision mulDiv, WAD/RAY fixed point,
///         per-second accrual. Lab ONLY, not protocol.
/// @dev RECONSTRUCTED 2026-08-14 from the Ch 4 chapter spec + ledger (the
///      VPS-era original, commit 11fd311, was lost with the decommissioned
///      host). The mulDiv implementation follows the OZ v5 Math algorithm
///      shape (512-bit product, quotient-overflow check, Newton inverse) with
///      the lab's own parameterized error; gas numbers re-pinned in the test.
///      Convention note: the interface functions are `public` here — the
///      original bit on `external` (Error 7576, Ch 4 Common Mistakes #1).
contract ArithProbe is IArithProbe {
    uint256 public constant override WAD = 1e18;
    uint256 public constant override RAY = 1e27;

    /// @dev Panic 0x11 (arithmetic) and Panic 0x12 (division by zero) selectors
    ///      — 0x4e487b71 followed by the uint256 code.
    uint256 internal constant PANIC_ARITHMETIC = 0x11;
    uint256 internal constant PANIC_DIVISION_BY_ZERO = 0x12;

    // ── checked vs unchecked ─────────────────────────────────────────────────

    /// @inheritdoc IArithProbe
    function checkedSum(uint256[] calldata xs) public pure returns (uint256 s) {
        for (uint256 i; i < xs.length; ++i) {
            s += xs[i]; // checked: Panic 0x11 on overflow
        }
    }

    /// @inheritdoc IArithProbe
    function uncheckedSum(uint256[] calldata xs) public pure returns (uint256 s) {
        unchecked {
            for (uint256 i; i < xs.length; ++i) {
                s += xs[i]; // wraps mod 2^256 — the 2018 batchOverflow class
            }
        }
    }

    // ── rounding ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArithProbe
    function ceilDiv(uint256 a, uint256 b) public pure returns (uint256) {
        if (b == 0) return a / b; // Panic 0x12, preserved deliberately (incl. 0/0)
        // Overflow-safe form: (a+b-1)/b wraps for a+b-1 ≥ 2^256; this does not.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ── mulDiv ───────────────────────────────────────────────────────────────

    /// @inheritdoc IArithProbe
    function mulDiv(uint256 a, uint256 b, uint256 denominator)
        public
        pure
        returns (uint256 result)
    {
        if (denominator == 0) _panic(PANIC_DIVISION_BY_ZERO);
        unchecked {
            // 512-bit product [prod1 prod0] = a · b
            uint256 prod0 = a * b;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            // Fast path: product fits in 256 bits → single division.
            if (prod1 == 0) return prod0 / denominator;
            // Quotient-overflow check: quotient ≥ 2^256 not representable.
            if (denominator <= prod1) revert MulDivOverflow(a, b, denominator);

            // 512-by-256 division with remainder.
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            // Factor powers of two out of denominator (binary gcd step).
            uint256 twos = denominator & (0 - denominator);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Newton inverse of denominator mod 2^256: seed correct mod 2^4,
            // each iteration doubles the correct bits — SIX iterations reach
            // 2^256 (4 → 8 → 16 → 32 → 64 → 128 → 256).
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse; // mod 2^8
            inverse *= 2 - denominator * inverse; // mod 2^16
            inverse *= 2 - denominator * inverse; // mod 2^32
            inverse *= 2 - denominator * inverse; // mod 2^64
            inverse *= 2 - denominator * inverse; // mod 2^128
            inverse *= 2 - denominator * inverse; // mod 2^256

            // 512-bit result = prod0 · inverse, divided by 2^256.
            result = prod0 * inverse;
        }
    }

    /// @inheritdoc IArithProbe
    function mulDivNaive(uint256 a, uint256 b, uint256 denominator) public pure returns (uint256) {
        // Checked (a·b)/c — the phantom-overflow trap.
        return (a * b) / denominator;
    }

    // ── WAD/RAY scaling ──────────────────────────────────────────────────────

    /// @inheritdoc IArithProbe
    function toWad(uint256 amount, uint8 decimals) public pure returns (uint256) {
        if (decimals > 18) revert DecimalsAbove18(decimals);
        return amount * 10 ** (18 - decimals);
    }

    /// @inheritdoc IArithProbe
    function fromWad(uint256 amount, uint8 decimals) public pure returns (uint256) {
        if (decimals > 18) revert DecimalsAbove18(decimals);
        return amount / 10 ** (18 - decimals);
    }

    // ── per-second accrual (locked: linear + r²/2 borrower-favorable bias) ───

    /// @inheritdoc IArithProbe
    function accrueLinear(uint256 ratePerSecond, uint256 secondsElapsed)
        public
        pure
        returns (uint256)
    {
        return mulDiv(ratePerSecond, secondsElapsed, 1);
    }

    /// @inheritdoc IArithProbe
    function accrueQuadratic(uint256 ratePerSecond, uint256 secondsElapsed)
        public
        pure
        returns (uint256)
    {
        uint256 rt = accrueLinear(ratePerSecond, secondsElapsed);
        // (r·t)² / (2·RAY) — RAY-scaled quadratic term.
        return mulDiv(rt, rt, 2 * RAY);
    }

    /// @inheritdoc IArithProbe
    function accrue(uint256 ratePerSecond, uint256 secondsElapsed) public pure returns (uint256) {
        return accrueLinear(ratePerSecond, secondsElapsed)
            + accrueQuadratic(ratePerSecond, secondsElapsed);
    }

    // ── internals ────────────────────────────────────────────────────────────

    /// @dev Revert with the standard Solidity panic selector (0x4e487b71, code).
    function _panic(uint256 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, 0x4e487b7100000000000000000000000000000000000000000000000000000000)
            mstore(0x04, code)
            revert(0x00, 0x24)
        }
    }
}
