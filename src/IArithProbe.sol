// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IArithProbe
/// @notice Ch 4 lab interface — integer arithmetic & units. Error catalog in
///         the interface per the locked convention (OZ v5 pattern).
/// @dev RECONSTRUCTED 2026-08-14 from the Ch 4 chapter spec + ledger (the
///      VPS-era original, commit 11fd311, was lost with the decommissioned
///      host). Surface and semantics match the documented spec; the exact
///      original implementation is not recoverable.
interface IArithProbe {
    /// @dev Full-precision quotient does not fit in uint256 (≥ 2^256).
    error MulDivOverflow(uint256 a, uint256 b, uint256 denominator);
    /// @dev toWad/fromWad only support 0–18 decimals.
    error DecimalsAbove18(uint8 decimals);

    /// @notice Checked summation — reverts Panic 0x11 on overflow.
    function checkedSum(uint256[] calldata xs) external pure returns (uint256);
    /// @notice Unchecked summation — wraps mod 2^256 (the batchOverflow class).
    function uncheckedSum(uint256[] calldata xs) external pure returns (uint256);
    /// @notice Overflow-safe ceil division: a==0 ? 0 : (a-1)/b + 1.
    ///         Preserves the Panic 0x12 on b == 0 (incl. 0/0).
    function ceilDiv(uint256 a, uint256 b) external pure returns (uint256);
    /// @notice Full-precision (a·b)/denominator, floor. Reverts MulDivOverflow
    ///         when the quotient ≥ 2^256, Panic 0x12 on denominator == 0.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256);
    /// @notice Naive (a·b)/denominator in checked context — the phantom-overflow
    ///         trap: reverts on products ≥ 2^256 even when the quotient fits.
    function mulDivNaive(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256);
    /// @notice Scale an amount to 18-decimal WAD.
    function toWad(uint256 amount, uint8 decimals) external pure returns (uint256);
    /// @notice Scale an 18-decimal WAD amount down to `decimals`.
    function fromWad(uint256 amount, uint8 decimals) external pure returns (uint256);
    /// @notice Linear per-second accrual: r·t in RAY (floor).
    function accrueLinear(uint256 ratePerSecond, uint256 secondsElapsed)
        external
        pure
        returns (uint256);
    /// @notice Quadratic bias term (r·t)²/2 — borrower-favorable compounding
    ///         correction (locked convention: per-second linear + r²/2 bias).
    function accrueQuadratic(uint256 ratePerSecond, uint256 secondsElapsed)
        external
        pure
        returns (uint256);
    /// @notice Total accrued: linear + quadratic bias.
    function accrue(uint256 ratePerSecond, uint256 secondsElapsed) external pure returns (uint256);
    /// @notice 10^18.
    function WAD() external pure returns (uint256);
    /// @notice 10^27.
    function RAY() external pure returns (uint256);
}
