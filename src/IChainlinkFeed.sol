// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChainlinkFeed
/// @notice Minimal Chainlink Data Feed surface `OracleRegistry` (Ch 22) consumes.
///         Deliberately a local interface, not a Chainlink dependency: the
///         registry needs exactly two functions, and a local interface keeps
///         the repo free of the chainlink contract package while remaining
///         ABI-identical to the deployed aggregator proxies (the proxy's
///         `latestRoundData`/`decimals` are what every integrator calls).
/// @dev The full AggregatorV3Interface has a `description`/`version`/`getRoundData`
///      surface; the registry never touches those, so they are not declared.
interface IChainlinkFeed {
    /// @notice Latest round data, Chainlink aggregator-proxy shape.
    /// @return roundId The round identifier (increments per update).
    /// @return answer The median price, in the feed's base unit (e.g. 8-dec USD).
    /// @return startedAt Timestamp the round started.
    /// @return updatedAt Timestamp the round was last updated (the heartbeat
    ///         clock the registry's staleness check reads).
    /// @return answeredInRound The round the answer was computed in. If it lags
    ///         `roundId`, the answer belongs to an earlier round — the classic
    ///         incomplete-round staleness signal.
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

    /// @notice Decimals of the feed's answer (8 for USD pairs).
    function decimals() external view returns (uint8);
}
