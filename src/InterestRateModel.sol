// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInterestRateModel} from "./IInterestRateModel.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Meridian kink (jump) interest rate model
/// @notice Protocol contract #4. Implements the Compound-style jump curve on
///         the Ch 20 interface: per-second WAD rates, utilization computed by
///         the vault (`totalDebt / (totalDebt + cash)`, Ch 20 locked). All
///         curve parameters are IMMUTABLE — to change a curve, governance
///         deploys a new model and swaps it via the vault's
///         `setInterestRateModel` (which accrues at the old model first).
///         Parameter values in this chapter's tests are EXAMPLE values; real
///         ones are a governance vote (Ch 25 timelock holds the role).
/// @dev Curve (per-second WAD):
///         U <= kink:  r = base + U·multiplier
///         U >  kink:  r = base + kink·multiplier + (U − kink)·jumpMultiplier
///      Continuous at the kink by construction (both branches equal
///      `base + kink·multiplier` at U == kink). Rates are quoted as LINEAR
///      per-second APR; the vault's per-second index compounding turns them
///      into effective APY with the Ch 4 r²/2 compounding premium.
///      Rounding: borrowRate floors (rate is quoted, not paid directly);
///      supplyRate floors (supplier-received, Ch 4 policy); the vault's index
///      accrual ceils (borrower-paid, Ch 20 line 449).
contract InterestRateModel is IInterestRateModel {
    /// @notice Per-second base borrow rate at zero utilization (WAD).
    uint256 public immutable override baseRatePerSecond;
    /// @notice Per-second slope between zero and the kink (WAD).
    uint256 public immutable override multiplierPerSecond;
    /// @notice Per-second slope above the kink — the "jump" (WAD).
    uint256 public immutable override jumpMultiplierPerSecond;
    /// @notice Kink utilization, WAD (1e18 == 100%).
    uint256 public immutable override kink;
    /// @notice Protocol share of interest, basis points (e.g. 2000 == 20%).
    uint64 public immutable reserveFactorBps;

    constructor(
        uint256 baseRatePerSecond_,
        uint256 multiplierPerSecond_,
        uint256 jumpMultiplierPerSecond_,
        uint256 kink_,
        uint64 reserveFactorBps_
    ) {
        if (kink_ > 1e18) revert InvalidKink(kink_);
        if (reserveFactorBps_ > 10_000) revert InvalidReserveFactor(reserveFactorBps_);
        baseRatePerSecond = baseRatePerSecond_;
        multiplierPerSecond = multiplierPerSecond_;
        jumpMultiplierPerSecond = jumpMultiplierPerSecond_;
        kink = kink_;
        reserveFactorBps = reserveFactorBps_;
    }

    /// @inheritdoc IInterestRateModel
    /// @dev `public` (not `external`) because `supplyRate` calls it internally
    ///      — the Ch 4/5 external-called-internally bug class, fixed the same way.
    function borrowRate(uint256 utilization) public view override returns (uint256) {
        if (utilization <= kink) {
            return baseRatePerSecond + Math.mulDiv(utilization, multiplierPerSecond, 1e18);
        }
        return baseRatePerSecond + Math.mulDiv(kink, multiplierPerSecond, 1e18)
            + Math.mulDiv(utilization - kink, jumpMultiplierPerSecond, 1e18);
    }

    /// @inheritdoc IInterestRateModel
    function supplyRate(uint256 utilization) external view override returns (uint256) {
        // r_supply = r_borrow · U · (1 − reserveFactor). Floors: supplier-received.
        uint256 borrow = borrowRate(utilization);
        uint256 netShare = Math.mulDiv(10_000 - reserveFactorBps, utilization, 10_000);
        return Math.mulDiv(borrow, netShare, 1e18);
    }
}
