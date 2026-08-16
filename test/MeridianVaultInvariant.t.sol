// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MeridianVaultHandler} from "./MeridianVaultHandler.sol";
import {MockERC20, FixedRateInterestRateModel, MockOracle} from "./MeridianVaultMocks.sol";

/// @notice Ch 39 invariant suite for `MeridianVault` v1 (isolated lending
///         market core) — the full-system audit's falsification campaign over
///         the lending state machine. Frozen market (fixed oracle price, zero
///         interest model) so the state machine's own guarantees are provable.
/// @dev Four invariants:
///      I1 — no self-inflicted liquidation: no user with debt is ever
///           liquidatable. Holds because borrow enforces debt <= CF*colValue
///           (so HF >= LT/CF > 1) and withdraw enforces HF >= 1; with zero
///           interest there is no drift to cross the line. This is the
///           v1 design guarantee Ch 20 states and Ch 39's audit pins.
///           NON-VACUOUS (Ch 39 review B2): the handler's pre-checks mirror
///           the vault's own checks (fail_on_revert compliance). If the
///           vault allowed more than the mirror predicts — a vault
///           correctness bug, e.g. a missing capacity or HF check — the
///           handler would NOT skip the call and a user would reach
///           HF < 1; I1 catches that. I1 tests the vault, not the handler.
///      I2 — collateral conservation: ghost == sum(collateralOf) over the
///           fixed 3-user set.
///      I3 — debt books exactly: sum(debtOf) == totalDebt. Snapshot folding
///           (Compound-style principal/index) makes the equality EXACT under
///           a zero rate model: with a constant borrow index,
///           debtOf(u) = principal(u) exactly, no rounding at any step.
///           Rounding dust appears only when the index compounds
///           (non-zero rate model), where per-user debt is derived via
///           fixed-point division.
///      I4 — safety buffer strictly positive: LT * BPS > CF * WAD. The
///           constructor enforces it and (since the Ch 39 fix) so do BOTH
///           setters — this pins the rule across the whole governance surface.
///      I5 — oracle-seam consistency: the vault's public healthFactor must
///           equal the health factor recomputed independently from the
///           oracle's current prices. Pins the vault's HF math against the
///           oracle it consumes (the R=1 trust anchor, Ch 22): a vault that
///           cached prices, mis-scaled decimals, or diverged in rounding
///           would trip this. Under the frozen market both sides use the
///           same floor mulDiv, so the equality is exact.
///      Handler bounds the CF setter to the constructor's own validity domain,
///      so sequences stay valid under fail_on_revert; the audit FINDING that
///      motivated the fix is proven by the dedicated unit test in
///      MeridianVaultTest (test_setCollateralFactor_atOrAboveLiquidationThreshold_reverts),
///      not by letting the handler hit a revert edge.
contract MeridianVaultInvariant is Test {
    using Math for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    MeridianVault internal vault;
    MockERC20 internal eth;
    MockERC20 internal usdc;
    MockOracle internal oracle;
    FixedRateInterestRateModel internal zeroModel;
    MeridianVaultHandler internal handler;

    address[3] internal users;

    function setUp() public {
        eth = new MockERC20("Mock ETH", "mETH", 18);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        oracle = new MockOracle();
        oracle.setPrice(address(eth), 2000e8); // 8-dec feed style, fixed
        oracle.setPrice(address(usdc), 1e8);
        zeroModel = new FixedRateInterestRateModel(0, 8e17); // frozen market
        vault = new MeridianVault(
            address(eth),
            address(usdc),
            oracle,
            zeroModel,
            uint64(7500), // 75% collateral factor
            0.8e18, // 80% liquidation threshold
            uint64(1000), // 10% liquidation incentive
            uint64(2000) // 20% reserve factor
        );
        handler = new MeridianVaultHandler(
            vault, eth, usdc, makeAddr("vaultUser0"), makeAddr("vaultUser1"), makeAddr("vaultUser2")
        );
        // The test contract is the constructor admin; hand governance to the
        // handler so its setCollateralFactor op is authorized.
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(handler));
        // Seed the debt pool (the v1 stand-in for the Ch 23 supply side) so
        // borrows have cash to draw.
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.supplyDebtLiquidity(1_000_000e6);

        users[0] = handler.user0();
        users[1] = handler.user1();
        users[2] = handler.user2();

        targetContract(address(handler));
    }

    /// @dev I1 — the v1 design guarantee: with a frozen market, no user action
    ///      can push a position over the liquidation line.
    function invariant_I1_noSelfInflictedLiquidation() public view {
        for (uint256 i = 0; i < 3; ++i) {
            address u = users[i];
            if (vault.debtOf(u) > 0) {
                assertFalse(vault.isLiquidatable(u), "user with debt became liquidatable");
            }
        }
    }

    /// @dev I2 — collateral conservation across the complete holder set.
    function invariant_I2_collateralConserved() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; ++i) {
            sum += vault.collateralOf(users[i]);
        }
        assertEq(handler.ghostCollateral(), sum, "ghost/sum collateral mismatch");
    }

    /// @dev I3 — the books balance exactly: sum of per-user debt == totalDebt.
    function invariant_I3_debtBooksExactly() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; ++i) {
            sum += vault.debtOf(users[i]);
        }
        assertEq(sum, vault.totalDebt(), "sum(debtOf) != totalDebt");
    }

    /// @dev I4 — the safety buffer stays strictly positive on the WHOLE
    ///      governance surface (constructor + both setters).
    function invariant_I4_safetyBufferPositive() public view {
        assertGt(
            vault.liquidationThreshold() * BPS,
            uint256(vault.collateralFactorBps()) * WAD,
            "LT * BPS <= CF * WAD - safety buffer erased"
        );
    }

    /// @dev I5 — oracle-seam consistency (Ch 39 review C1): the vault's
    ///      public healthFactor must equal the value recomputed here from
    ///      the oracle's CURRENT prices and the vault's public parameters.
    ///      This is the one invariant that crosses the vault-oracle seam
    ///      (the R=1 trust anchor, Ch 22): a vault that cached prices at
    ///      deposit time, mis-scaled decimals, or diverged in rounding
    ///      from the independent recompute would trip it. Under the frozen
    ///      market both sides are deterministic floor mulDiv, so the
    ///      equality is exact.
    function invariant_I5_oracleSeamConsistency() public view {
        uint256 collPrice = vault.oracle().getPrice(address(eth));
        uint256 debtPrice = vault.oracle().getPrice(address(usdc));
        uint256 lt = vault.liquidationThreshold();
        for (uint256 i = 0; i < 3; ++i) {
            address u = users[i];
            uint256 debt = vault.debtOf(u);
            if (debt == 0) continue;
            uint256 collValue = vault.collateralOf(u).mulDiv(collPrice, 10 ** eth.decimals());
            uint256 debtValue = debt.mulDiv(debtPrice, 10 ** usdc.decimals());
            uint256 expectedHF = collValue.mulDiv(lt, WAD).mulDiv(WAD, debtValue);
            assertEq(
                vault.healthFactor(u),
                expectedHF,
                "oracle-seam: vault HF != independent oracle recompute"
            );
        }
    }
}
