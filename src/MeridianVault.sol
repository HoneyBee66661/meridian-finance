// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMeridianVault} from "./IMeridianVault.sol";
import {IMeridianOracle} from "./IMeridianOracle.sol";
import {IInterestRateModel} from "./IInterestRateModel.sol";

/// @title Meridian Vault (isolated lending market core) — v1
/// @notice The third protocol contract (after MER and gMER). One instance is
///         one ISOLATED market: a single collateralToken / debtToken pair with
///         its own collateral factor, liquidation parameters, interest rate
///         model, and oracle feed. Users deposit collateral, borrow against it
///         up to `collateral * price * CF`, and repay with interest. v1 has no
///         liquidation engine (Ch 24-25) — the hook is `liquidate` (reverts
///         `LiquidationNotImplemented`) and the live `isLiquidatable` view.
/// @dev Design decisions locked in Ch 20:
///      - **Isolation**: no cross-market state, so a correlated-collateral
///        crash in one market cannot drain another (the 2026 contagion class).
///      - **Health factor** = `collateralValue * LT / debtValue`, WAD. Must stay
///        ≥ 1; borrow/withdraw enforce the hard line; a position is liquidatable
///        when HF < 1, i.e. debt exceeds `LT * collateralValue`.
///        `liquidationThreshold` (WAD, e.g. 0.8e18) sits strictly above the
///        collateral factor — the safety buffer where Ch 24 liquidations
///        activate while the position is still solvent.
///      - **Accounting in token-native units**; WAD only for the borrow index,
///        rates, and prices. Per-user debt is the Compound-style
///        `principal * index / interestIndex` snapshot, so accrual is O(1) per
///        operation and never loops over users (Ch 1 bounded-loops rule).
///      - **Rounding per Ch 4/16**: the protocol never loses a wei. Interest
///        and the borrow index round UP (borrowers pay the ceil); borrow
///        capacity and health factor round DOWN (users get the floor);
///        partial-repay principal reduction rounds DOWN (the repayment
///        settles a hair less debt — the dust stays owed to the protocol).
///      - **Oracle and rate model are consumed, not owned**: `getPrice` comes
///        from `OracleRegistry` (Ch 22), `borrowRate` from `InterestRateModel`
///        (Ch 21). v1 tests against mocks so both sides can change shape-free.
///      - **Tokens must be plain ERC-20** (no fee-on-transfer, no rebase, no
///        EIP-777 hooks) — the Ch 17 listing gate; balance-delta accounting is
///        out of scope and would otherwise silently mis-price (Ch 17).
///      - v1 is NON-upgradeable (plain storage). When markets become minimal
///        proxies (Ch 38), storage moves to the Ch 6 ERC-7201 namespaces;
///        flagged in the ledger as deliberate scoping, not drift.
contract MeridianVault is IMeridianVault, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev One WAD == 1e18. The health-factor axis: HF is liquidatable below
    ///      1e18; the liquidation threshold is a WAD fraction (<= 1e18).
    uint256 private constant WAD = 1e18;

    /// @dev Basis points denominator.
    uint256 private constant BPS = 10_000;

    // ---- Immutables (Ch 8: fixed at construction, PUSH32 not SLOAD) ----
    address public immutable override collateralToken;
    address public immutable override debtToken;
    IERC20 internal immutable _collateralERC20;
    IERC20 internal immutable _debtERC20;
    uint8 internal immutable _collateralDecimals;
    uint8 internal immutable _debtDecimals;

    // ---- Market parameters (governance-settable) ----
    uint64 internal _collateralFactorBps; // borrow capacity factor, e.g. 7500
    uint256 internal _liquidationThreshold; // WAD <= 1e18, strictly > CF, e.g. 0.8e18
    uint64 internal _liquidationIncentiveBps; // e.g. 1000 (10% bonus)
    uint64 internal _reserveFactorBps; // protocol share of interest, e.g. 2000
    IMeridianOracle internal _oracle;
    IInterestRateModel internal _interestRateModel;

    // ---- Accounting ----
    struct BorrowSnapshot {
        uint256 principal; // scaled principal; debt = principal * index / interestIndex
        uint256 interestIndex; // global index at the user's last interaction
    }

    mapping(address => uint256) internal _collateralOf; // collateral-token units
    mapping(address => BorrowSnapshot) internal _borrows;
    uint256 internal _totalDebt; // current total debt, debt-token units
    uint256 internal _reserve; // protocol reserve claim, debt-token units
    uint256 internal _borrowIndex; // WAD, starts at 1e18
    uint256 internal _lastAccrual; // block.timestamp of last accrual

    /// @param collateralToken_ The token deposited as collateral.
    /// @param debtToken_ The token borrowed as debt.
    /// @param oracle_ The oracle pricing both assets (IMeridianOracle).
    /// @param interestRateModel_ The rate model (IInterestRateModel).
    /// @param collateralFactorBps_ Borrow capacity factor (<= 100%).
    /// @param liquidationThreshold_ Liquidation threshold, WAD (<= 1e18) and
    ///        strictly above the collateral factor; liquidations begin when
    ///        debt exceeds `LT * collateralValue` (HF < 1).
    /// @param liquidationIncentiveBps_ Bonus on seized collateral, non-zero.
    /// @param reserveFactorBps_ Protocol share of interest (<= 100%).
    constructor(
        address collateralToken_,
        address debtToken_,
        IMeridianOracle oracle_,
        IInterestRateModel interestRateModel_,
        uint64 collateralFactorBps_,
        uint256 liquidationThreshold_,
        uint64 liquidationIncentiveBps_,
        uint64 reserveFactorBps_
    ) {
        if (collateralToken_ == address(0) || debtToken_ == address(0)) {
            revert InvalidConstructorAddress(collateralToken_ == address(0)
                    ? collateralToken_
                    : debtToken_);
        }
        if (address(oracle_) == address(0)) revert InvalidConstructorAddress(address(oracle_));
        if (address(interestRateModel_) == address(0)) {
            revert InvalidConstructorAddress(address(interestRateModel_));
        }
        if (collateralFactorBps_ > BPS) revert InvalidCollateralFactor(collateralFactorBps_);
        // LT is a WAD fraction of collateral value: at most 1e18, and strictly
        // above the collateral factor or the safety buffer vanishes (LT == CF
        // would put max-borrow positions at HF == 1, on the liquidation line).
        if (
            liquidationThreshold_ > WAD
                || liquidationThreshold_ * BPS <= uint256(collateralFactorBps_) * WAD
        ) {
            revert InvalidLiquidationThreshold(liquidationThreshold_);
        }
        if (liquidationIncentiveBps_ == 0) {
            revert InvalidLiquidationIncentive(liquidationIncentiveBps_);
        }
        if (reserveFactorBps_ > BPS) revert InvalidReserveFactor(reserveFactorBps_);

        collateralToken = collateralToken_;
        debtToken = debtToken_;
        _collateralERC20 = IERC20(collateralToken_);
        _debtERC20 = IERC20(debtToken_);
        _collateralDecimals = IERC20Metadata(collateralToken_).decimals();
        _debtDecimals = IERC20Metadata(debtToken_).decimals();
        _oracle = oracle_;
        _interestRateModel = interestRateModel_;
        _collateralFactorBps = collateralFactorBps_;
        _liquidationThreshold = liquidationThreshold_;
        _liquidationIncentiveBps = liquidationIncentiveBps_;
        _reserveFactorBps = reserveFactorBps_;
        _borrowIndex = WAD;
        _lastAccrual = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ---- Views ---------------------------------------------------------------

    /// @inheritdoc IMeridianVault
    function oracle() external view override returns (IMeridianOracle) {
        return _oracle;
    }

    /// @inheritdoc IMeridianVault
    function interestRateModel() external view override returns (IInterestRateModel) {
        return _interestRateModel;
    }

    /// @inheritdoc IMeridianVault
    function collateralFactorBps() external view override returns (uint64) {
        return _collateralFactorBps;
    }

    /// @inheritdoc IMeridianVault
    function liquidationThreshold() external view override returns (uint256) {
        return _liquidationThreshold;
    }

    /// @inheritdoc IMeridianVault
    function liquidationIncentiveBps() external view override returns (uint64) {
        return _liquidationIncentiveBps;
    }

    /// @inheritdoc IMeridianVault
    function reserveFactorBps() external view override returns (uint64) {
        return _reserveFactorBps;
    }

    /// @inheritdoc IMeridianVault
    function collateralOf(address user) external view override returns (uint256) {
        return _collateralOf[user];
    }

    /// @inheritdoc IMeridianVault
    function debtOf(address user) external view override returns (uint256) {
        return _currentDebt(_borrows[user]);
    }

    /// @inheritdoc IMeridianVault
    function totalDebt() public view override returns (uint256) {
        return _totalDebt;
    }

    /// @inheritdoc IMeridianVault
    function reserve() external view override returns (uint256) {
        return _reserve;
    }

    /// @inheritdoc IMeridianVault
    function borrowIndex() external view override returns (uint256) {
        return _borrowIndex;
    }

    /// @inheritdoc IMeridianVault
    function utilization() public view override returns (uint256) {
        uint256 debt = totalDebt();
        uint256 cash = _idleCash();
        if (debt + cash == 0) return 0;
        return debt.mulDiv(WAD, debt + cash);
    }

    /// @inheritdoc IMeridianVault
    function borrowCapacity(address user) public view override returns (uint256) {
        uint256 collValue = _collateralOf[user].mulDiv(
            _oracle.getPrice(collateralToken), 10 ** _collateralDecimals
        );
        uint256 capacityBase = collValue.mulDiv(_collateralFactorBps, BPS);
        return capacityBase.mulDiv(10 ** _debtDecimals, _oracle.getPrice(debtToken));
    }

    /// @inheritdoc IMeridianVault
    function healthFactor(address user) public view override returns (uint256) {
        uint256 debt = _currentDebt(_borrows[user]);
        if (debt == 0) return type(uint256).max;
        return _healthFactor(_collateralOf[user], debt);
    }

    /// @inheritdoc IMeridianVault
    function isLiquidatable(address user) external view override returns (bool) {
        return healthFactor(user) < WAD;
    }

    // ---- User actions ---------------------------------------------------------

    /// @inheritdoc IMeridianVault
    function depositCollateral(uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        _collateralOf[msg.sender] += amount;
        _collateralERC20.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, amount);
    }

    /// @inheritdoc IMeridianVault
    function withdrawCollateral(uint256 amount) external override {
        _accrueInterest();
        if (amount == 0) revert ZeroAmount();
        uint256 collateral = _collateralOf[msg.sender];
        if (collateral < amount) revert InsufficientCollateral(msg.sender, amount, collateral);

        uint256 newCollateral = collateral - amount;
        uint256 hfAfter = _healthFactor(newCollateral, _currentDebt(_borrows[msg.sender]));
        if (hfAfter < WAD) revert HealthFactorTooLow(msg.sender, hfAfter, WAD);

        _collateralOf[msg.sender] = newCollateral;
        _collateralERC20.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IMeridianVault
    function borrow(uint256 amount) external override {
        _accrueInterest();
        if (amount == 0) revert ZeroAmount();

        uint256 debtAfter = _currentDebt(_borrows[msg.sender]) + amount;
        uint256 capacity = borrowCapacity(msg.sender);
        if (debtAfter > capacity) {
            revert BorrowCapacityExceeded(msg.sender, debtAfter, capacity);
        }

        uint256 idle = _idleCash();
        if (amount > idle) revert InsufficientLiquidity(amount, idle);

        // Compound-style snapshot reset: fold the user's current debt (incl.
        // all accrued interest) plus the new amount into a fresh principal
        // stamped at the current index, so `sum(debtOf) == totalDebt` always
        // holds regardless of when each user last interacted. Rounding enters
        // only via the Ceil in `_currentDebt` (the user owes at least the true
        // scaled value), never here.
        BorrowSnapshot storage b = _borrows[msg.sender];
        b.principal = _currentDebt(b) + amount;
        b.interestIndex = _borrowIndex;
        _totalDebt += amount;

        _debtERC20.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount, _totalDebt);
    }

    /// @inheritdoc IMeridianVault
    function repay(uint256 amount) external override {
        _accrueInterest();
        uint256 debt = _currentDebt(_borrows[msg.sender]);
        if (debt == 0) revert NothingToRepay(msg.sender);

        uint256 pay = amount == 0 ? debt : (amount < debt ? amount : debt);

        // Snapshot reset on the way out, mirroring borrow: the remaining debt
        // (current minus the repayment) becomes the new principal at the
        // current index. `debt` itself is Ceil-rounded, so a full repay of
        // the displayed value always clears the snapshot; a partial repay
        // leaves at most the rounding dust, which stays owed to the protocol.
        BorrowSnapshot storage b = _borrows[msg.sender];
        b.principal = debt - pay;
        b.interestIndex = _borrowIndex;
        _totalDebt -= pay;

        _debtERC20.safeTransferFrom(msg.sender, address(this), pay);
        emit Repaid(msg.sender, pay);
    }

    /// @inheritdoc IMeridianVault
    function liquidate(address, uint256) external pure override {
        revert LiquidationNotImplemented();
    }

    // ---- Governance -------------------------------------------------------------

    /// @inheritdoc IMeridianVault
    function supplyDebtLiquidity(uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _debtERC20.safeTransferFrom(msg.sender, address(this), amount);
        emit DebtLiquiditySupplied(msg.sender, amount);
    }

    /// @inheritdoc IMeridianVault
    function withdrawExcessLiquidity(uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 idle = _idleCash();
        if (amount > idle) revert ExcessiveWithdrawal(amount, idle);
        _debtERC20.safeTransfer(msg.sender, amount);
        emit ExcessLiquidityWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IMeridianVault
    function setCollateralFactor(uint64 collateralFactorBps_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (collateralFactorBps_ > BPS) {
            revert InvalidCollateralFactor(collateralFactorBps_);
        }
        emit CollateralFactorSet(_collateralFactorBps, collateralFactorBps_);
        _collateralFactorBps = collateralFactorBps_;
    }

    /// @inheritdoc IMeridianVault
    function setLiquidationThreshold(uint256 liquidationThreshold_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Same validation as the constructor: WAD fraction (<= 1e18), strictly
        // above the collateral factor so the safety buffer survives.
        if (
            liquidationThreshold_ > WAD
                || liquidationThreshold_ * BPS <= uint256(_collateralFactorBps) * WAD
        ) {
            revert InvalidLiquidationThreshold(liquidationThreshold_);
        }
        emit LiquidationThresholdSet(_liquidationThreshold, liquidationThreshold_);
        _liquidationThreshold = liquidationThreshold_;
    }

    /// @inheritdoc IMeridianVault
    function setLiquidationIncentive(uint64 liquidationIncentiveBps_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (liquidationIncentiveBps_ == 0) {
            revert InvalidLiquidationIncentive(liquidationIncentiveBps_);
        }
        emit LiquidationIncentiveSet(_liquidationIncentiveBps, liquidationIncentiveBps_);
        _liquidationIncentiveBps = liquidationIncentiveBps_;
    }

    /// @inheritdoc IMeridianVault
    function setReserveFactor(uint64 reserveFactorBps_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (reserveFactorBps_ > BPS) revert InvalidReserveFactor(reserveFactorBps_);
        emit ReserveFactorSet(_reserveFactorBps, reserveFactorBps_);
        _reserveFactorBps = reserveFactorBps_;
    }

    /// @inheritdoc IMeridianVault
    function setInterestRateModel(IInterestRateModel newModel)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _accrueInterest(); // lock pending interest at the old model
        if (address(newModel) == address(0)) revert InvalidConstructorAddress(address(newModel));
        emit InterestRateModelSet(_interestRateModel, newModel);
        _interestRateModel = newModel;
    }

    /// @inheritdoc IMeridianVault
    function setOracle(IMeridianOracle newOracle) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _accrueInterest(); // keep the accrual timeline continuous
        if (address(newOracle) == address(0)) revert InvalidConstructorAddress(address(newOracle));
        emit OracleSet(_oracle, newOracle);
        _oracle = newOracle;
    }

    // ---- Internal ----------------------------------------------------------------

    /// @dev Current debt for a snapshot, rounding UP so the user owes at least
    ///      the true scaled value.
    function _currentDebt(BorrowSnapshot memory b) internal view returns (uint256) {
        if (b.principal == 0) return 0;
        return b.principal.mulDiv(_borrowIndex, b.interestIndex, Math.Rounding.Ceil);
    }

    /// @dev Health factor for explicit collateral, WAD, floored (conservative).
    ///      `debtValue == 0` is handled by the caller (HF = max).
    ///      HF = collateralValue * LT / debtValue — the liquidation threshold,
    ///      not the collateral factor: at max borrow (debt = CF * collValue)
    ///      HF = LT/CF > 1, so the maximum borrower is never liquidatable.
    function _healthFactor(uint256 collateralAmount, uint256 debtAmount)
        internal
        view
        returns (uint256)
    {
        if (debtAmount == 0) return type(uint256).max;
        if (collateralAmount == 0) return 0;
        uint256 collValue =
            collateralAmount.mulDiv(_oracle.getPrice(collateralToken), 10 ** _collateralDecimals);
        uint256 debtValue = debtAmount.mulDiv(_oracle.getPrice(debtToken), 10 ** _debtDecimals);
        return collValue.mulDiv(_liquidationThreshold, WAD).mulDiv(WAD, debtValue);
    }

    /// @dev Lendable debt-token balance: total vault balance minus the protocol
    ///      reserve claim, saturating at zero (the all-borrowed case).
    function _idleCash() internal view returns (uint256) {
        uint256 balance = _debtERC20.balanceOf(address(this));
        return balance > _reserve ? balance - _reserve : 0;
    }

    /// @dev Applies per-second linear interest (Ch 4 convention) to `_totalDebt`
    ///      (current units) and to the global borrow index, then to the reserve
    ///      claim. O(1): no user loop — every user's debt scales with the index.
    ///      Rate comes from the model at CURRENT utilization, matching the
    ///      Compound accrual shape Ch 21's model expects. Interest and the
    ///      index bump round UP (protocol favor): borrowers pay the ceil, so
    ///      the reserve and the supplier share can never come up short.
    function _accrueInterest() internal {
        uint256 dt = block.timestamp - _lastAccrual;
        if (dt == 0) return;

        uint256 rate = _interestRateModel.borrowRate(utilization());
        uint256 interestFactor = rate * dt; // WAD
        uint256 interest = _totalDebt.mulDiv(interestFactor, WAD, Math.Rounding.Ceil);
        if (interest > 0) {
            _reserve += interest.mulDiv(_reserveFactorBps, BPS, Math.Rounding.Ceil);
            _totalDebt += interest;
            // Distributes the FULL interest (reserve + supplier share) across
            // borrowers via the index.
            _borrowIndex += _borrowIndex.mulDiv(interestFactor, WAD, Math.Rounding.Ceil);
        }

        _lastAccrual = block.timestamp;
        emit InterestAccrued(interest, _totalDebt, _reserve);
    }
}
