// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChainlinkFeed} from "./IChainlinkFeed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SimplePriceFeed
/// @notice Ch 40 testnet price feed — a minimal mock implementing the subset
///         of the Chainlink AggregatorV3-style interface consumed by
///         `OracleRegistry` (Ch 22), for use on a testnet where no real
///         aggregator proxy exists.
/// @dev NOT production-grade: a single admin can set any price. It exists
///      so the capstone deploy exercises the REAL registry path (primary
///      feed + staleness check + normalization) instead of bypassing it.
///      Do not treat this mock as a real Chainlink aggregator — it
///      implements only the two functions the registry reads, and nothing
///      else (no description/version/getRoundData, no medianization, no
///      heartbeat network). Each deployment is one feed = one asset
///      (Chainlink proxy shape).
contract SimplePriceFeed is IChainlinkFeed, Ownable {
    uint8 private immutable _decimals;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(uint8 decimals_) Ownable(msg.sender) {
        _decimals = decimals_;
    }

    /// @notice Pokes a new price, advancing the round (Chainlink shape).
    /// @param answer The new price in the feed's base unit (e.g. 2000e8).
    function setPrice(int256 answer) external onlyOwner {
        if (answer <= 0) revert InvalidAnswer(answer);
        _roundId += 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answer = answer;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    error InvalidAnswer(int256 answer);
}
