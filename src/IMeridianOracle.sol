// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMeridianOracle
/// @notice The oracle ABI Meridian commits to (Ch 3 Weekly Project) — the
///         compatibility contract Ch 22's `OracleRegistry` must not break.
/// @dev Interface only, no implementation (contracts arrive in Ch 20-22).
///      Chainlink-shaped primary feed + on-chain TWAP fallback + decimals.
///      Extended in Ch 20 (additively, per the ledger) with `getPrice(address)`
///      — the per-asset price resolution `MeridianVault` consumes for collateral
///      and debt valuation. Existing selectors are unchanged; the Ch 3 ABI pins
///      in MeridianOracleAbiTest still hold.
interface IMeridianOracle {
    /// @notice Chainlink-shaped latest round data, so `OracleRegistry` can
    ///         wrap feeds without translation.
    /// @return roundId The round identifier.
    /// @return answer The price in the feed's base unit.
    /// @return startedAt Timestamp the round started.
    /// @return updatedAt Timestamp the round was last updated.
    /// @return answeredInRound The round the answer was computed in.
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /// @notice On-chain TWAP fallback price.
    /// @param market The market address (asset pair) to price.
    /// @param secondsAgo Look-back window for the time-weighted average.
    /// @return price The TWAP price in the market's base unit.
    function consult(address market, uint256 secondsAgo) external view returns (uint256 price);

    /// @notice Decimals of the price feed.
    /// @return The number of decimals (e.g. 8 for USD feeds).
    function decimals() external view returns (uint8);

    /// @notice Resolves the current price of `asset` in the oracle's base unit
    ///         (base units per one whole `asset` token — e.g. 2000e8 for an
    ///         8-decimal USD feed pricing ETH at $2,000). Primary feed with
    ///         staleness handling and TWAP fallback are `OracleRegistry`'s
    ///         business (Ch 22); the vault consumes this one surface so the
    ///         manipulation-resistance choice lives in one place.
    /// @dev Added Ch 20 (additive extension, ledger-noted). Must revert if the
    ///      asset is not listed — an unpriced asset is an unhealthy asset.
    /// @param asset The token to price.
    /// @return price Base units per whole token.
    function getPrice(address asset) external view returns (uint256 price);
}
