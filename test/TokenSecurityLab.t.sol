// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {ITokenSecurityLab} from "../src/ITokenSecurityLab.sol";
import {
    LabToken,
    LabTokenWithHelpers,
    FeeOnTransferToken,
    NaiveFeeIntegrator,
    DeltaFeeIntegrator,
    RebasingToken,
    NaiveRebaseVault,
    FractionalRebaseVault
} from "../src/TokenSecurityLab.sol";

/// @notice Ch 17 Token Security Patterns lab tests — (a) the approval race and
///         its fixes, (b) fee-on-transfer tokens, (c) rebasing tokens. The
///         EIP-777-style reentrancy demo lives in Reentrancy777Lab.t.sol.
/// @dev Conventions held: parameter-exact `vm.expectRevert` (Ch 10); gas
///      probes log-only, loop-amplified min-deltas, warm-up first (Ch 8/16);
///      cheatcodes confined to test/ (Ch 10); the permit fix is demonstrated
///      against MER (Ch 14's protocol token) with the Ch 14 signing helpers.
contract TokenSecurityLabTest is Test {
    /// @dev Fixed key so permit signatures are reproducible (Ch 14 pattern).
    uint256 internal constant ALICE_KEY = 0xA11CE;

    uint256 internal constant INITIAL_SUPPLY = 10_000_000e18;
    uint256 internal constant ALICE_FUNDING = 1_000e18;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    LabToken internal lab;
    LabTokenWithHelpers internal labh;
    FeeOnTransferToken internal fee;
    RebasingToken internal reb;
    NaiveFeeIntegrator internal naiveFee;
    DeltaFeeIntegrator internal deltaFee;
    NaiveRebaseVault internal naiveRebase;
    FractionalRebaseVault internal fracRebase;

    MeridianToken internal mer;

    address internal owner;
    address internal minter;
    address internal treasury;
    address internal alice; // vm.addr(ALICE_KEY) — the permit signer
    address internal bob;
    address internal mallory; // the front-runner in the permit-griefing test
    address internal eoa; // hook-free recipient for the EOA probe

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        treasury = makeAddr("treasury");
        alice = vm.addr(ALICE_KEY);
        bob = makeAddr("bob");
        mallory = makeAddr("mallory");
        eoa = makeAddr("eoa");

        lab = new LabToken();
        labh = new LabTokenWithHelpers();
        fee = new FeeOnTransferToken();
        reb = new RebasingToken();
        naiveFee = new NaiveFeeIntegrator(IERC20(address(fee)));
        deltaFee = new DeltaFeeIntegrator(IERC20(address(fee)));
        naiveRebase = new NaiveRebaseVault(reb);
        fracRebase = new FractionalRebaseVault(reb);

        mer = new MeridianToken(owner, minter, treasury, INITIAL_SUPPLY);
        vm.prank(treasury);
        mer.transfer(alice, ALICE_FUNDING);
    }

    // ── (a) the approval race ───────────────────────────────────────────────

    /// @dev The canonical EIP-20 race, re-derived on a lab token: a reduce
    ///      intent front-run by the spender captures BOTH the old and the new
    ///      allowance (reach 150 vs intended 50).
    function test_approvalRace_staleApprove_grantsMoreThanIntended() public {
        lab.mint(alice, 1_000);
        vm.startPrank(alice);
        lab.approve(bob, 100);
        vm.stopPrank();

        vm.prank(bob); // front-run: spend the old allowance first
        lab.transferFrom(alice, bob, 100);

        vm.prank(alice); // stale intent lands after the front-run
        lab.approve(bob, 50);

        vm.prank(bob); // the residual allowance is still spendable
        lab.transferFrom(alice, bob, 50);

        assertEq(lab.balanceOf(bob), 150); // 150 extracted vs 50 intended
        assertEq(lab.allowance(alice, bob), 0);
    }

    /// @dev The relative-helper fix (OZ v4, removed in v5): after the spender
    ///      drains the old 100, `decreaseAllowance(50)` REVERTS instead of
    ///      minting a fresh 50 on top. Reach is bounded by the old value.
    function test_approvalRace_decreaseAllowance_boundsReach() public {
        labh.mint(alice, 1_000);
        vm.startPrank(alice);
        labh.approve(bob, 100);
        vm.stopPrank();

        vm.prank(bob); // front-run: spend the old allowance
        labh.transferFrom(alice, bob, 100);

        // The atomic reduce cannot go below zero — no fresh allowance appears.
        vm.expectRevert(abi.encodeWithSelector(ITokenSecurityLab.InsufficientBalance.selector, 0, 50));
        vm.prank(alice);
        labh.decreaseAllowance(bob, 50);

        assertEq(labh.balanceOf(bob), 100); // 100, NOT 150
        assertEq(labh.allowance(alice, bob), 0);
    }

    /// @dev The relative helper done cleanly: one atomic tx lands at exactly
    ///      the reduced value, so the spender can never take more than it.
    function test_approvalRace_decreaseAllowance_atomicReduce() public {
        labh.mint(alice, 1_000);
        vm.startPrank(alice);
        labh.approve(bob, 100);
        labh.decreaseAllowance(bob, 50); // 100 -> 50 in ONE SSTORE
        vm.stopPrank();

        assertEq(labh.allowance(alice, bob), 50);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 50, 100)
        );
        vm.prank(bob);
        labh.transferFrom(alice, bob, 100);

        vm.prank(bob);
        labh.transferFrom(alice, bob, 50);
        assertEq(labh.balanceOf(bob), 50);
    }

    /// @dev Two-step approve(0)->approve(N): a front-run of the SECOND step
    ///      captures only N — the zero step already cleared the old allowance.
    function test_approvalRace_twoStep_secondStepFrontRunCapturesOnlyNew() public {
        lab.mint(alice, 1_000);
        vm.startPrank(alice);
        lab.approve(bob, 100);
        lab.approve(bob, 0); // the zero step lands first
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 100));
        vm.prank(bob); // front-run of the second step: nothing to take
        lab.transferFrom(alice, bob, 100);

        vm.prank(alice);
        lab.approve(bob, 50);
        vm.prank(bob);
        lab.transferFrom(alice, bob, 50);
        assertEq(lab.balanceOf(bob), 50);
    }

    /// @dev Honest caveat: two-step does NOT protect the OLD allowance if the
    ///      spender acts before the zero step lands — it only prevents a
    ///      single reduce tx from extending reach to old+new.
    function test_approvalRace_twoStep_frontRunOfZeroStep_losesOld() public {
        lab.mint(alice, 1_000);
        vm.startPrank(alice);
        lab.approve(bob, 100);
        vm.stopPrank();

        vm.prank(bob); // front-runs the zero step, captures the old 100
        lab.transferFrom(alice, bob, 100);

        vm.startPrank(alice);
        lab.approve(bob, 0);
        lab.approve(bob, 50);
        vm.stopPrank();

        vm.prank(bob); // the new 50 is still spendable
        lab.transferFrom(alice, bob, 50);
        assertEq(lab.balanceOf(bob), 150); // same reach as the single-approve race
    }

    /// @dev The structural fix: ERC-2612 permit pins the value in a signature,
    ///      so no stale allowance exists to front-run. Bounded value, exact
    ///      allowance — the spender can take exactly what was signed.
    function test_permit_setsExactAllowance_noStaleState() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(_permitDigest(alice, bob, 50, 0, deadline));

        mer.permit(alice, bob, 50, deadline, v, r, s); // anyone can submit

        assertEq(mer.allowance(alice, bob), 50);
        assertEq(mer.nonces(alice), 1);

        vm.prank(bob);
        mer.transferFrom(alice, bob, 50);
        assertEq(mer.balanceOf(bob), 50);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        mer.transferFrom(alice, bob, 1);
    }

    /// @dev Permit griefing: an attacker front-runs the user's own signed
    ///      permit with the SAME signature. It succeeds (consuming the nonce);
    ///      the user's original permit then reverts because the nonce advanced.
    ///      No funds are stolen (the attacker cannot change the signed value),
    ///      but the user's transaction fails and the spender keeps the
    ///      allowance. Rebuild the digest with the consumed nonce to prove the
    ///      recovered signer is no longer Alice — the exact ERC2612InvalidSigner
    ///      revert OZ v5.7 produces.
    function test_permit_griefing_frontRun_burnsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(_permitDigest(alice, bob, 50, 0, deadline));

        vm.prank(mallory); // front-run: submit the user's signature first
        mer.permit(alice, bob, 50, deadline, v, r, s);
        assertEq(mer.allowance(alice, bob), 50);
        assertEq(mer.nonces(alice), 1);

        // The user's own permit rebuilds the struct hash with nonce 1 (the
        // current one), so the recovered signer differs from Alice.
        address recovered = ECDSA.recover(_permitDigest(alice, bob, 50, 1, deadline), v, r, s);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, alice));
        mer.permit(alice, bob, 50, deadline, v, r, s);

        assertEq(mer.nonces(alice), 1); // the failed permit burned nothing
    }

    // ── (b) fee-on-transfer tokens ──────────────────────────────────────────

    /// @dev The token semantics: sender pays 100, receiver gets 99, 1 burned.
    function test_feeOnTransfer_receiverGetsNet() public {
        fee.mint(alice, 1_000);
        vm.prank(alice);
        fee.transfer(bob, 100);

        assertEq(fee.balanceOf(bob), 99);
        assertEq(fee.balanceOf(alice), 900);
        assertEq(fee.totalSupply(), 999); // 1 wei burned
    }

    /// @dev The naive integrator credits `amount`; after ONE full deposit the
    ///      ledger says 100 but the vault holds 99 — instantly insolvent.
    function test_naiveFeeIntegrator_instantlyInsolvent() public {
        fee.mint(alice, 1_000);
        vm.startPrank(alice);
        fee.approve(address(naiveFee), type(uint256).max);
        naiveFee.deposit(100);
        vm.stopPrank();

        assertEq(naiveFee.credits(alice), 100); // recorded liability
        assertEq(fee.balanceOf(address(naiveFee)), 99); // real balance

        // OZ `_update` moves the net 99 first (99 from 99, ok), then burns the
        // 1 fee from the now-empty vault -> ERC20InsufficientBalance(vault, 0, 1).
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(naiveFee), 0, 1)
        );
        vm.prank(alice);
        naiveFee.redeem(100);
    }

    /// @dev The delta integrator credits `received`; it stays solvent through
    ///      the round trip (the fee is the token's business, not the vault's
    ///      insolvency). Deposit 1000: 1% in (10 burned), redeem the 990 credit:
    ///      1% out (9 burned) -> Alice nets 981 = 1000 - 10 - 9.
    function test_deltaFeeIntegrator_solvent() public {
        fee.mint(alice, 1_000);
        vm.startPrank(alice);
        fee.approve(address(deltaFee), type(uint256).max);
        deltaFee.deposit(1000);
        vm.stopPrank();

        assertEq(deltaFee.credits(alice), 990); // measured delta, not the request

        vm.prank(alice);
        deltaFee.redeem(990);
        assertEq(deltaFee.credits(alice), 0);
        assertEq(fee.balanceOf(address(deltaFee)), 0);
        assertEq(fee.balanceOf(alice), 1000 - 10 - 9); // fee in, fee out
    }

    // ── (c) rebasing tokens ─────────────────────────────────────────────────

    function test_rebase_positive_growsBalances() public {
        reb.mint(alice, 100);
        reb.rebase(5000); // +50%
        assertEq(reb.balanceOf(alice), 150);
        assertEq(reb.totalSupply(), 150);
    }

    function test_rebase_negative_shrinksBalances() public {
        reb.mint(alice, 100);
        reb.rebase(-5000); // -50%
        assertEq(reb.balanceOf(alice), 50);
        assertEq(reb.totalSupply(), 50);
    }

    function test_rebase_guardrail_rejectsFullCollapse() public {
        reb.mint(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(ITokenSecurityLab.RebaseOutOfBounds.selector, int256(-10_000)));
        reb.rebase(-10_000);
    }

    /// @dev Raw-unit accounting + negative rebase = insolvency: the vault owes
    ///      more than it holds, so the last redeemer cannot be paid.
    function test_naiveRebaseVault_negativeRebase_insolvent() public {
        reb.mint(alice, 100);
        reb.mint(bob, 100);
        vm.startPrank(alice);
        reb.approve(address(naiveRebase), type(uint256).max);
        naiveRebase.deposit(100);
        vm.stopPrank();
        vm.startPrank(bob);
        reb.approve(address(naiveRebase), type(uint256).max);
        naiveRebase.deposit(100);
        vm.stopPrank();

        reb.rebase(-5000); // -50%: vault balance 200 -> 100, tracked stays 200
        assertEq(naiveRebase.surplus(), -100);

        vm.prank(alice); // first redeemer is paid in full
        naiveRebase.redeem(100);
        assertEq(reb.balanceOf(address(naiveRebase)), 0);

        // The last redeemer hits the rebaser's own balance check (the gons
        // ledger is empty).
        vm.expectRevert(abi.encodeWithSelector(ITokenSecurityLab.InsufficientBalance.selector, 0, 100));
        vm.prank(bob); // last redeemer is stuck
        naiveRebase.redeem(100);
    }

    /// @dev Raw-unit accounting + positive rebase = free value: the vault holds
    ///      300 while tracking 200, so after paying every tracked unit it still
    ///      holds 100 tokens no share claims — either stuck or sweepable.
    function test_naiveRebaseVault_positiveRebase_freeValue() public {
        reb.mint(alice, 100);
        reb.mint(bob, 100);
        vm.startPrank(alice);
        reb.approve(address(naiveRebase), type(uint256).max);
        naiveRebase.deposit(100);
        vm.stopPrank();
        vm.startPrank(bob);
        reb.approve(address(naiveRebase), type(uint256).max);
        naiveRebase.deposit(100);
        vm.stopPrank();

        reb.rebase(5000); // +50%: vault balance 200 -> 300, tracked stays 200
        assertEq(naiveRebase.surplus(), 100);

        vm.prank(alice);
        naiveRebase.redeem(100);
        vm.prank(bob);
        naiveRebase.redeem(100);

        // Every tracked unit paid, yet 68 gons (102 tokens at rate 1.5) remain
        // in the vault with ZERO liabilities — the gons-floor leaves the free
        // value slightly larger than the exact 100.
        assertEq(naiveRebase.surplus(), 102); // unbacked free value remains
        assertEq(reb.balanceOf(address(naiveRebase)), 102);
    }

    /// @dev Share-of-balance accounting survives a positive rebase: each
    ///      depositor gets their pro-rata share of the grown balance — the same
    ///      result as holding the rebasing token directly.
    function test_fractionalRebaseVault_positiveRebase_proportional() public {
        reb.mint(alice, 100);
        reb.mint(bob, 100);
        vm.startPrank(alice);
        reb.approve(address(fracRebase), type(uint256).max);
        fracRebase.deposit(100);
        vm.stopPrank();
        vm.startPrank(bob);
        reb.approve(address(fracRebase), type(uint256).max);
        fracRebase.deposit(100);
        vm.stopPrank();

        reb.rebase(5000); // +50%
        assertEq(fracRebase.totalAssets(), 300);

        vm.prank(alice);
        assertEq(fracRebase.redeem(100), 150); // 100 -> 150, like holding REB
        vm.prank(bob);
        assertEq(fracRebase.redeem(100), 150);
        assertEq(reb.balanceOf(address(fracRebase)), 0);
    }

    /// @dev And a negative rebase leaves the fractional vault solvent — each
    ///      depositor bears their proportional share of the shrink.
    function test_fractionalRebaseVault_negativeRebase_solvent() public {
        reb.mint(alice, 100);
        reb.mint(bob, 100);
        vm.startPrank(alice);
        reb.approve(address(fracRebase), type(uint256).max);
        fracRebase.deposit(100);
        vm.stopPrank();
        vm.startPrank(bob);
        reb.approve(address(fracRebase), type(uint256).max);
        fracRebase.deposit(100);
        vm.stopPrank();

        reb.rebase(-5000); // -50%
        vm.prank(alice);
        assertEq(fracRebase.redeem(100), 50);
        vm.prank(bob);
        assertEq(fracRebase.redeem(100), 50);
        assertEq(reb.balanceOf(address(fracRebase)), 0);
    }

    /// @dev Conservation under a bounded positive rebase: full redemption pays
    ///      everyone their share and leaves the vault empty (within the 2-wei
    ///      floor-rounding slack per conversion).
    function testFuzz_fractionalRebaseVault_conservation(uint256 a_, uint256 b_, uint256 bps_) public {
        uint256 a = bound(a_, 1, 1e30);
        uint256 b = bound(b_, 1, 1e30);
        uint256 bps = bound(bps_, 1, 9000);

        reb.mint(alice, a);
        reb.mint(bob, b);
        vm.startPrank(alice);
        reb.approve(address(fracRebase), type(uint256).max);
        fracRebase.deposit(a);
        vm.stopPrank();
        vm.startPrank(bob);
        reb.approve(address(fracRebase), type(uint256).max);
        fracRebase.deposit(b);
        vm.stopPrank();

        reb.rebase(int256(bps));
        uint256 assetsBefore = fracRebase.totalAssets();

        // Ch 14 finding #3 recurrence: next-call cheatcodes are consumed by
        // argument-evaluation calls, so the share reads MUST be hoisted before
        // the prank or `redeem` runs as the test contract with 0 shares.
        uint256 aliceShares = fracRebase.shares(alice);
        uint256 bobShares = fracRebase.shares(bob);
        vm.prank(alice);
        uint256 alicePaid = fracRebase.redeem(aliceShares);
        vm.prank(bob);
        uint256 bobPaid = fracRebase.redeem(bobShares);

        // Conservation, bounded: gons are conserved, but balanceOf floors per
        // account (`gons * rate / BASE`), so `sum(balanceOf) <= totalSupply`
        // with a gap of at most one fragment per account — the AMPL micro-dust.
        // The vault can never distribute more than it held.
        uint256 aliceReceived = reb.balanceOf(alice);
        uint256 bobReceived = reb.balanceOf(bob);
        uint256 leftover = reb.balanceOf(address(fracRebase));
        assertLe(aliceReceived + bobReceived + leftover, assetsBefore);
        assertGe(aliceReceived + bobReceived + leftover, assetsBefore - 2);
        // Fairness: a positive rebase never erodes principal (floor slack only).
        uint256 floorBound = a + b > 3 ? a + b - 3 : 0; // avoid underflow at dust scale
        assertGe(aliceReceived + bobReceived, floorBound);
        // The vault is drained modulo the gons-floor dust (< a few wei at the
        // maximum +90% rebase).
        assertLe(leftover, 4);
    }

    // ── gas probes (log-only, warm-up first, loop-amplified min-deltas) ────

    /// @dev The price of the delta-measurement fix: naive credits with zero
    ///      balance reads; delta pays for two external `balanceOf` reads.
    function test_gasProbe_feeIntegrator_naiveVsDelta() public {
        fee.mint(alice, 1_000_000);
        vm.startPrank(alice);
        fee.approve(address(naiveFee), type(uint256).max);
        fee.approve(address(deltaFee), type(uint256).max);
        naiveFee.deposit(1); // warm-up call
        deltaFee.deposit(1);
        uint256 bestNaive = type(uint256).max;
        uint256 bestDelta = type(uint256).max;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 g0 = gasleft();
            naiveFee.deposit(1);
            uint256 naive = g0 - gasleft();
            if (naive < bestNaive) bestNaive = naive;
            g0 = gasleft();
            deltaFee.deposit(1);
            uint256 delta = g0 - gasleft();
            if (delta < bestDelta) bestDelta = delta;
        }
        console2.log("naive fee deposit gas (min of 5):", bestNaive);
        console2.log("delta fee deposit gas (min of 5):", bestDelta);
    }

    /// @dev Gons-based balanceOf (mulDiv + 2 SLOADs) vs plain ERC20 balanceOf
    ///      (1 SLOAD) — the per-account cost of elastic supply.
    function test_gasProbe_rebasing_balanceOf() public {
        lab.mint(alice, 1e18);
        reb.mint(alice, 1e18);
        lab.balanceOf(alice); // warm-up
        reb.balanceOf(alice);
        uint256 bestLab = type(uint256).max;
        uint256 bestReb = type(uint256).max;
        for (uint256 i = 0; i < 10; ++i) {
            uint256 g0 = gasleft();
            lab.balanceOf(alice);
            uint256 l = g0 - gasleft();
            if (l < bestLab) bestLab = l;
            g0 = gasleft();
            reb.balanceOf(alice);
            uint256 r = g0 - gasleft();
            if (r < bestReb) bestReb = r;
        }
        console2.log("ERC20 balanceOf gas (min of 10):", bestLab);
        console2.log("rebasing balanceOf gas (min of 10):", bestReb);
    }

    // ── helpers (Ch 14 pattern) ─────────────────────────────────────────────

    function _permitDigest(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, value_, nonce_, deadline_));
        return keccak256(abi.encodePacked("\x19\x01", mer.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(bytes32 digest) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return vm.sign(ALICE_KEY, digest);
    }
}
