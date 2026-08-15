// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {IMeridianVault} from "../src/IMeridianVault.sol";
import {MockERC20, FixedRateInterestRateModel, MockOracle} from "./MeridianVaultMocks.sol";

/// @notice Ch 20 test suite for `MeridianVault` v1 (isolated lending market
///         core). Covers the collateral/LTV/health-factor surface, the exact
///         revert catalog (Ch 20 FINAL), rounding-direction pins (Ch 4/16),
///         oracle-price-change scenarios, and a non-privileged negative test
///         for every guarded path (Ch 10 convention).
/// @dev Methodology: parameter-exact `vm.expectRevert` (Ch 10); view reads
///      hoisted before pranks (Ch 14 finding #3 house rule); no `vm.store`;
///      gas numbers come from `.gas-snapshot` rows (Ch 13 gate), not inline
///      `gasleft()` deltas.
contract MeridianVaultTest is Test {
    using Math for uint256;

    MockERC20 internal eth;
    MockERC20 internal usdc;
    MockOracle internal oracle;
    FixedRateInterestRateModel internal zeroModel;
    FixedRateInterestRateModel internal rateModel;
    MeridianVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant LT = 0.8e18; // liquidation threshold (WAD); liquidation begins at LTV > LT
    uint256 internal constant ETH_PRICE = 2000e8; // 8-dec feed style
    uint256 internal constant USDC_PRICE = 1e8;
    uint256 internal constant CF = 7500; // 75%
    uint256 internal constant LI = 1000; // 10%
    uint256 internal constant RF = 2000; // 20%

    function setUp() public {
        eth = new MockERC20("Mock ETH", "mETH", 18);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        oracle = new MockOracle();
        oracle.setPrice(address(eth), ETH_PRICE);
        oracle.setPrice(address(usdc), USDC_PRICE);
        zeroModel = new FixedRateInterestRateModel(0, 8e17);
        rateModel = new FixedRateInterestRateModel(1e16, 8e17); // 1% per second
        vault = new MeridianVault(
            address(eth), address(usdc), oracle, zeroModel, uint64(CF), LT, uint64(LI), uint64(RF)
        );

        _fund(alice, 100e18, 1_000_000e6);
        _fund(bob, 100e18, 1_000_000e6);
    }

    // ---- Helpers -----------------------------------------------------------

    function _fund(address who, uint256 ethAmt, uint256 usdcAmt) internal {
        eth.mint(who, ethAmt);
        usdc.mint(who, usdcAmt);
        vm.startPrank(who);
        eth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Admin (the test contract holds DEFAULT_ADMIN_ROLE) seeds the market
    ///      debt pool — the v1 stand-in for the Ch 23 supply side.
    function _supply(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.supplyDebtLiquidity(amount);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        vault.depositCollateral(amount);
    }

    function _borrow(address who, uint256 amount) internal {
        vm.prank(who);
        vault.borrow(amount);
    }

    function _repay(address who, uint256 amount) internal {
        vm.prank(who);
        vault.repay(amount);
    }

    /// @dev Switches the vault to the 1%/sec fixed-rate model.
    function _useRateModel() internal {
        vault.setInterestRateModel(rateModel);
    }

    /// @dev Any state-changing call accrues interest; this no-op governance
    ///      call (re-points the oracle at the same mock) triggers accrual after
    ///      a `vm.warp` without disturbing balances.
    function _triggerAccrual() internal {
        vault.setOracle(oracle);
    }

    function _expectNotAdmin(address caller) internal {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE(); // hoisted before any prank
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role
            )
        );
    }

    // ---- Happy paths ---------------------------------------------------------

    function test_depositCollateral_increasesCollateral() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit IMeridianVault.CollateralDeposited(alice, 1e18);
        _deposit(alice, 1e18);

        assertEq(vault.collateralOf(alice), 1e18);
        assertEq(eth.balanceOf(address(vault)), 1e18);
    }

    function test_withdrawCollateral_partialAndFull() public {
        _deposit(alice, 2e18);
        vm.prank(alice);
        vault.withdrawCollateral(5e17);
        assertEq(vault.collateralOf(alice), 1.5e18);

        vm.prank(alice);
        vault.withdrawCollateral(1.5e18);
        assertEq(vault.collateralOf(alice), 0);
        assertEq(eth.balanceOf(address(vault)), 0);
    }

    function test_borrow_withinCapacity() public {
        _supply(3000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 1000e6);

        assertEq(vault.debtOf(alice), 1000e6);
        assertEq(vault.totalDebt(), 1000e6);
        assertEq(usdc.balanceOf(alice), 1_001_000e6);
    }

    function test_repay_partialAndFull() public {
        _supply(3000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 1000e6);

        _repay(alice, 400e6);
        assertEq(vault.debtOf(alice), 600e6);
        assertEq(vault.totalDebt(), 600e6);

        _repay(alice, 0); // repay all
        assertEq(vault.debtOf(alice), 0);
        assertEq(vault.totalDebt(), 0);
    }

    function test_borrow_exactlyCapacity_healthFactorAboveOne() public {
        _supply(3000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 3000e6);
        // At max borrow (LTV = CF = 75%), HF = LT/CF = 0.8/0.75 = 1.0667 > 1:
        // the maximum borrower is healthy, never liquidatable.
        assertEq(vault.healthFactor(alice), 1_066_666_666_666_666_666);
        assertFalse(vault.isLiquidatable(alice));
        assertEq(vault.debtOf(alice), 3000e6);
    }

    function test_repay_overDebt_capsAtDebt() public {
        _supply(3000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 100e6);

        _repay(alice, 999e6); // more than owed
        assertEq(vault.debtOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 1_000_000e6); // only 100e6 pulled
    }

    function test_healthFactor_noDebt_isMax() public {
        _deposit(alice, 2e18);
        assertEq(vault.healthFactor(alice), type(uint256).max);
        assertFalse(vault.isLiquidatable(alice));
    }

    function test_utilization_movesWithBorrow() public {
        assertEq(vault.utilization(), 0);
        _supply(2000e6);
        _deposit(alice, 1e18);
        assertEq(vault.utilization(), 0);
        _borrow(alice, 1000e6);
        assertEq(vault.utilization(), 0.5e18);
    }

    function test_capacity_math_pin() public {
        _deposit(alice, 2e18);
        // 2 ETH * 2000e8 / 1e18 * 0.75 -> 3000e8 base -> /1e8 * 1e6 = 3000e6
        assertEq(vault.borrowCapacity(alice), 3000e6);
    }

    function test_capacity_floor_direction() public {
        _deposit(alice, 1e18);
        oracle.setPrice(address(eth), ETH_PRICE + 7); // 200000000007
        uint256 expected =
            Math.mulDiv(Math.mulDiv(1e18, ETH_PRICE + 7, 1e18), CF, 10_000).mulDiv(1e6, USDC_PRICE);
        assertEq(vault.borrowCapacity(alice), expected);
        assertEq(vault.borrowCapacity(alice), 1_500_000_000); // floored; Ceil would be +1
    }

    // ---- Interest accrual & rounding pins --------------------------------------

    function test_interest_accruesOverTime_andReserve() public {
        _useRateModel();
        _supply(1000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 1000e6); // consumes all idle -> utilization 100%

        vm.warp(block.timestamp + 10);
        _triggerAccrual();

        assertEq(vault.borrowIndex(), 1.1e18); // 1% * 10s
        assertEq(vault.totalDebt(), 1100e6);
        assertEq(vault.debtOf(alice), 1100e6);
        assertEq(vault.reserve(), 20e6); // 20% reserve factor on 100e6 interest
    }

    function test_interestAccrual_debtRoundsUp() public {
        _useRateModel();
        _supply(1_000_000e6);
        _deposit(alice, 1e18);
        _borrow(alice, 1_000_001); // 1.000001 USDC

        vm.warp(block.timestamp + 3); // index -> 1.03e18
        _triggerAccrual();

        // true debt = 1000001 * 1.03 = 1030001.03 -> CEIL = 1030002
        assertEq(vault.borrowIndex(), 1.03e18);
        assertEq(vault.debtOf(alice), 1_030_002);
    }

    function test_repayDust_staysOwed_thenFullRepayClears() public {
        _useRateModel();
        _supply(1_000_000e6);
        _deposit(alice, 1e18);
        _borrow(alice, 1_000_001);
        vm.warp(block.timestamp + 3);
        _triggerAccrual();

        // Repay the floored amount: debt stays at 1030002, so 1 wei of Ceil
        // dust remains owed to the protocol (floor accounting would have
        // shorted it). The snapshot reset makes the remaining debt exact.
        _repay(alice, 1_030_001);
        assertEq(vault.debtOf(alice), 1);

        _repay(alice, 0);
        assertEq(vault.debtOf(alice), 0);
        assertEq(vault.totalDebt(), 0);
    }

    function test_newBorrowerAndExistingBorrower_snapshotConsistency() public {
        _useRateModel();
        _supply(1_000_000e6);
        _deposit(alice, 2e18);
        _deposit(bob, 1e18);
        _borrow(alice, 100e6);

        vm.warp(block.timestamp + 100); // 1% * 100s -> index doubles
        _triggerAccrual();
        assertEq(vault.borrowIndex(), 2e18);
        assertEq(vault.debtOf(alice), 200e6);

        // Alice borrows more AFTER the index doubled: her snapshot resets.
        _borrow(alice, 100e6);
        // Bob borrows fresh at the doubled index.
        _borrow(bob, 100e6);

        assertEq(vault.debtOf(alice), 300e6);
        assertEq(vault.debtOf(bob), 100e6);
        assertEq(vault.totalDebt(), 400e6); // sum(debtOf) == totalDebt
    }

    // ---- Health-factor enforcement negatives -------------------------------------

    function test_borrow_aboveCapacity_reverts() public {
        _supply(3000e6);
        _deposit(alice, 1e18); // capacity 1500e6
        vm.expectRevert(
            abi.encodeWithSelector(
                IMeridianVault.BorrowCapacityExceeded.selector, alice, 1_500_000_001, 1_500_000_000
            )
        );
        vm.prank(alice);
        vault.borrow(1_500_000_001);
    }

    function test_borrow_undercollateralized_reverts() public {
        _supply(1000e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.BorrowCapacityExceeded.selector, bob, 100e6, 0)
        );
        vm.prank(bob);
        vault.borrow(100e6);
    }

    function test_borrow_withoutLiquidity_reverts() public {
        _deposit(alice, 2e18); // capacity 3000e6, but no idle liquidity
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InsufficientLiquidity.selector, 100e6, 0)
        );
        vm.prank(alice);
        vault.borrow(100e6);
    }

    function test_withdraw_belowHealthFactor_reverts() public {
        _supply(2000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 2000e6);

        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.HealthFactorTooLow.selector, alice, 0, 1e18)
        );
        vm.prank(alice);
        vault.withdrawCollateral(2e18);
    }

    function test_withdraw_aboveCollateral_reverts() public {
        _deposit(alice, 2e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMeridianVault.InsufficientCollateral.selector, alice, 2e18 + 1, 2e18
            )
        );
        vm.prank(alice);
        vault.withdrawCollateral(2e18 + 1);
    }

    function test_deposit_zero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMeridianVault.ZeroAmount.selector));
        vm.prank(alice);
        vault.depositCollateral(0);
    }

    function test_withdraw_zero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMeridianVault.ZeroAmount.selector));
        vm.prank(alice);
        vault.withdrawCollateral(0);
    }

    function test_borrow_zero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMeridianVault.ZeroAmount.selector));
        vm.prank(alice);
        vault.borrow(0);
    }

    function test_repay_noDebt_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMeridianVault.NothingToRepay.selector, alice));
        vm.prank(alice);
        vault.repay(1);
    }

    function test_liquidate_placeholder_reverts_untilCh24() public {
        vm.expectRevert(abi.encodeWithSelector(IMeridianVault.LiquidationNotImplemented.selector));
        vault.liquidate(alice, 1);
    }

    // ---- Oracle-price-change scenarios ---------------------------------------------

    function test_priceDrop_makesLiquidatable_andBlocksWithdraw() public {
        _supply(3000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 2000e6);
        // HF = 4000e8 * 0.8 / 2000e8 = 1.6 (the chapter's Production Example)
        assertEq(vault.healthFactor(alice), 1.6e18);

        oracle.setPrice(address(eth), 1200e8); // -40%
        // HF = 2400e8 * 0.8 / 2000e8 = 0.96 < 1 -> liquidatable
        assertEq(vault.healthFactor(alice), 0.96e18);
        assertTrue(vault.isLiquidatable(alice));

        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.HealthFactorTooLow.selector, alice, 0, 1e18)
        );
        vm.prank(alice);
        vault.withdrawCollateral(2e18);
    }

    function test_priceDrop_bufferZone_liquidatableButSolvent() public {
        _supply(3000e6);
        _deposit(alice, 2e18); // collateral value 4000e8 at $2000
        _borrow(alice, 2200e6);
        // HF = 4000e8 * 0.8 / 2200e8 = 1.4545 -> healthy, not liquidatable
        assertEq(vault.healthFactor(alice), 1_454_545_454_545_454_545);
        assertFalse(vault.isLiquidatable(alice));

        // Price drops to $1370: collateral value 2740e8, LT-adjusted 2192e8,
        // HF = 2192/2200 = 0.9964 < 1 -> liquidatable, yet still solvent:
        // debt (2200e8) is below collateral value (2740e8) — the liquidatable-
        // but-solvent zone (LTV 80.3% between LT 80% and 100%).
        oracle.setPrice(address(eth), 1370e8);
        uint256 hf = vault.healthFactor(alice);
        assertLt(hf, 1e18);
        assertTrue(vault.isLiquidatable(alice));
        uint256 collValue = Math.mulDiv(2e18, 1370e8, 1e18);
        uint256 debtValue = Math.mulDiv(2200e6, USDC_PRICE, 1e6);
        assertLt(debtValue, collValue);
    }

    function test_priceRise_increasesCapacity() public {
        _deposit(alice, 1e18);
        assertEq(vault.borrowCapacity(alice), 1500e6);
        oracle.setPrice(address(eth), 3000e8);
        assertEq(vault.borrowCapacity(alice), 2250e6);
    }

    // ---- Governance happy paths -----------------------------------------------------

    function test_setCollateralFactor_updatesCapacity() public {
        _deposit(alice, 2e18);
        assertEq(vault.borrowCapacity(alice), 3000e6);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IMeridianVault.CollateralFactorSet(uint64(CF), uint64(8000));
        vault.setCollateralFactor(8000);

        assertEq(vault.collateralFactorBps(), 8000);
        assertEq(vault.borrowCapacity(alice), 3200e6);
    }

    function test_supplyDebtLiquidity_enablesBorrowing() public {
        _deposit(alice, 2e18);
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InsufficientLiquidity.selector, 100e6, 0)
        );
        vm.prank(alice);
        vault.borrow(100e6);

        _supply(1000e6);
        _borrow(alice, 100e6);
        assertEq(vault.debtOf(alice), 100e6);
    }

    function test_withdrawExcessLiquidity_idleOnly() public {
        _supply(1000e6);
        _deposit(alice, 2e18);
        _borrow(alice, 100e6);
        assertEq(vault.utilization(), 0.1e18);

        vault.withdrawExcessLiquidity(900e6);
        assertEq(usdc.balanceOf(address(vault)), 0); // all idle pulled; debt still owed

        vm.expectRevert(abi.encodeWithSelector(IMeridianVault.ExcessiveWithdrawal.selector, 1, 0));
        vault.withdrawExcessLiquidity(1);
    }

    // ---- Non-privileged negatives (every guarded path, Ch 10 convention) -----------

    function test_setCollateralFactor_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.setCollateralFactor(8000);
    }

    function test_setLiquidationThreshold_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.setLiquidationThreshold(0.9e18);
    }

    function test_setLiquidationIncentive_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.setLiquidationIncentive(2000);
    }

    function test_setReserveFactor_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.setReserveFactor(3000);
    }

    function test_setInterestRateModel_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.setInterestRateModel(rateModel);
    }

    function test_setOracle_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.setOracle(oracle);
    }

    function test_supplyDebtLiquidity_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.supplyDebtLiquidity(100e6);
    }

    function test_withdrawExcessLiquidity_onlyAdmin() public {
        _expectNotAdmin(alice);
        vm.prank(alice);
        vault.withdrawExcessLiquidity(100e6);
    }

    // ---- Admin parameter validation ----------------------------------------------

    function test_setCollateralFactor_above10000_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidCollateralFactor.selector, uint64(10_001))
        );
        vault.setCollateralFactor(10_001);
    }

    function test_setLiquidationThreshold_atCollateralFactor_reverts() public {
        // LT must sit strictly above the collateral factor or the safety
        // buffer vanishes: at LT == CF (75%) a max-borrow position would sit
        // at HF == 1, right on the liquidation line.
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidLiquidationThreshold.selector, 0.75e18)
        );
        vault.setLiquidationThreshold(0.75e18);
    }

    function test_setLiquidationIncentive_zero_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidLiquidationIncentive.selector, uint64(0))
        );
        vault.setLiquidationIncentive(0);
    }

    function test_setReserveFactor_above10000_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidReserveFactor.selector, uint64(10_001))
        );
        vault.setReserveFactor(10_001);
    }

    // ---- Constructor guards ---------------------------------------------------------

    function test_constructor_zeroCollateralAddress_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidConstructorAddress.selector, address(0))
        );
        new MeridianVault(
            address(0), address(usdc), oracle, zeroModel, uint64(CF), LT, uint64(LI), uint64(RF)
        );
    }

    function test_constructor_zeroOracleAddress_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidConstructorAddress.selector, address(0))
        );
        new MeridianVault(
            address(eth),
            address(usdc),
            MockOracle(address(0)),
            zeroModel,
            uint64(CF),
            LT,
            uint64(LI),
            uint64(RF)
        );
    }

    function test_constructor_liquidationThresholdAboveOne_reverts() public {
        // LT is a WAD fraction of collateral value; > 1e18 is off-axis.
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidLiquidationThreshold.selector, 1.05e18)
        );
        new MeridianVault(
            address(eth),
            address(usdc),
            oracle,
            zeroModel,
            uint64(CF),
            1.05e18,
            uint64(LI),
            uint64(RF)
        );
    }

    function test_constructor_collateralFactorAbove10000_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidCollateralFactor.selector, uint64(10_001))
        );
        new MeridianVault(
            address(eth),
            address(usdc),
            oracle,
            zeroModel,
            uint64(10_001),
            LT,
            uint64(LI),
            uint64(RF)
        );
    }

    function test_constructor_reserveFactorAbove10000_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianVault.InvalidReserveFactor.selector, uint64(10_001))
        );
        new MeridianVault(
            address(eth),
            address(usdc),
            oracle,
            zeroModel,
            uint64(CF),
            LT,
            uint64(LI),
            uint64(10_001)
        );
    }

    // ---- Gas probes (log-only; `.gas-snapshot` rows are the gate, Ch 13) ----------

    function test_gas_depositCollateral() public {
        _deposit(alice, 1e18);
    }

    function test_gas_borrow() public {
        _supply(1000e6);
        _deposit(alice, 1e18);
        _borrow(alice, 500e6);
    }

    function test_gas_repay() public {
        _supply(1000e6);
        _deposit(alice, 1e18);
        _borrow(alice, 500e6);
        _repay(alice, 500e6);
    }
}
