// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInterestRateModel} from "./IInterestRateModel.sol";
import {IMeridianOracle} from "./IMeridianOracle.sol";

/// @title Meridian Vault interface (isolated lending market core)
/// @notice Protocol-facing surface of `MeridianVault` v1 (Ch 20). This file
///         FINALIZES the vault error catalog that has been PROVISIONAL since
///         Ch 2 (see ledger; Ch 14 resolved it for tokens, this chapter
///         resolves it for the vault). The catalog is the contract every
///         subsequent module (Ch 21 rate model, Ch 22 oracles, Ch 23 sMER,
///         Ch 24-25 liquidation + governance) reverts against.
/// @dev One `MeridianVault` instance == one ISOLATED market pair
///      (collateralToken / debtToken). Isolation means a crash in one
///      market's collateral cannot drain any other market — the account
///      model below is entirely per-instance. Each market carries its own
///      collateral factor, liquidation parameters, interest rate model, and
///      oracle feed (TOC: "Each market (asset pair) has its own collateral
///      factor, kink-based interest rate model, and oracle feed").
///      v1 scope (Ch 20): collateral deposit/withdraw, borrow/repay,
///      health-factor enforcement on borrow & withdraw. The liquidation
///      ENGINE is Ch 24-25; the hook shape is anticipated here (`liquidate`
///      reverts `LiquidationNotImplemented` until then) and the health-factor
///      + threshold surface it consumes is already live.
interface IMeridianVault {
    /// @notice The token deposited as collateral (e.g. an ETH-like token).
    function collateralToken() external view returns (address);

    /// @notice The token borrowed as debt (e.g. a USDC-like token).
    function debtToken() external view returns (address);

    /// @notice The oracle used to price both assets. Consumed, never owned:
    ///         `OracleRegistry` (Ch 22) implements `IMeridianOracle`.
    function oracle() external view returns (IMeridianOracle);

    /// @notice The interest rate model. Consumed, never owned:
    ///         `InterestRateModel` (Ch 21) implements `IInterestRateModel`.
    function interestRateModel() external view returns (IInterestRateModel);

    /// @notice Collateral factor in basis points (e.g. 7500 == 75%): the
    ///         fraction of collateral value usable as borrow capacity.
    function collateralFactorBps() external view returns (uint64);

    /// @notice Liquidation threshold in WAD (e.g. 0.8e18 == 80%): the fraction
    ///         of collateral value at which liquidation begins. The health
    ///         factor is `collateralValue * LT / debtValue`, so a position is
    ///         liquidatable when HF < 1 — equivalently when debt exceeds
    ///         LT * collateralValue. LT must sit strictly above the collateral
    ///         factor (the safety buffer) and at most 1e18. Ch 24-25 build on
    ///         this.
    function liquidationThreshold() external view returns (uint256);

    /// @notice Liquidation incentive in basis points (e.g. 1000 == 10% bonus
    ///         on the collateral a liquidator seizes). Consumed by Ch 24.
    function liquidationIncentiveBps() external view returns (uint64);

    /// @notice Reserve factor in basis points: the protocol's share of
    ///         accrued interest (revenue route to sMER stakers, Ch 23).
    function reserveFactorBps() external view returns (uint64);

    /// @notice Collateral held by `user`, in collateral-token native units.
    function collateralOf(address user) external view returns (uint256);

    /// @notice Current debt owed by `user`, in debt-token native units,
    ///         including all accrued-but-unpaid interest.
    function debtOf(address user) external view returns (uint256);

    /// @notice Current total debt across all borrowers, in debt-token units.
    function totalDebt() external view returns (uint256);

    /// @notice Protocol reserve claim (debt-token units): the reserve-factor
    ///         share of interest that has accrued and is owed to the protocol.
    function reserve() external view returns (uint256);

    /// @notice Global borrow index (WAD, starts at 1e18). Per-user debt is
    ///         `principal * index / interestIndex`, the Compound-style
    ///         interest-rate snapshot that makes accrual O(1) per user.
    function borrowIndex() external view returns (uint256);

    /// @notice Market utilization in WAD:
    ///         `totalDebt / (totalDebt + cash)` where `cash` is the vault's
    ///         lendable debt-token balance (balance minus reserve).
    function utilization() external view returns (uint256);

    /// @notice Maximum additional debt `user` may hold, in debt-token units:
    ///         `collateral * price_collateral * CF / price_debt`, floored.
    function borrowCapacity(address user) external view returns (uint256);

    /// @notice Health factor of `user` in WAD:
    ///         `collateralValue * LT / debtValue` (liquidation threshold, not
    ///         the collateral factor). No debt -> type(uint256).max;
    ///         no collateral -> 0. Must stay at or above 1 (the borrow/withdraw
    ///         hard line); a position is liquidatable when HF drops below 1.
    function healthFactor(address user) external view returns (uint256);

    /// @notice True when `healthFactor(user) < 1e18` — i.e. the user's debt
    ///         exceeds `liquidationThreshold * collateralValue`. The predicate
    ///         the Ch 24 liquidation engine consumes.
    function isLiquidatable(address user) external view returns (bool);

    // ---- User actions ------------------------------------------------------

    /// @notice Deposits `amount` collateral-token into the vault for the caller.
    function depositCollateral(uint256 amount) external;

    /// @notice Withdraws `amount` collateral-token. Reverts if the resulting
    ///         health factor would drop below 1.
    function withdrawCollateral(uint256 amount) external;

    /// @notice Borrows `amount` debt-token. Reverts if it exceeds the caller's
    ///         borrow capacity or the vault's idle liquidity.
    function borrow(uint256 amount) external;

    /// @notice Repays the caller's debt. `amount == 0` repays the full current
    ///         debt; any amount above the current debt is capped at the debt.
    function repay(uint256 amount) external;

    /// @notice Placeholder for the Ch 24-25 liquidation engine. Reverts
    ///         `LiquidationNotImplemented` in v1; the shape (borrower +
    ///         debtToCover + collateral seizure at the incentive) is locked
    ///         so the interface does not change when the engine ships.
    function liquidate(address borrower, uint256 debtToCover) external;

    // ---- Governance (DEFAULT_ADMIN_ROLE; Ch 25 timelock in production) -----

    /// @notice Pulls `amount` debt-token into the vault as lendable liquidity.
    ///         v1 stand-in for the Ch 23 supply side (sMER vault).
    function supplyDebtLiquidity(uint256 amount) external;

    /// @notice Withdraws idle liquidity back to the admin, capped at the vault's
    ///         lendable cash (never the reserve or borrowed-out funds).
    function withdrawExcessLiquidity(uint256 amount) external;

    function setCollateralFactor(uint64 collateralFactorBps_) external;
    function setLiquidationThreshold(uint256 liquidationThreshold_) external;
    function setLiquidationIncentive(uint64 liquidationIncentiveBps_) external;
    function setReserveFactor(uint64 reserveFactorBps_) external;
    function setInterestRateModel(IInterestRateModel newModel) external;
    function setOracle(IMeridianOracle newOracle) external;

    // ---- Events -------------------------------------------------------------

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 totalDebtAfter);
    event Repaid(address indexed user, uint256 amount);
    event InterestAccrued(uint256 interest, uint256 totalDebtAfter, uint256 reserveAfter);
    event CollateralFactorSet(uint64 oldValue, uint64 newValue);
    event LiquidationThresholdSet(uint256 oldValue, uint256 newValue);
    event LiquidationIncentiveSet(uint64 oldValue, uint64 newValue);
    event ReserveFactorSet(uint64 oldValue, uint64 newValue);
    event InterestRateModelSet(IInterestRateModel oldModel, IInterestRateModel newModel);
    event OracleSet(IMeridianOracle oldOracle, IMeridianOracle newOracle);
    event DebtLiquiditySupplied(address indexed supplier, uint256 amount);
    event ExcessLiquidityWithdrawn(address indexed recipient, uint256 amount);

    // ---- Errors (FINAL vault catalog — Ch 20 resolves Ch 2 PROVISIONAL) -----

    /// @notice A constructor address argument was the zero address.
    error InvalidConstructorAddress(address account);

    /// @notice Constructor parameters were internally inconsistent
    ///         (e.g. a liquidation threshold above 1 or at/below the
    ///         collateral factor).
    error InvalidMarketParams();

    /// @notice A zero amount was passed where a positive amount is required.
    error ZeroAmount();

    /// @notice The caller tried to withdraw more collateral than they hold.
    error InsufficientCollateral(address user, uint256 requested, uint256 available);

    /// @notice The borrow would push the user's debt above their capacity.
    error BorrowCapacityExceeded(address user, uint256 requestedDebt, uint256 capacity);

    /// @notice An action would push the health factor below the minimum (1).
    error HealthFactorTooLow(address user, uint256 healthFactor, uint256 minimum);

    /// @notice The vault does not hold enough idle liquidity to fund the borrow.
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice The caller tried to repay with no outstanding debt.
    error NothingToRepay(address user);

    /// @notice Collateral factor must be at most 100%.
    error InvalidCollateralFactor(uint64 value);

    /// @notice Liquidation threshold must be at most 1 (WAD) and strictly above
    ///         the collateral factor.
    error InvalidLiquidationThreshold(uint256 value);

    /// @notice Liquidation incentive must be non-zero.
    error InvalidLiquidationIncentive(uint64 value);

    /// @notice Reserve factor must be at most 100%.
    error InvalidReserveFactor(uint64 value);

    /// @notice The liquidation engine has not shipped (Ch 24-25).
    error LiquidationNotImplemented();

    /// @notice The admin tried to withdraw more idle liquidity than exists.
    error ExcessiveWithdrawal(uint256 requested, uint256 available);
}
