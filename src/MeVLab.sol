// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMeVLab} from "./IMeVLab.sol";

/// @title MeVLab
/// @notice Pedagogical liquidation-race model: the health check and the bonus
///         that MEV searchers race for. NOT part of the protocol.
contract MeVLab is IMeVLab {
    address public liquidator;

    constructor(address liquidator_) {
        liquidator = liquidator_;
    }

    /// @dev Ch 20 health-factor check: D > C·P·τ ⟹ liquidatable.
    function isLiquidatable(uint256 collateral, uint256 debt, uint256 price, uint256 thresholdBps)
        public
        pure
        returns (bool)
    {
        // D × 10000 > C × P × τ  (all WAD-scaled)
        uint256 rhs = Math.mulDiv(collateral, price, 1e18); // C × P in WAD
        rhs = Math.mulDiv(rhs, thresholdBps, 10000); // × τ
        return debt > rhs;
    }

    /// @dev The bonus the liquidator captures (the MEV surface).
    function liquidationBonus(uint256 debt, uint256 bonusBps) public pure returns (uint256) {
        return Math.mulDiv(debt, bonusBps, 10000);
    }

    /// @dev The race entry — permissionless in production; the lab pins the
    ///      check with a registered liquidator for testability.
    function tryLiquidate(uint256 collateral, uint256 debt, uint256 price) external {
        if (msg.sender != liquidator) revert NotLiquidator(msg.sender);
        if (!isLiquidatable(collateral, debt, price, 8000)) revert Healthy(1e18);
    }
}
