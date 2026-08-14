// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MiniToken} from "../src/MiniToken.sol";
import {Mini4626} from "../src/Mini4626.sol";
import {IVault4626Lab} from "../src/IVault4626Lab.sol";
import {Naive4626Lab, Virtual4626Lab} from "../src/Vault4626Lab.sol";

/// @notice Ch 16 lab tests — share math, the inflation/donation attack, and
///         the OZ virtual-offset mitigation, with pinned rounding directions
///         and log-only gas probes.
/// @dev Methodology per locked conventions: parameter-exact vm.expectRevert
///      (low-level revert-data shape for parameterized errors); non-privileged
///      negative test for the owner-gated path; `bound` over vm.assume; warm-up
///      calls before gasleft() deltas; gas probes log-only (no assertions in
///      fuzz/invariant code). The canonical attack numbers are 1 wei seed /
///      1e21 donation / 1e21 victim deposit — chosen so the naive-vs-virtual
///      comparison is exact.
contract Vault4626LabTest is Test {
    MiniToken internal token;
    Naive4626Lab internal naive;
    Virtual4626Lab internal virtualVault;

    address internal alice;
    address internal bob;

    /// @dev The canonical attack amounts: attacker seeds 1 wei, donates 1e21,
    ///      victim deposits 1e21.
    uint256 internal constant DONATION = 1e21;
    uint256 internal constant VICTIM_DEPOSIT = 1e21;

    function setUp() public {
        token = new MiniToken();
        naive = new Naive4626Lab(IERC20(address(token)));
        virtualVault = new Virtual4626Lab(IERC20(address(token)));
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        token.mint(address(this), type(uint128).max);
        token.approve(address(naive), type(uint256).max);
        token.approve(address(virtualVault), type(uint256).max);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    /// @dev Seed a vault 1:1 from the test contract (funds in setUp).
    function _seed(IVault4626Lab vault, uint256 amount) internal returns (uint256 shares) {
        shares = vault.deposit(amount, address(this));
    }

    /// @dev Run the canonical attack sequence against `vault`. Returns the
    ///      victim's minted shares and the attacker's redemption proceeds.
    function _runAttack(IVault4626Lab vault) internal returns (uint256 victimShares, uint256 attackerProceeds) {
        // t1: attacker seeds 1 wei -> 1 share (genesis 1:1 in both vaults)
        token.mint(alice, 1 + DONATION + VICTIM_DEPOSIT);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1, alice);
        // t2: donation via a PLAIN TRANSFER — no vault function involved
        token.transfer(address(vault), DONATION);
        vm.stopPrank();

        // t3: victim deposits at the inflated price
        token.mint(bob, VICTIM_DEPOSIT);
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        victimShares = vault.deposit(VICTIM_DEPOSIT, bob);
        vm.stopPrank();

        // t4: attacker redeems their single share
        vm.prank(alice);
        attackerProceeds = vault.redeem(1, alice, alice);
    }

    // ── share math: rounding directions (pinned exact numbers) ─────────────

    /// @dev A = 11, S = 10 (seed 10, donate 1). deposit floors: 10 assets mint
    ///      9 shares (10*11/12 = 9.167). The vault keeps the dust.
    function test_shareMath_deposit_roundsSharesDown() public {
        _seed(virtualVault, 10);
        token.transfer(address(virtualVault), 1);
        assertEq(virtualVault.previewDeposit(10), 9);
        assertEq(virtualVault.deposit(10, address(this)), 9);
    }

    /// @dev mint ceil: to mint 9 shares you pay 10 assets (9*12/11 = 9.82).
    function test_shareMath_mint_roundsAssetsUp() public {
        _seed(virtualVault, 10);
        token.transfer(address(virtualVault), 1);
        assertEq(virtualVault.previewMint(9), 10);
    }

    /// @dev withdraw ceil: to pull 10 assets you burn 10 shares.
    function test_shareMath_withdraw_roundsSharesUp() public {
        _seed(virtualVault, 10);
        token.transfer(address(virtualVault), 1);
        assertEq(virtualVault.previewWithdraw(10), 10);
    }

    /// @dev redeem floor: 9 shares pay out 9 assets (9*12/11 floor) — while
    ///      minting those same 9 shares costs 10 assets (ceil). Same pair,
    ///      opposite edges: the vault rounds its own way on both sides.
    function test_shareMath_redeem_roundsAssetsDown() public {
        _seed(virtualVault, 10);
        token.transfer(address(virtualVault), 1);
        assertEq(virtualVault.previewRedeem(9), 9);
        assertEq(virtualVault.previewMint(9), 10);
    }

    /// @dev The solvency argument in one line: all shares' implied value is
    ///      never more than what the vault holds. Each of the four entry
    ///      points rounds the vault's way, so dust accrues to the vault.
    function test_solvency_convertToAssetsOfTotalSupply_leTotalAssets() public {
        _seed(virtualVault, 1_000);
        token.transfer(address(virtualVault), 1);
        assertLe(virtualVault.convertToAssets(virtualVault.totalSupply()), virtualVault.totalAssets());

        // after a fresh deposit at the skewed price, still solvent
        virtualVault.deposit(1_000, address(this));
        assertLe(virtualVault.convertToAssets(virtualVault.totalSupply()), virtualVault.totalAssets());
    }

    /// @dev Floor/floor round-trips never mint value (the Ch 12 invariant,
    ///      now on the full four-direction surface).
    function testFuzz_convertRoundTrip_neverGains(uint256 x) public {
        _seed(naive, 1_000);
        _seed(virtualVault, 1_000);
        token.transfer(address(naive), 1);
        token.transfer(address(virtualVault), 1); // A=1001, S=1000 skew

        x = bound(x, 0, type(uint96).max);
        assertLe(naive.convertToAssets(naive.convertToShares(x)), x);
        assertLe(naive.convertToShares(naive.convertToAssets(x)), x);
        assertLe(virtualVault.convertToAssets(virtualVault.convertToShares(x)), x);
        assertLe(virtualVault.convertToShares(virtualVault.convertToAssets(x)), x);
    }

    // ── the inflation/donation attack ──────────────────────────────────────

    /// @dev Naive vault: the victim's 1e21 deposit mints ZERO shares and the
    ///      attacker redeems the entire pot. Canonical t11s numbers.
    function test_inflationAttack_naive_victimDepositCaptured() public {
        (uint256 victimShares, ) = _runAttack(naive);
        assertEq(victimShares, 0); // floor(1e21 * 1 / (1e21+1)) == 0
        assertEq(naive.balanceOf(bob), 0);
    }

    /// @dev Naive vault: attacker proceeds = whole pot (2e21+1) vs their total
    ///      in (1e21+1) — profit == the victim's deposit, exactly.
    function test_inflationAttack_naive_attackerProfitsVictimLoss() public {
        (uint256 victimShares, uint256 attackerProceeds) = _runAttack(naive);
        assertEq(attackerProceeds, 2 * VICTIM_DEPOSIT + 1);
        // profit = proceeds - (1 wei seed + donation) == victim deposit
        assertEq(attackerProceeds - (1 + DONATION), VICTIM_DEPOSIT);

        // the victim's (zero) shares are worthless
        assertEq(naive.convertToAssets(victimShares), 0);
    }

    /// @dev Virtual vault, SAME sequence: the victim mints 1 share (not 0) and
    ///      the attacker exits with LESS than they contributed — a net loss.
    ///      The value is absorbed by the virtual shares, not captured (the
    ///      OZ "non-profitable" claim, exact numbers).
    function test_inflationAttack_virtual_attackerLoses() public {
        (uint256 victimShares, uint256 attackerProceeds) = _runAttack(virtualVault);
        assertEq(victimShares, 1); // floor(1e21 * 2 / (1e21+2)) == 1
        // proceeds = 1 share * (A+1)/(S+1) = (2e21+2)/3 — a strict loss vs
        // the 1e21+1 contributed (seed 1 wei + 1e21 donation).
        assertEq(attackerProceeds, (2 * VICTIM_DEPOSIT + 2) / 3);
        assertLt(attackerProceeds, 1 + DONATION);
    }

    /// @dev Defense-in-depth: a non-trivial initial deposit (OZ CAUTION's
    ///      recommendation) makes the attack a large loss AND the victim
    ///      recovers ~their full deposit.
    function test_inflationAttack_virtual_withSeedDeposit_victimRecovers() public {
        // protocol seeds 1e18: now the attacker's 1 wei is diluted
        _seed(virtualVault, 1e18);

        uint256 attackerIn = 1 + DONATION;
        token.mint(alice, attackerIn);
        vm.startPrank(alice);
        token.approve(address(virtualVault), type(uint256).max);
        virtualVault.deposit(1, alice);
        token.transfer(address(virtualVault), DONATION);
        vm.stopPrank();

        token.mint(bob, VICTIM_DEPOSIT);
        vm.startPrank(bob);
        token.approve(address(virtualVault), type(uint256).max);
        uint256 victimShares = virtualVault.deposit(VICTIM_DEPOSIT, bob);
        vm.stopPrank();

        vm.prank(alice);
        uint256 attackerProceeds = virtualVault.redeem(1, alice, alice);
        assertLt(attackerProceeds, attackerIn); // the attack is a loss

        vm.prank(bob);
        uint256 victimProceeds = virtualVault.redeem(victimShares, bob, bob);
        assertApproxEqRel(victimProceeds, VICTIM_DEPOSIT, 1e16); // within 1%: ~full recovery
    }

    /// @dev A donation needs NO vault function: totalAssets() reads the balance,
    ///      so a plain transfer inflates the price.
    function test_donation_directTransfer_inflatesPrice() public {
        _seed(naive, 1_000);
        assertEq(naive.previewDeposit(1_000), 1_000); // price 1
        token.transfer(address(naive), 500);
        assertLt(naive.previewDeposit(1_000), 1_000); // price > 1 now
    }

    // ── preview vs convert ─────────────────────────────────────────────────

    /// @dev previewDeposit is a snapshot; between the read and the execution a
    ///      donation can land (the MEV/atomic shape) and the ACTUAL shares are
    ///      far fewer. preview is display, not a guarantee.
    function test_preview_donationBetweenPreviewAndDeposit_changesShares() public {
        _seed(naive, 1_000);
        uint256 previewed = naive.previewDeposit(100_000);
        assertEq(previewed, 100_000); // price 1

        token.transfer(address(naive), 1_000_000); // price -> 1001
        uint256 actual = naive.deposit(100_000, address(this));
        assertEq(actual, 99); // floor(100_000 * 1000 / 1_001_000)
        assertLt(actual, previewed);
    }

    // ── max* surface ───────────────────────────────────────────────────────

    function test_maxDeposit_defaultUnlimited() public {
        assertEq(naive.maxDeposit(address(this)), type(uint256).max);
        assertEq(virtualVault.maxDeposit(address(this)), type(uint256).max);
        assertEq(naive.maxMint(address(this)), type(uint256).max);
    }

    function test_maxRedeem_maxWithdraw_derived() public {
        _seed(virtualVault, 1_000);
        assertEq(virtualVault.maxRedeem(address(this)), 1_000);
        assertEq(virtualVault.maxWithdraw(address(this)), virtualVault.previewRedeem(1_000));
    }

    // ── access control (non-privileged negative test) ──────────────────────

    /// @dev Owner-only lab surface: a non-owner cannot withdraw the owner's
    ///      position. Parameter-exact revert (Ch 10 convention).
    function test_withdraw_notOwner_reverts() public {
        token.mint(alice, 1_000);
        vm.startPrank(alice);
        token.approve(address(virtualVault), type(uint256).max);
        virtualVault.deposit(1_000, alice);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IVault4626Lab.UnauthorizedCaller.selector, bob, alice));
        vm.prank(bob);
        virtualVault.withdraw(100, bob, alice);
    }

    // ── solvency under honest flows ────────────────────────────────────────

    /// @dev Deposit-only sequences (no donations): every holder's shares are
    ///      worth at most their deposit, and all redemptions are covered by
    ///      totalAssets. The vault is a no-arbitrage accounting ledger.
    function testFuzz_vaultSolvency_allShareholdersCovered(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1e6, 1e18);
        b = bound(b, 1e6, 1e18);
        c = bound(c, 1e6, 1e18);

        address[3] memory users = [alice, bob, makeAddr("carol")];
        uint256[3] memory deposits = [a, b, c];

        for (uint256 i = 0; i < 3; i++) {
            token.mint(users[i], deposits[i]);
            vm.startPrank(users[i]);
            token.approve(address(virtualVault), type(uint256).max);
            virtualVault.deposit(deposits[i], users[i]);
            vm.stopPrank();
        }

        uint256 totalValue;
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = virtualVault.balanceOf(users[i]);
            uint256 value = virtualVault.convertToAssets(shares);
            assertLe(value, deposits[i]); // never gain on a deposit
            totalValue += value;
        }
        assertLe(totalValue, virtualVault.totalAssets()); // redemptions covered
    }

    // ── precision: mulDiv vs naive multiply ────────────────────────────────

    /// @dev Full-precision Math.mulDiv handles huge operands; the Ch 12 naive
    ///      `assets * supply / tracked` is an overflow bomb at scale (Panic
    ///      0x11). Production share math MUST be mulDiv (Ch 4 canon).
    function test_mulDiv_fullPrecision_handlesLargeInputs() public {
        _seed(virtualVault, 1_000);
        token.transfer(address(virtualVault), 1);
        assertGt(virtualVault.convertToShares(2 ** 250), 0); // mulDiv: fine
    }

    function test_naiveMultiply_vault_overflows_Panic0x11() public {
        // Mini4626 (Ch 12) uses the naive `assets * supply / tracked` form.
        Mini4626 m = new Mini4626(token);
        token.approve(address(m), type(uint256).max);
        m.deposit(1_000);
        token.transfer(address(m), 1);

        vm.expectRevert(stdError.arithmeticError); // Panic 0x11
        m.convertToShares(2 ** 250);
    }

    // ── gas probes (log-only, loop-amplified min-deltas, warm-up first) ────

    /// @dev The virtual offset is ~free: same mulDiv, +1 constant operands.
    ///      Pins the chapter's "mitigation has no gas tax" claim.
    function test_gas_previewDeposit_naiveVsVirtual() public {
        _seed(naive, 1_000);
        _seed(virtualVault, 1_000);
        token.transfer(address(naive), 1);
        token.transfer(address(virtualVault), 1);
        naive.previewDeposit(1e18); // warm-up
        virtualVault.previewDeposit(1e18);

        uint256 minNaive = type(uint256).max;
        uint256 minVirtual = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                naive.previewDeposit(1e18);
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < minNaive) minNaive = perCall;

            before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                virtualVault.previewDeposit(1e18);
            }
            perCall = (before - gasleft()) / 10;
            if (perCall < minVirtual) minVirtual = perCall;
        }
        console2.log("naive previewDeposit (per call):", minNaive);
        console2.log("virtual previewDeposit (per call):", minVirtual);
        uint256 diff = minVirtual > minNaive ? minVirtual - minNaive : minNaive - minVirtual;
        assertLt(diff, 100); // expect ~0-20 gas; the offset is not a tax
    }

    function test_gas_deposit_virtual() public {
        _seed(virtualVault, 1e6);
        token.mint(alice, 1e24);
        vm.startPrank(alice);
        token.approve(address(virtualVault), type(uint256).max);
        virtualVault.deposit(1, alice); // warm-up
        vm.stopPrank();

        uint256 min = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                vm.prank(alice);
                virtualVault.deposit(1, alice);
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < min) min = perCall;
        }
        console2.log("virtual deposit (per call):", min);
    }

    function test_gas_redeem_virtual() public {
        _seed(virtualVault, 1e6);
        token.mint(alice, 1e24);
        vm.startPrank(alice);
        token.approve(address(virtualVault), type(uint256).max);
        virtualVault.deposit(1_000, alice);
        vm.stopPrank();

        uint256 min = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                vm.prank(alice);
                virtualVault.redeem(1, alice, alice);
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < min) min = perCall;
        }
        console2.log("virtual redeem (per call):", min);
    }
}
