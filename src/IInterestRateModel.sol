// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Meridian interest rate model interface
/// @notice The rate-model ABI `MeridianVault` (Ch 20) consumes. The kink
///         implementation is Ch 21's `InterestRateModel.sol`; this chapter
///         locks the contract between vault and model so both sides develop
///         and test in isolation (the vault tests against a fixed-rate mock).
/// @dev Rates are PER-SECOND in WAD (1e18 == 100% per second). This is Ch 4's
///      per-second linear accrual convention carried into the vault's
///      `_accrueInterest`; Ch 21 derives the kink curve on the same axis.
///      Utilization is also WAD (1e18 == 100%) and is COMPUTED BY THE VAULT —
///      the model reads it, it does not re-derive it. The vault's definition
///      (Ch 20, locked): `utilization = totalDebt / (totalDebt + cash)` where
///      `cash` is the vault's lendable debt-token balance.
///      Errors `InvalidKink`/`InvalidReserveFactor` were added ADDITIVELY in
///      Ch 21 (constructor-time validation of `InterestRateModel`); existing
///      function ABIs are untouched (IMeridianOracle precedent, Ch 20).
interface IInterestRateModel {
    /// @notice Constructor rejected a kink utilization above 100% (1e18).
    error InvalidKink(uint256 kink);

    /// @notice Constructor rejected a reserve factor above 100% (10_000 bps).
    error InvalidReserveFactor(uint64 reserveFactorBps);

    /// @notice Per-second borrow rate at a given utilization.
    /// @param utilization Current market utilization, WAD (1e18 == 100%).
    /// @return borrowRate Per-second borrow rate, WAD.
    function borrowRate(uint256 utilization) external view returns (uint256 borrowRate);

    /// @notice Per-second supply rate at a given utilization. Informational in
    ///         v1 (the supply side is Ch 23's sMER vault); implemented by the
    ///         real model so the chapter's numbers line up with Ch 21.
    /// @param utilization Current market utilization, WAD.
    /// @return supplyRate Per-second supply rate, WAD.
    function supplyRate(uint256 utilization) external view returns (uint256 supplyRate);

    /// @notice The kink: utilization (WAD) where the borrow-rate slope
    ///         accelerates. Ch 21's `InterestRateModel` returns its
    ///         `optimalUtilization`; the fixed-rate mock returns a constant.
    /// @return Kink utilization, WAD.
    function kink() external view returns (uint256);

    /// @notice Base per-second borrow rate at zero utilization (WAD).
    function baseRatePerSecond() external view returns (uint256);

    /// @notice Per-second multiplier applied between zero and the kink (WAD).
    function multiplierPerSecond() external view returns (uint256);

    /// @notice Per-second multiplier applied above the kink (WAD) — the "jump".
    function jumpMultiplierPerSecond() external view returns (uint256);
}
