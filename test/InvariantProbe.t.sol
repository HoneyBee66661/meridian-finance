// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Mini4626} from "../src/Mini4626.sol";
import {MiniToken} from "../src/MiniToken.sol";
import {Mini4626Handler} from "./Mini4626Handler.sol";

/// @notice Ch 12 invariant tests — the ERC4626-style invariant set against
///         Mini4626 THROUGH the handler.
/// @dev Target configuration: ONLY the handler's deposit/redeem selectors are
///      in the target set (donate deliberately excluded) — the green suite
///      proves the honest accounting path. The chapter's one-off
///      ZzDonationBreaks experiment adds donate.selector and observes
///      invariant_noFreeAssets flip red: the detector works (verified in-run,
///      variant removed afterwards).
contract InvariantProbeTest is Test {
    MiniToken internal token;
    Mini4626 internal vault;
    Mini4626Handler internal handler;

    function setUp() public {
        token = new MiniToken();
        vault = new Mini4626(token);
        handler = new Mini4626Handler(vault, token);

        // Seed 1:1 THROUGH the handler so ghosts track the genesis state
        // (deposit-only sequences keep A == S == price 1 — the rounding
        // properties get real skew in testFuzz_conversionsNeverGain_atSkewedPrice).
        handler.deposit(1_000_000 ether);

        // Target the handler only, and only deposit/redeem. Exclude this test
        // contract so the runner never sequences its own test functions.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = Mini4626Handler.deposit.selector;
        selectors[1] = Mini4626Handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        excludeContract(address(this));
    }

    /// @dev Every asset is accounted for: tracked == deposits + donations.
    ///      Holds even when donate IS targeted (the handler records it).
    function invariant_conservation() public view {
        assertEq(vault.totalAssets_(), handler.ghost_totalDeposited() + handler.ghost_donated());
    }

    /// @dev No asset enters without a share mint. THE inflation-attack
    ///      detector: with donate out of the target set this must stay green;
    ///      the moment a donation lands, totalAssets_ exceeds the deposit
    ///      ledger and this flips red.
    function invariant_noFreeAssets() public view {
        assertEq(vault.totalAssets_(), handler.ghost_totalDeposited());
    }

    /// @dev Floor/floor conversions never mint value (rounding-direction pin).
    ///      Trivially tight at price 1; real rounding is exercised at skewed
    ///      prices in testFuzz_conversionsNeverGain_atSkewedPrice.
    function invariant_conversionsNeverGain() public view {
        uint256 x = 123_456_789;
        assertLe(vault.convertToAssets(vault.convertToShares(x)), x);
        assertLe(vault.convertToShares(vault.convertToAssets(x)), x);
    }

    /// @dev Conversion is monotonic: no arbitrage surface in the price fn.
    function invariant_monotonicShares() public view {
        assertLe(vault.convertToShares(1_000), vault.convertToShares(2_000));
    }

    /// @dev The "conversions never gain" property under REAL rounding: skew the
    ///      price (donation) so floor/floor actually loses wei, then fuzz x.
    ///      Round-trip loss is bounded by ~⌊A/S⌋+1 wei (Ch 12 math); the
    ///      property under test is the DIRECTION — conversions never mint value.
    function testFuzz_conversionsNeverGain_atSkewedPrice(uint256 x) public {
        // Fresh vault skewed to A/S ≈ 1,001 via donation (directed test).
        token = new MiniToken();
        vault = new Mini4626(token);
        token.mint(address(this), 1_000_000);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000);
        token.mint(address(this), 1_000_000_000);
        vault.donate(1_000_000_000); // A = 1,001,000,000, S = 1,000,000

        x = bound(x, 0, type(uint96).max);
        assertLe(vault.convertToAssets(vault.convertToShares(x)), x);
        assertLe(vault.convertToShares(vault.convertToAssets(x)), x);
    }

    /// @dev The t11s inflation attack, deterministically: the attacker is the
    ///      EARLY depositor + donor; the victim deposits at the inflated price,
    ///      mints dust, and the attacker redeems the captured value. This is
    ///      what invariant_noFreeAssets detects as a CONDITION (free assets)
    ///      rather than this specific victim.
    ///      Uses a FRESH vault: the attack needs donation >> existing supply —
    ///      against the setUp seed (1e24) the donation is diluted to zero
    ///      profit (observed in-run; the invariant detector is seed-independent
    ///      because it tracks the ghost ledger).
    function test_donationAttack_stealsFromLateDepositor() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        // Fresh, young vault — the classic attack's arena.
        token = new MiniToken();
        vault = new Mini4626(token);

        // Attacker: early deposit (holds pre-inflation shares) + huge donation.
        token.mint(attacker, 1_000);
        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1_000);
        token.mint(attacker, 1_000_000_000);
        vault.donate(1_000_000_000); // share price 1 -> ~1,001,000
        vm.stopPrank();

        // Victim deposits at the inflated price: 100M in, dust shares out.
        token.mint(victim, 100_000_000);
        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);
        uint256 victimShares = vault.deposit(100_000_000);
        vm.stopPrank();

        // The victim's shares are worth less than they paid, and full
        // redemption cannot recover the deposit — the value was captured.
        assertLt(vault.convertToAssets(victimShares), 100_000_000);
        vm.prank(victim);
        uint256 victimProceeds = vault.redeem(victimShares);
        assertLt(victimProceeds, 100_000_000);

        // The attacker redeems at the inflated price: proceeds exceed the
        // total contribution (deposit + donation) — profit = victim's loss.
        vm.prank(attacker);
        uint256 attackerProceeds = vault.redeem(1_000);
        assertGt(attackerProceeds, 1_000 + 1_000_000_000);
    }
}
