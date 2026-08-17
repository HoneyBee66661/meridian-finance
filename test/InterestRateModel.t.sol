// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {IInterestRateModel} from "../src/IInterestRateModel.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MockERC20, MockOracle} from "./MeridianVaultMocks.sol";

/// @notice Ch 21 test suite for `InterestRateModel` (kink/jump curve, protocol
///         contract #4). Covers constructor validation, curve pins on the
///         per-second WAD axis, monotonicity/closed-form fuzz, supply-rate
///         pins (r_s = r_b·U·(1−RF), floor), vault integration with the REAL
///         model (self-consistent accrual, compounding bonus, utilization→rate
///         wiring, governance swap + negative test), and gas probes.
/// @dev Methodology: parameter-exact `vm.expectRevert` (Ch 10); view reads
///      hoisted before pranks (Ch 14 finding #3 house rule); fuzz `bound` to
///      [0, 1e18] (Ch 12); gas = loop-amplified min-deltas with warm-up first
///      (Ch 8/9 standing rules); rates are per-second WAD — per-second
///      quantization dust (~0.0003%) is tolerated by APR-sanity pins, while
///      exact pins use the model's own quantized rate (self-consistent).
contract InterestRateModelTest is Test {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant BPS = 10_000;

    // Example governance params (Ch 21, locked): base 2% APR, multiplier 10%
    // APR, jump 100% APR, kink 80% utilization, reserve factor 20%.
    uint256 internal constant BASE_APR = 2e16;
    uint256 internal constant MULT_APR = 1e17;
    uint256 internal constant JUMP_APR = 1e18;
    uint256 internal constant KINK = 8e17;
    uint64 internal constant RESERVE = 2000;

    InterestRateModel internal model;

    MockERC20 internal eth;
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MeridianVault internal vault;

    address internal alice = makeAddr("alice");

    // ---- helpers -----------------------------------------------------------

    /// @dev Linear APR (WAD) → per-second WAD rate, Ch 21 locked convention.
    function _aprToPerSecond(uint256 aprWad) internal pure returns (uint256) {
        return aprWad / SECONDS_PER_YEAR;
    }

    /// @dev Closed-form reference (plain arithmetic — safe: max product here
    ///      is 1e18·1e18 = 1e36 << 2^256) as an independent check on mulDiv.
    function _refBorrowRate(uint256 u) internal pure returns (uint256) {
        if (u <= KINK) return _aprToPerSecond(BASE_APR) + (u * _aprToPerSecond(MULT_APR)) / WAD;
        return _aprToPerSecond(BASE_APR) + (KINK * _aprToPerSecond(MULT_APR)) / WAD
            + ((u - KINK) * _aprToPerSecond(JUMP_APR)) / WAD;
    }

    function _refSupplyRate(uint256 u) internal pure returns (uint256) {
        uint256 netShare = (u * (BPS - RESERVE)) / BPS;
        return (_refBorrowRate(u) * netShare) / WAD;
    }

    function _deployVault() internal returns (MeridianVault v) {
        v = new MeridianVault(
            address(eth), address(usdc), oracle, model, 7500, 0.8e18, 1000, uint64(RESERVE)
        );
    }

    /// @dev Standard Ch 20 wiring: test contract (vault admin) supplies 10,000
    ///      mUSDC liquidity, alice deposits 10 mETH (priced 2000e8) and borrows
    ///      5,000 mUSDC → utilization exactly 50%.
    function _openBorrowPosition() internal {
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), 10_000e6);
        vault.supplyDebtLiquidity(10_000e6);

        eth.mint(alice, 10e18);
        vm.startPrank(alice);
        eth.approve(address(vault), 10e18);
        vault.depositCollateral(10e18);
        usdc.approve(address(vault), 5_000e6);
        vault.borrow(5_000e6);
        vm.stopPrank();

        assertEq(vault.utilization(), 5e17, "utilization must be exactly 50%");
    }

    /// @dev Loop-amplified min-delta gas probe (Ch 8/9 standing rule).
    function _gasBorrowRate(uint256 u) internal view returns (uint256) {
        model.borrowRate(u); // warm-up call
        uint256 minDelta = type(uint256).max;
        for (uint256 i = 0; i < 64; i++) {
            uint256 g0 = gasleft();
            model.borrowRate(u);
            uint256 g1 = gasleft();
            uint256 d = g0 - g1;
            if (d < minDelta) minDelta = d;
        }
        return minDelta;
    }

    // ---- setup -------------------------------------------------------------

    function setUp() public {
        model = new InterestRateModel(
            _aprToPerSecond(BASE_APR),
            _aprToPerSecond(MULT_APR),
            _aprToPerSecond(JUMP_APR),
            KINK,
            RESERVE
        );
        eth = new MockERC20("Mock ETH", "mETH", 18);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        oracle = new MockOracle();
        oracle.setPrice(address(eth), 2000e8);
        oracle.setPrice(address(usdc), 1e8);
        vault = _deployVault();
    }

    // ---- constructor -------------------------------------------------------

    function test_constructor_readsBackParams() public view {
        assertEq(model.baseRatePerSecond(), _aprToPerSecond(BASE_APR));
        assertEq(model.multiplierPerSecond(), _aprToPerSecond(MULT_APR));
        assertEq(model.jumpMultiplierPerSecond(), _aprToPerSecond(JUMP_APR));
        assertEq(model.kink(), KINK);
        assertEq(model.reserveFactorBps(), RESERVE);
    }

    function test_constructor_allowsKinkAtMax() public {
        InterestRateModel m = new InterestRateModel(0, 0, 0, 1e18, 0);
        assertEq(m.kink(), 1e18);
    }

    function test_constructor_rejectsKinkAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(IInterestRateModel.InvalidKink.selector, 1e18 + 1));
        new InterestRateModel(0, 0, 0, 1e18 + 1, 0);
    }

    function test_constructor_allowsReserveFactorAtMax() public {
        InterestRateModel m = new InterestRateModel(0, 0, 0, 0, 10_000);
        assertEq(m.reserveFactorBps(), 10_000);
        assertEq(m.supplyRate(5e17), 0, "100% reserve factor leaves suppliers nothing");
    }

    function test_constructor_rejectsReserveFactorAboveMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(IInterestRateModel.InvalidReserveFactor.selector, 10_001)
        );
        new InterestRateModel(0, 0, 0, 0, 10_001);
    }

    // ---- curve pins (per-second WAD) ---------------------------------------

    function test_borrowRate_atZeroUtilization_isBase() public view {
        assertEq(model.borrowRate(0), _aprToPerSecond(BASE_APR));
    }

    function test_borrowRate_midBand_isSevenPercentApr() public view {
        // U = 50% → 2% + 50%·10% = 7% APR; exact against the closed form,
        // and within 0.01% of the ideal APR (per-second quantization).
        uint256 r = model.borrowRate(5e17);
        assertEq(r, _refBorrowRate(5e17));
        uint256 ideal = _aprToPerSecond(7e16);
        uint256 tol = ideal / 10_000;
        assertTrue(r >= ideal - tol && r <= ideal + tol, "r(50%) must be ~7% APR");
    }

    function test_borrowRate_atKink_isTenPercentApr() public view {
        uint256 r = model.borrowRate(KINK);
        assertEq(r, _refBorrowRate(KINK));
        uint256 ideal = _aprToPerSecond(1e17);
        uint256 tol = ideal / 10_000;
        assertTrue(r >= ideal - tol && r <= ideal + tol, "r(80%) must be ~10% APR");
    }

    function test_borrowRate_atMaxUtilization_isThirtyPercentApr() public view {
        uint256 r = model.borrowRate(1e18);
        assertEq(r, _refBorrowRate(1e18));
        uint256 ideal = _aprToPerSecond(3e17);
        uint256 tol = ideal / 10_000;
        assertTrue(r >= ideal - tol && r <= ideal + tol, "r(100%) must be ~30% APR");
    }

    function test_borrowRate_continuousAtKink() public view {
        // Both branches evaluate base + kink·multiplier at U == kink.
        uint256 left = _aprToPerSecond(BASE_APR) + (KINK * _aprToPerSecond(MULT_APR)) / WAD;
        uint256 right = _aprToPerSecond(BASE_APR) + (KINK * _aprToPerSecond(MULT_APR)) / WAD
            + ((KINK - KINK) * _aprToPerSecond(JUMP_APR)) / WAD;
        assertEq(left, right);
        assertEq(model.borrowRate(KINK), left);
    }

    function testFuzz_borrowRate_matchesClosedForm(uint256 u) public view {
        u = bound(u, 0, 1e18);
        assertEq(model.borrowRate(u), _refBorrowRate(u), "mulDiv vs plain arithmetic");
    }

    function testFuzz_borrowRate_monotonicNonDecreasing(uint256 u1, uint256 u2) public view {
        u1 = bound(u1, 0, 1e18);
        u2 = bound(u2, 0, 1e18);
        if (u1 > u2) (u1, u2) = (u2, u1);
        assertLe(model.borrowRate(u1), model.borrowRate(u2), "more utilization never cheaper");
    }

    function testFuzz_borrowRate_neverBelowBase(uint256 u) public view {
        u = bound(u, 0, 1e18);
        assertGe(model.borrowRate(u), _aprToPerSecond(BASE_APR));
    }

    // ---- supply rate -------------------------------------------------------

    function test_supplyRate_atKink_isSixPointFourPercentApr() public view {
        // r_s = 10% · 0.8 · 0.8 = 6.4% APR (floor).
        uint256 s = model.supplyRate(KINK);
        assertEq(s, _refSupplyRate(KINK));
        uint256 ideal = _aprToPerSecond(64e15);
        uint256 tol = ideal / 10_000;
        assertTrue(s >= ideal - tol && s <= ideal + tol, "supply at kink must be ~6.4% APR");
    }

    function test_supplyRate_zeroAtZeroUtilization() public view {
        assertEq(model.supplyRate(0), 0);
    }

    function testFuzz_supplyRate_neverExceedsBorrowRate(uint256 u) public view {
        u = bound(u, 0, 1e18);
        assertLe(
            model.supplyRate(u),
            model.borrowRate(u),
            "suppliers cannot earn more than borrowers pay"
        );
    }

    function testFuzz_supplyRate_matchesClosedForm(uint256 u) public view {
        u = bound(u, 0, 1e18);
        assertEq(model.supplyRate(u), _refSupplyRate(u));
    }

    // ---- vault integration (real model) ------------------------------------

    function test_integration_oneYearAccrual_selfConsistent() public {
        _openBorrowPosition();
        uint256 rate = model.borrowRate(vault.utilization()); // ~7% APR per-second
        uint256 interestFactor = rate * SECONDS_PER_YEAR; // WAD
        uint256 expectedInterest = Math.mulDiv(5_000e6, interestFactor, WAD, Math.Rounding.Ceil);
        uint256 expectedReserve = Math.mulDiv(expectedInterest, RESERVE, BPS, Math.Rounding.Ceil);

        vm.warp(block.timestamp + SECONDS_PER_YEAR);
        vault.setInterestRateModel(model); // accrual trigger (Ch 20 governance no-op)

        assertEq(vault.totalDebt(), 5_000e6 + expectedInterest, "totalDebt must match model rate");
        assertEq(vault.reserve(), expectedReserve, "reserve must be RF-share of interest");
        assertEq(vault.borrowIndex(), WAD + interestFactor, "index must compound the model rate");
        assertEq(vault.debtOf(alice), vault.totalDebt(), "single borrower: debtOf == totalDebt");
        // Quantization dust vs the idealized 350e6 / 70e6 / 1.07e18:
        assertLt(350e6 - expectedInterest, 2_000, "within ~2,000 wei of idealized interest");
    }

    function test_integration_twoAccruals_compoundingBonus() public {
        _openBorrowPosition();
        uint256 rate = model.borrowRate(vault.utilization());
        uint256 oneShotLinear =
            5_000e6 + Math.mulDiv(5_000e6, rate * SECONDS_PER_YEAR, WAD, Math.Rounding.Ceil);

        vm.warp(block.timestamp + SECONDS_PER_YEAR / 2);
        vault.setInterestRateModel(model); // accrual #1
        uint256 midDebt = vault.totalDebt();
        vm.warp(block.timestamp + SECONDS_PER_YEAR / 2);
        vault.setInterestRateModel(model); // accrual #2

        uint256 finalDebt = vault.totalDebt();
        assertGt(
            finalDebt, oneShotLinear, "compounding (+ utilization drift) beats one-shot linear"
        );
        assertGt(finalDebt, midDebt, "debt must keep growing");
        assertLt(finalDebt, 5_400e6, "sanity: well below 8% APR equivalent");
        assertEq(vault.debtOf(alice), finalDebt, "single borrower: debtOf == totalDebt");
    }

    function test_integration_utilizationFeedsExactRate() public {
        _openBorrowPosition();
        assertEq(vault.utilization(), 5e17);
        assertEq(model.borrowRate(vault.utilization()), model.borrowRate(5e17));
        assertEq(model.borrowRate(vault.utilization()), _refBorrowRate(5e17));
    }

    function test_integration_swapModel_governance() public {
        InterestRateModel model2 = new InterestRateModel(
            _aprToPerSecond(5e16),
            _aprToPerSecond(MULT_APR),
            _aprToPerSecond(JUMP_APR),
            KINK,
            RESERVE
        );
        vault.setInterestRateModel(model2); // admin = test contract
        assertEq(address(vault.interestRateModel()), address(model2));
    }

    function test_integration_swapModel_unauthorizedReverts() public {
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE(); // hoisted before prank (Ch 14 #3)
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        vault.setInterestRateModel(model);
    }

    // ---- gas probes (loop-amplified min-deltas, warm-up first) -------------

    function test_gas_borrowRate_belowKink() public {
        emit log_named_uint(
            "borrowRate below kink (incl. warm external call)", _gasBorrowRate(5e17)
        );
    }

    function test_gas_borrowRate_aboveKink() public {
        emit log_named_uint(
            "borrowRate above kink (incl. warm external call)", _gasBorrowRate(95e16)
        );
    }
}
