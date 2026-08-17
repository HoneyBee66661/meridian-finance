// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMeVLab
/// @notice I-prefix interface — the liquidation-race model.
interface IMeVLab {
    error Healthy(uint256 healthFactor);
    error NotLiquidator(address caller);

    function isLiquidatable(uint256 collateral, uint256 debt, uint256 price, uint256 thresholdBps)
        external
        pure
        returns (bool);
    function liquidationBonus(uint256 debt, uint256 bonusBps) external pure returns (uint256);
    function tryLiquidate(uint256 collateral, uint256 debt, uint256 price) external;
}
