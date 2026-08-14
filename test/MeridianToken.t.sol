// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {IMeridianToken} from "../src/IMeridianToken.sol";

/// @notice Ch 14 ERC20 Deep Dive test suite for MeridianToken (MER) — the first
///         PROTOCOL contract (not a lab probe). 40+ tests: EIP-20 semantics,
///         allowance edge cases, the approval-race demonstration (stale approve
///         vs fail-safe decrease), ERC-2612 permit (EIP-712 digests, nonce
///         replay, expiry, wrong signer, cross-chain domain), role-gated mint,
///         burn/burnFrom, fuzz accounting pins, and two log-only gas probes.
/// @dev Conventions held: parameter-exact `vm.expectRevert` (Ch 10); every
///      privileged call has a non-privileged negative test (Ch 10); cheatcodes
///      confined to test/ (Ch 10); gas probes are log-only, loop-amplified
///      min-deltas, never asserted (Ch 8 methodology). The token's error catalog
///      is referenced through the OZ interfaces (IERC20Errors, IAccessControl)
///      and the inherited ERC-2612 errors — canon since Ch 14.
contract MeridianTokenTest is Test {
    /// @dev Fixed key for Alice so permit signatures are reproducible.
    uint256 internal constant ALICE_KEY = 0xA11CE;
    uint256 internal constant CAROL_KEY = 0xC0C0A;

    /// @dev Initial protocol supply: 10,000,000 MER (18 decimals).
    uint256 internal constant INITIAL_SUPPLY = 10_000_000e18;
    /// @dev MER funding the test hands Alice from the treasury.
    uint256 internal constant ALICE_FUNDING = 1_000e18;
    /// @dev The 1-wei gas-probe recipient funding (see setUp).
    uint256 internal constant RECIPIENT_FUNDING = 1;

    /// @dev ERC-2612 typehash (compile-time constant; the contract keeps it
    ///      private, so the test re-derives it — a signature that disagrees
    ///      here would be rejected by `permit`).
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    /// @dev EIP-712 domain typehash.
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    MeridianToken internal token;
    address internal owner; // DEFAULT_ADMIN_ROLE holder
    address internal minter; // MINTER_ROLE holder
    address internal treasury; // initial-supply recipient
    address internal alice; // vm.addr(ALICE_KEY) — the permit signer
    address internal bob;
    address internal carol; // vm.addr(CAROL_KEY) — the wrong-signer in permit tests
    address internal recipient; // 1-wei holder used only by the gas probe

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        treasury = makeAddr("treasury");
        alice = vm.addr(ALICE_KEY);
        bob = makeAddr("bob");
        carol = vm.addr(CAROL_KEY);
        recipient = makeAddr("recipient");

        token = new MeridianToken(owner, minter, treasury, INITIAL_SUPPLY);

        // Fund Alice from the treasury so she can transfer/burn/approve.
        vm.prank(treasury);
        token.transfer(alice, ALICE_FUNDING);

        // Fund the gas-probe recipient with 1 wei: written in setUp (separate
        // tx from each test), so during the probe its slot is warm but NOT
        // dirty — the precondition for the reset-price measurement.
        vm.prank(treasury);
        token.transfer(recipient, 1);
    }

    // ── EIP-20 metadata & supply ──────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(token.name(), "Meridian Token");
        assertEq(token.symbol(), "MER");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_initialSupply_mintedToRecipient() public view {
        // setUp moved ALICE_FUNDING and RECIPIENT_FUNDING out of the treasury,
        // so treasury holds the remainder; totalSupply is untouched by
        // transfers.
        assertEq(token.balanceOf(treasury), INITIAL_SUPPLY - ALICE_FUNDING - RECIPIENT_FUNDING);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    // ── transfer semantics ────────────────────────────────────────────────────

    function test_transfer_movesBalanceAndEmitsEvent() public {
        vm.expectEmit();
        emit IERC20.Transfer(alice, bob, 250e18);
        vm.prank(alice);
        token.transfer(bob, 250e18);
        assertEq(token.balanceOf(alice), ALICE_FUNDING - 250e18);
        assertEq(token.balanceOf(bob), 250e18);
    }

    function test_transfer_toZero_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        vm.prank(alice);
        token.transfer(address(0), 1);
    }

    function test_transfer_insufficientBalance_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                alice,
                ALICE_FUNDING,
                ALICE_FUNDING + 1
            )
        );
        vm.prank(alice);
        token.transfer(bob, ALICE_FUNDING + 1);
    }

    function test_transfer_zeroValue_succeedsAndEmits() public {
        // EIP-20: transfers of 0 values MUST be treated as normal transfers
        // and fire the Transfer event.
        vm.expectEmit();
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        token.transfer(bob, 0);
        assertEq(token.balanceOf(alice), ALICE_FUNDING);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_selfTransfer_preservesBalanceAndEmits() public {
        vm.expectEmit();
        emit IERC20.Transfer(alice, alice, 100e18);
        vm.prank(alice);
        token.transfer(alice, 100e18);
        assertEq(token.balanceOf(alice), ALICE_FUNDING);
    }

    // ── allowance & transferFrom ──────────────────────────────────────────────

    function test_approve_setsAllowanceAndEmits() public {
        vm.expectEmit();
        emit IERC20.Approval(alice, bob, 100);
        vm.prank(alice);
        token.approve(bob, 100);
        assertEq(token.allowance(alice, bob), 100);
    }

    function test_approve_zeroSpender_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
        vm.prank(alice);
        token.approve(address(0), 100);
    }

    function test_approve_overwritesExactly() public {
        // EIP-20: approve sets the allowance to exactly `value` — no accumulation.
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(alice);
        token.approve(bob, 50);
        assertEq(token.allowance(alice, bob), 50);
    }

    function test_transferFrom_usesAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        token.transferFrom(alice, bob, 60);
        assertEq(token.balanceOf(bob), 60);
        assertEq(token.balanceOf(alice), ALICE_FUNDING - 60);
        assertEq(token.allowance(alice, bob), 40);
    }

    function test_transferFrom_insufficientAllowance_reverts() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 100, 101)
        );
        vm.prank(bob);
        token.transferFrom(alice, bob, 101);
    }

    function test_transferFrom_insufficientBalance_reverts() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max); // allowance is not the binding constraint
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                alice,
                ALICE_FUNDING,
                ALICE_FUNDING + 1
            )
        );
        vm.prank(bob);
        token.transferFrom(alice, bob, ALICE_FUNDING + 1);
    }

    function test_safeTransfer_viaSafeERC20_pullsTokens() public {
        // The Ch 9 returndata-gate pattern, exercised against a COMPLIANT
        // token: SafeERC20's safeTransfer decodes the bool return and reverts
        // on anything other than `true` (rds == 0x20). MER returns true, so
        // the path is the happy case; Ch 20's vault will use SafeERC20 for
        // every external token interaction, and Ch 17 covers the weird tokens.
        // Fund the test contract first (it is a normal holder).
        vm.prank(treasury);
        token.transfer(address(this), 500);
        SafeERC20.safeTransfer(token, bob, 500);
        assertEq(token.balanceOf(bob), 500);
        assertEq(token.balanceOf(address(this)), 0);
    }

    // ── the approval race (EIP-20's own warning, made concrete) ───────────────
    // NOTE (OZ v5 fact, pinned here): OpenZeppelin v5 REMOVED
    // increaseAllowance/decreaseAllowance (present in v4.x). The v5 mitigation
    // set for the race is: two-step approve(0)→approve(N), SafeERC20.forceApprove
    // (which does the two-step internally for integrators), or ERC-2612 permit
    // with bounded values/deadlines. The relative-helper concept lives on only
    // in integrator libraries, not on the token itself.

    function test_approvalRace_staleApprove_grantsMoreThanIntended() public {
        // Alice approves Bob 100. She decides the exposure should be 50 and
        // sends approve(50). Bob sees the pending tx, front-runs it with a
        // transferFrom(100) that drains the OLD allowance, and then the stale
        // approve(50) lands — Bob can now take ANOTHER 50. Total reach: 150,
        // when Alice intended 50. This is the race EIP-20 warns about.
        vm.prank(alice);
        token.approve(bob, 100);

        vm.prank(bob); // front-run: spend the old allowance first
        token.transferFrom(alice, bob, 100);

        vm.prank(alice); // stale intent lands after the front-run
        token.approve(bob, 50);

        vm.prank(bob); // the residual allowance is still spendable
        token.transferFrom(alice, bob, 50);

        assertEq(token.balanceOf(bob), 150); // 150 extracted vs 50 intended
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_approvalRace_forceApprove_twoStep() public {
        // The integrator-side mitigation: SafeERC20.forceApprove first tries a
        // plain approve(N); ONLY when the token returns false (the USDT-class
        // behavior) does it fall back to approve(0) → approve(N), so any
        // front-run between the steps can only capture the N of the second
        // approval. MER returns true, so this run takes the single-approve
        // path — the two-step is the fallback branch, exercised against a
        // false-returning mock in Ch 17. Ch 20's vault will use forceApprove
        // for every token it touches.
        vm.expectEmit();
        emit IERC20.Approval(address(this), bob, 50);
        SafeERC20.forceApprove(token, bob, 50);
        assertEq(token.allowance(address(this), bob), 50);
    }

    function test_twoStepApprove_limitsExposure() public {
        // The canonical fix: approve(0), then approve(50). A front-run between
        // the two steps can only ever capture the 50 of the second tx — the
        // old allowance was already zeroed.
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(alice);
        token.approve(bob, 50);
        assertEq(token.allowance(alice, bob), 50);
    }

    // ── ERC-2612 permit ───────────────────────────────────────────────────────

    function test_domainSeparator_bindsChainIdAndContract() public view {
        bytes32 expected = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("Meridian Token")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    function test_permit_setsAllowance() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(_permitDigest(alice, bob, 100, 0, deadline));

        token.permit(alice, bob, 100, deadline, v, r, s);

        assertEq(token.allowance(alice, bob), 100);
        assertEq(token.nonces(alice), 1);
    }

    function test_permit_replay_reverts() public {
        // The nonce is consumed: replaying the same signature rebuilds the
        // struct hash with nonce 1, the recovered signer no longer matches
        // Alice, and the call reverts with the recovered (wrong) signer.
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(_permitDigest(alice, bob, 100, 0, deadline));

        token.permit(alice, bob, 100, deadline, v, r, s); // nonce 0 → 1

        bytes32 replayedDigest = _permitDigest(alice, bob, 100, 1, deadline);
        address recoveredForReplay = ecrecover(replayedDigest, v, r, s);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, recoveredForReplay, alice
            )
        );
        token.permit(alice, bob, 100, deadline, v, r, s);
    }

    function test_permit_expired_reverts() public {
        uint256 deadline = block.timestamp - 1; // already past
        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline)
        );
        token.permit(alice, bob, 100, deadline, 27, bytes32(0), bytes32(0)); // reverts before sig check
    }

    function test_permit_wrongSigner_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        // Carol signs Alice's permit — the recovered signer is Carol, not Alice.
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(CAROL_KEY, _permitDigest(alice, bob, 100, 0, deadline));

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, carol, alice)
        );
        token.permit(alice, bob, 100, deadline, v, r, s);
    }

    function test_permit_wrongChainId_rejected() public {
        // Cross-chain replay protection: a signature built against a domain
        // separator for another chainId must be rejected here. EIP-712 binds
        // chainId + verifyingContract; EIP-2612 inherits that binding.
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 otherChainDomain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("Meridian Token")),
                keccak256(bytes("1")),
                block.chainid + 1,
                address(token)
            )
        );
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 100, 0, deadline));
        bytes32 otherChainDigest =
            keccak256(abi.encodePacked("\x19\x01", otherChainDomain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_KEY, otherChainDigest);

        // The contract rebuilds the digest over the REAL domain (chainId of
        // this chain); the recovered signer is whoever that digest yields.
        bytes32 realDigest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        address recoveredOverRealDomain = ecrecover(realDigest, v, r, s);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, recoveredOverRealDomain, alice
            )
        );
        token.permit(alice, bob, 100, deadline, v, r, s);
    }

    function test_permit_maxDeadline_noExpiry() public {
        // type(uint256).max as deadline is the "no expiry" convention.
        (uint8 v, bytes32 r, bytes32 s) =
            _sign(_permitDigest(alice, bob, 100, 0, type(uint256).max));
        token.permit(alice, bob, 100, type(uint256).max, v, r, s);
        assertEq(token.allowance(alice, bob), 100);
    }

    function test_permit_zeroValue_cancelsAllowance() public {
        // The "revoke via permit" pattern: a signed zero-value permit zeroes
        // the allowance without an on-chain approve tx from the owner.
        vm.prank(alice);
        token.approve(bob, 100);
        (uint8 v, bytes32 r, bytes32 s) = _sign(_permitDigest(alice, bob, 0, 0, type(uint256).max));
        token.permit(alice, bob, 0, type(uint256).max, v, r, s);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_permit_thenTransferFrom_gaslessFlow() public {
        // The UX permit exists for: Alice signs off-chain (no gas), Bob
        // submits permit + transferFrom in ONE tx. Alice never pays for the
        // approval.
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(_permitDigest(alice, bob, 100, 0, deadline));

        vm.startPrank(bob);
        token.permit(alice, bob, 100, deadline, v, r, s);
        token.transferFrom(alice, bob, 100);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.nonces(alice), 1);
    }

    // ── mint (role-gated) & burn ──────────────────────────────────────────────

    function test_mint_onlyMinter_mintsAndEmits() public {
        vm.expectEmit();
        emit IERC20.Transfer(address(0), alice, 500);
        vm.prank(minter);
        token.mint(alice, 500);
        assertEq(token.balanceOf(alice), ALICE_FUNDING + 500);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 500);
    }

    function test_mint_nonMinter_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.MINTER_ROLE()
            )
        );
        vm.prank(alice);
        token.mint(alice, 1);
    }

    function test_mint_toZero_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        vm.prank(minter);
        token.mint(address(0), 1);
    }

    function test_burn_own_reducesSupplyAndEmits() public {
        vm.expectEmit();
        emit IERC20.Transfer(alice, address(0), 100);
        vm.prank(alice);
        token.burn(100);
        assertEq(token.balanceOf(alice), ALICE_FUNDING - 100);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 100);
    }

    function test_burnFrom_usesAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        token.burnFrom(alice, 60);
        assertEq(token.balanceOf(alice), ALICE_FUNDING - 60);
        assertEq(token.allowance(alice, bob), 40);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 60);
    }

    function test_burnFrom_insufficientAllowance_reverts() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 100, 101)
        );
        vm.prank(bob);
        token.burnFrom(alice, 101);
    }

    // ── AccessControl: role administration ────────────────────────────────────

    function test_defaultAdmin_canGrantMinterRole() public {
        // NOTE: the role constant must be read BEFORE vm.prank — evaluating
        // `token.MINTER_ROLE()` as a call argument would consume the prank
        // (the next-call cheatcode applies to the argument-evaluation call,
        // not the outer call; pinned as a Ch 14 finding).
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(owner);
        token.grantRole(minterRole, carol);
        vm.prank(carol);
        token.mint(bob, 42);
        assertEq(token.balanceOf(bob), 42);
    }

    function test_grantRole_nonAdmin_reverts() public {
        // grantRole is gated by the role's ADMIN (DEFAULT_ADMIN_ROLE, i.e.
        // bytes32(0)) — not by MINTER_ROLE itself. Both role reads MUST happen
        // before the cheatcodes: any external call made while evaluating call
        // arguments consumes the next-call cheatcode (vm.expectRevert here,
        // vm.prank in test_defaultAdmin_canGrantMinterRole — Ch 14 finding).
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 defaultAdminRole = token.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, defaultAdminRole
            )
        );
        vm.prank(alice);
        token.grantRole(minterRole, bob);
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianToken.InvalidConstructorAddress.selector, address(0))
        );
        new MeridianToken(address(0), minter, treasury, INITIAL_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianToken.InvalidConstructorAddress.selector, address(0))
        );
        new MeridianToken(owner, address(0), treasury, INITIAL_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IMeridianToken.InvalidConstructorAddress.selector, address(0))
        );
        new MeridianToken(owner, minter, address(0), INITIAL_SUPPLY);
    }

    // ── fuzz: accounting pins ─────────────────────────────────────────────────

    function testFuzz_transfer_conservesSupply(uint256 amount) public {
        amount = bound(amount, 0, ALICE_FUNDING);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), ALICE_FUNDING - amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_transferFrom_allowanceAccounting(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, ALICE_FUNDING);
        amount = bound(amount, 0, allowance);
        vm.prank(alice);
        token.approve(bob, allowance);
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, bob), allowance - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), ALICE_FUNDING - amount);
    }

    function testFuzz_approve_overwritesExact(uint256 first, uint256 second) public {
        vm.prank(alice);
        token.approve(bob, first);
        vm.prank(alice);
        token.approve(bob, second);
        assertEq(token.allowance(alice, bob), second);
    }

    function testFuzz_burn_neverExceedsBalance(uint256 amount) public {
        amount = bound(amount, 0, ALICE_FUNDING);
        vm.prank(alice);
        token.burn(amount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(alice), ALICE_FUNDING - amount);
    }

    // ── gas probes (log-only; loop-amplified min-deltas, Ch 8 methodology) ────

    function testGas_transfer_warmPath() public {
        // Four honest SSTORE regimes, all measured in-run (setUp is a separate
        // tx from the test, so slots written in setUp are warm but NOT dirty):
        //  (a) warm, not dirty, both slots nonzero → RESET (2,900) per slot.
        //  (b) self-transfer after (a) → sender slot already dirty → 100/op.
        //  (c) dirty slots, loop-amplified min-delta (repeated writes in one tx
        //      are 100 each — the regime most people get wrong).
        //  (d) cold receiver slot (0 → 1, first touch) → 22,100 + SET pricing.
        token.balanceOf(alice);
        token.balanceOf(recipient);
        vm.startPrank(alice);
        uint256 g0 = gasleft();
        token.transfer(recipient, 1); // (a) both slots nonzero, not dirty
        uint256 resetPrice = g0 - gasleft();

        g0 = gasleft();
        token.transfer(alice, 1); // (b) self-transfer; alice slot now dirty
        uint256 dirtySelf = g0 - gasleft();

        g0 = gasleft();
        token.transfer(makeAddr("freshReceiver"), 1); // (d) cold receiver 0→1
        uint256 coldReceiver = g0 - gasleft();
        vm.stopPrank();
        console2.log("transfer (a) warm, not dirty (reset price):", resetPrice);
        console2.log("transfer (b) self-transfer, dirty sender slot:", dirtySelf);
        console2.log("transfer (d) cold receiver slot (SET+cold):", coldReceiver);

        uint256 best = type(uint256).max;
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; ++i) {
            uint256 d0 = gasleft();
            for (uint256 j = 0; j < 50; ++j) {
                token.transfer(recipient, 1);
            }
            uint256 perTransfer = (d0 - gasleft()) / 50;
            if (perTransfer < best) best = perTransfer;
        }
        vm.stopPrank();
        console2.log("transfer (c) dirty slots, loop-amplified:", best);

        // Diagnostic: prove the transfers actually moved balances.
        console2.log("alice balance:", token.balanceOf(alice));
        console2.log("recipient balance:", token.balanceOf(recipient));
    }

    function testGas_permit_warmPath() public {
        uint256 nonce;
        uint256 best = type(uint256).max;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 g0 = gasleft();
            for (uint256 j = 0; j < 20; ++j) {
                (uint8 v, bytes32 r, bytes32 s) =
                    _sign(_permitDigest(alice, bob, 1, nonce, type(uint256).max));
                token.permit(alice, bob, 1, type(uint256).max, v, r, s);
                ++nonce;
            }
            uint256 perPermit = (g0 - gasleft()) / 20;
            if (perPermit < best) best = perPermit;
        }
        console2.log("permit path gas (warm, incl. call overhead):", best);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev EIP-712 digest for a Permit struct: 0x19 0x01 ‖ domain ‖ structHash.
    function _permitDigest(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner_, spender_, value_, nonce_, deadline_)
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(bytes32 digest) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return vm.sign(ALICE_KEY, digest);
    }
}
