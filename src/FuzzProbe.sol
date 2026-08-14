// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Ch 12 lab — pure functions with classic bug classes, fuzz targets.
///         LAB ONLY, NOT protocol.
/// @dev Properties under test (see FuzzProbe.t.sol):
///      - mulDivFloor: floor-correct a*b/d within the bounded domain; the
///        naive form overflows outside it (pinned by test_mulDiv_naiveOverflows
///        — the reason production code uses full-precision mulDiv, Ch 4/20).
///      - sumChecked / sumUnchecked: the overflow surface (Panic 0x11), the
///        BEC/SMT batchOverflow class (Ch 2/4).
///      - toUint8: narrowing-cast truncation (== x % 256).
contract FuzzProbe {
    error DivByZero();

    /// @notice Floor division of a*b by d. Checked: reverts Panic 0x11 when
    ///         a*b overflows — that is the property under test, not a bug here.
    function mulDivFloor(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        if (d == 0) revert DivByZero();
        return a * b / d;
    }

    /// @notice Checked accumulation: reverts Panic 0x11 exactly on overflow.
    function sumChecked(uint256[] calldata xs) external pure returns (uint256) {
        uint256 acc;
        for (uint256 i = 0; i < xs.length; i++) {
            acc += xs[i];
        }
        return acc;
    }

    /// @notice Unchecked accumulation: wraps modulo 2^256 on overflow.
    function sumUnchecked(uint256[] calldata xs) external pure returns (uint256) {
        uint256 acc;
        unchecked {
            for (uint256 i = 0; i < xs.length; i++) {
                acc += xs[i];
            }
        }
        return acc;
    }

    /// @notice Narrowing cast: truncates to the low 8 bits.
    function toUint8(uint256 x) external pure returns (uint8) {
        return uint8(x);
    }
}
