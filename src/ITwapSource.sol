// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITwapSource
/// @notice Minimal on-chain TWAP surface the registry's fallback path consumes.
///         `OracleRegistry.consult` (the IMeridianOracle passthrough, Ch 3 ABI
///         pin) forwards to `market.consult(market, secondsAgo)`; `getPrice`
///         uses the same call internally with the governance-set window.
/// @dev The canonical implementations are Uniswap v2-pair-style cumulative
///      accumulator markets (arithmetic-mean TWAP, Ch 22 theory). The listing
///      contract for a TWAP market: `consult` must return the price of the
///      quoted asset in `twapDecimals` configured at listing, and must revert
///      or return 0 when the window is unavailable (pair too young, window
///      longer than the pair's lifetime).
interface ITwapSource {
    /// @notice Time-weighted average price over `[now - secondsAgo, now]`.
    /// @param market The market address (AMM pair) being consulted.
    /// @param secondsAgo Look-back window.
    /// @return price TWAP price in the market's configured decimals.
    function consult(address market, uint256 secondsAgo) external view returns (uint256 price);
}
