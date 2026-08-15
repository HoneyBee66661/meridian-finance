// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MockERC20} from "./MeridianVaultMocks.sol";

/// @notice Ch 39 invariant handler — wraps MeridianVault's state-changing
///         surface (deposit / withdraw / borrow / repay) plus the governance
///         setter for the collateral factor, with bounded arguments.
/// @dev Ch 12 rules held: arguments `bound` to realistic domains; sequences
///      never revert (every revert edge pre-checked, so `[invariant]
///      fail_on_revert = true` holds); ghosts are single-writer public state
///      written only by the handler. The handler executes user ops via
///      `vm.prank` over a FIXED 3-user set (u0/u1/u2) — the invariant suite
///      sums that complete set. The oracle price is FIXED and the rate model
///      is zero (Ch 39 audit scope: the lending state machine under a frozen
///      market), which is what makes I1 ("no self-inflicted liquidation")
///      provable: with no interest drift, HF after borrow is >= LT/CF > 1 and
///      withdraw enforces HF >= 1, so no user action can cross the line.
contract MeridianVaultHandler is Test {
    using Math for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    MeridianVault public vault;
    MockERC20 public collateral;
    MockERC20 public debt;
    address public user0;
    address public user1;
    address public user2;

    /// @dev Ghost: total collateral in the system (deposited - withdrawn).
    ///      Single writer (this handler); invariants only read it.
    uint256 public ghostCollateral;

    constructor(
        MeridianVault _vault,
        MockERC20 _collateral,
        MockERC20 _debt,
        address _user0,
        address _user1,
        address _user2
    ) {
        vault = _vault;
        collateral = _collateral;
        debt = _debt;
        user0 = _user0;
        user1 = _user1;
        user2 = _user2;
        // Approval set once per user (Ch 14 finding #3 house rule).
        for (uint256 i = 0; i < 3; ++i) {
            address u = _actor(i);
            vm.startPrank(u);
            collateral.approve(address(vault), type(uint256).max);
            debt.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---- Handler ops (all revert edges pre-checked) -------------------------

    function deposit(uint256 actor, uint256 amount) external {
        address u = _actor(actor);
        amount = bound(amount, 1, 1e24);
        collateral.mint(u, amount);
        vm.prank(u);
        vault.depositCollateral(amount);
        ghostCollateral += amount;
    }

    function withdraw(uint256 actor, uint256 amount) external {
        address u = _actor(actor);
        uint256 coll = vault.collateralOf(u);
        if (coll == 0) return; // nothing to withdraw — skip (bound needs min <= max)
        amount = bound(amount, 1, coll);
        // HF-after pre-check, mirroring the vault's own math (floor):
        // a withdraw that would push HF below 1 reverts in the contract.
        if (_hfAfter(u, coll - amount) < WAD) return;
        vm.prank(u);
        vault.withdrawCollateral(amount);
        ghostCollateral -= amount;
    }

    function borrow(uint256 actor, uint256 amount) external {
        address u = _actor(actor);
        uint256 debtAmt = vault.debtOf(u);
        uint256 capacity = vault.borrowCapacity(u);
        if (capacity <= debtAmt) return; // no headroom — skip
        amount = bound(amount, 1, capacity - debtAmt);
        uint256 idle = _idleCash();
        if (amount > idle) amount = idle; // clamp to lendable cash
        if (amount == 0) return;
        vm.prank(u);
        vault.borrow(amount);
    }

    function repay(uint256 actor, uint256 amount) external {
        address u = _actor(actor);
        uint256 debtAmt = vault.debtOf(u);
        if (debtAmt == 0) return; // nothing to repay — skip
        amount = bound(amount, 1, debtAmt);
        debt.mint(u, amount); // user needs the debt token to pay
        vm.prank(u);
        vault.repay(amount);
    }

    /// @dev Governance op: raises/lowers the collateral factor, bounded to the
    ///      constructor's own validity domain (LT * BPS > CF * WAD — the
    ///      safety buffer must stay strictly positive). The bound mirrors the
    ///      documented rule so sequences never revert; the contract itself
    ///      enforces the same rule since the Ch 39 fix.
    function setCollateralFactor(uint256 cf) external {
        uint256 maxCf = vault.liquidationThreshold() * BPS / WAD; // CF < LT (strict)
        if (maxCf <= 1) return;
        cf = bound(cf, 1, maxCf - 1);
        vault.setCollateralFactor(uint64(cf));
    }

    // ---- Internal helpers -----------------------------------------------------

    function _actor(uint256 i) internal view returns (address) {
        if (i == 0) return user0;
        if (i == 1) return user1;
        return user2;
    }

    /// @dev Mirror of MeridianVault._healthFactor for the withdraw pre-check:
    ///      HF = collateralValue * LT / debtValue, WAD, floored (conservative).
    function _hfAfter(address u, uint256 collAfter) internal view returns (uint256) {
        uint256 debtAmount = vault.debtOf(u);
        if (debtAmount == 0) return type(uint256).max;
        if (collAfter == 0) return 0;
        uint256 collValue =
            collAfter.mulDiv(_price(address(collateral)), 10 ** collateral.decimals());
        uint256 debtValue = debtAmount.mulDiv(_price(address(debt)), 10 ** debt.decimals());
        return collValue.mulDiv(vault.liquidationThreshold(), WAD).mulDiv(WAD, debtValue);
    }

    function _price(address asset) internal view returns (uint256) {
        return vault.oracle().getPrice(asset);
    }

    /// @dev Mirror of MeridianVault._idleCash: lendable debt-token balance,
    ///      saturating at zero (the all-borrowed case).
    function _idleCash() internal view returns (uint256) {
        uint256 balance = debt.balanceOf(address(vault));
        uint256 reserve = vault.reserve();
        return balance > reserve ? balance - reserve : 0;
    }
}
