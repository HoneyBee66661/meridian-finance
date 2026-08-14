// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Votes} from "@openzeppelin/contracts/governance/utils/Votes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianGovernanceToken} from "../src/MeridianGovernanceToken.sol";
import {IMeridianGovernanceToken} from "../src/IMeridianGovernanceToken.sol";

/// @notice Ch 15 Governance Tokens test suite for MeridianGovernanceToken (gMER)
///         — the ERC-5805/ERC-6372 checkpointed-voting wrapper around MER.
///         ~40 tests: wrapper mechanics (deposit/withdraw 1:1), ERC-5805
///         delegation (self, third-party, delegate-to-zero, vote movement on
///         transfer), historical votes (strictly-past rule, ERC5805FutureLookup),
///         delegateBySig (EIP-712, replay, expiry, tamper), the shared
///         Nonces/EIP-712 space with ERC20Permit (permit vs delegation nonce
///         collision — a real OZ v5.7 finding), the Beanstalk-shaped flash-vote
///         demo, same-block checkpoint coalescing, wrapper-donation inertness,
///         fuzz conservation pins, and log-only gas probes.
/// @dev Conventions held: parameter-exact `vm.expectRevert` (Ch 10); cheatcodes
///      confined to test/ (Ch 10); gas probes are log-only, loop-amplified
///      min-deltas with a warm-up call, never asserted (Ch 8/9 methodology);
///      the probe address is warmed before deltas (Ch 8 standing rule).
contract MeridianGovernanceTokenTest is Test {
    /// @dev Fixed key for Alice so permit/delegation signatures are reproducible.
    uint256 internal constant ALICE_KEY = 0xA11CE;
    uint256 internal constant CAROL_KEY = 0xC0C0A;

    uint256 internal constant INITIAL_SUPPLY = 10_000_000e18;
    uint256 internal constant ALICE_FUNDING = 1_000_000e18;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    MeridianToken internal mer;
    MeridianGovernanceToken internal gmer;
    address internal owner;
    address internal treasury;
    address internal alice; // vm.addr(ALICE_KEY) — the EIP-712 signer
    address internal bob;
    address internal carol; // vm.addr(CAROL_KEY) — third-party submitter / wrong signer
    address internal dave;
    address internal eve;

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        alice = vm.addr(ALICE_KEY);
        bob = makeAddr("bob");
        carol = vm.addr(CAROL_KEY);
        dave = makeAddr("dave");
        eve = makeAddr("eve");

        // Test contract holds MINTER_ROLE so fixtures can mint MER on demand.
        mer = new MeridianToken(owner, address(this), treasury, INITIAL_SUPPLY);
        gmer = new MeridianGovernanceToken(address(mer), "Meridian Governance", "gMER");

        // Fund Alice from the treasury and pre-approve the wrapper once.
        vm.prank(treasury);
        mer.transfer(alice, ALICE_FUNDING);
        vm.prank(alice);
        mer.approve(address(gmer), type(uint256).max);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Alice deposits `amount` MER into the wrapper (pranked).
    function _depositFor(address account, uint256 amount) internal {
        vm.prank(account);
        gmer.deposit(amount);
    }

    /// @dev Mints MER to `account` (test contract holds MINTER_ROLE) and
    ///      pre-approves the wrapper — the standard fixture for non-Alice actors.
    function _fundAndApprove(address account, uint256 amount) internal {
        mer.mint(account, amount);
        vm.prank(account);
        mer.approve(address(gmer), type(uint256).max);
    }

    /// @dev EIP-712 signature over a Permit struct (same domain as delegateBySig).
    function _signPermit(
        uint256 key,
        address signer,
        address spender,
        uint256 value,
        uint256 deadline,
        uint256 nonce
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, signer, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gmer.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(key, digest);
    }

    /// @dev EIP-712 signature over a Delegation struct.
    function _signDelegation(
        uint256 key,
        address delegatee,
        uint256 nonce,
        uint256 expiry
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gmer.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(key, digest);
    }

    // ── construction & clock ──────────────────────────────────────────────────

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMeridianGovernanceToken.InvalidConstructorAddress.selector, address(0)));
        new MeridianGovernanceToken(address(0), "Meridian Governance", "gMER");
    }

    function test_metadata() public view {
        assertEq(gmer.name(), "Meridian Governance");
        assertEq(gmer.symbol(), "gMER");
        assertEq(gmer.decimals(), 18);
        assertEq(address(gmer.mer()), address(mer));
    }

    function test_clock_blockNumberMode() public view {
        // ERC-6372: block-number clock, OZ default mode string (verified in the
        // vendored ERC6372Utils: blocknumber mode checks clock() consistency and
        // returns exactly "mode=blocknumber&from=default").
        assertEq(gmer.clock(), uint48(block.number));
        assertEq(gmer.CLOCK_MODE(), "mode=blocknumber&from=default");
    }

    // ── wrapper mechanics ─────────────────────────────────────────────────────

    function test_deposit_mintsOneForOne() public {
        vm.expectEmit(true, true, true, true, address(gmer));
        emit IMeridianGovernanceToken.Deposited(alice, 1_000e18);
        _depositFor(alice, 1_000e18);

        assertEq(gmer.balanceOf(alice), 1_000e18);
        assertEq(gmer.totalSupply(), 1_000e18);
        assertEq(mer.balanceOf(alice), ALICE_FUNDING - 1_000e18);
        assertEq(mer.balanceOf(address(gmer)), 1_000e18);
    }

    function test_depositFor_mintsToAccount() public {
        // Alice pays, Bob gets the gMER (and the votes).
        _depositFor(alice, 0); // no-op, keeps prank discipline explicit below
        vm.prank(alice);
        gmer.depositFor(bob, 500e18);

        assertEq(gmer.balanceOf(alice), 0);
        assertEq(gmer.balanceOf(bob), 500e18);
        assertEq(mer.balanceOf(alice), ALICE_FUNDING - 500e18);
    }

    function test_depositFor_zeroAddress_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        gmer.depositFor(address(0), 100e18);
        // Atomicity: the pull is rolled back with the mint.
        assertEq(mer.balanceOf(alice), ALICE_FUNDING);
        assertEq(mer.balanceOf(address(gmer)), 0);
    }

    function test_depositFor_withoutAllowance_reverts() public {
        vm.prank(bob); // bob never approved the wrapper
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gmer), 0, 100e18)
        );
        gmer.deposit(100e18);
    }

    function test_deposit_zeroAmount_isNoOp() public {
        _depositFor(alice, 0);
        assertEq(gmer.totalSupply(), 0);
        assertEq(gmer.numCheckpoints(alice), 0); // no checkpoint spam on zero ops
    }

    function test_withdraw_burnsAndReturns() public {
        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        gmer.delegate(alice); // activate checkpoints before unwrapping

        vm.expectEmit(true, true, true, true, address(gmer));
        emit IMeridianGovernanceToken.Withdrawn(alice, 400e18);
        vm.prank(alice);
        gmer.withdraw(400e18);

        assertEq(gmer.balanceOf(alice), 600e18);
        assertEq(gmer.totalSupply(), 600e18);
        assertEq(mer.balanceOf(alice), ALICE_FUNDING - 600e18);
        assertEq(gmer.getVotes(alice), 600e18); // votes follow the burn
    }

    function test_withdraw_insufficientBalance_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1e18)
        );
        vm.prank(alice);
        gmer.withdraw(1e18);
    }

    // ── delegation (ERC-5805) ─────────────────────────────────────────────────

    function test_delegate_movesVotes() public {
        _depositFor(alice, 1_000e18);

        vm.expectEmit(true, true, true, true, address(gmer));
        emit IVotes.DelegateChanged(alice, address(0), bob);
        vm.expectEmit(true, true, true, true, address(gmer));
        emit IVotes.DelegateVotesChanged(bob, 0, 1_000e18);
        vm.prank(alice);
        gmer.delegate(bob);

        assertEq(gmer.delegates(alice), bob);
        assertEq(gmer.getVotes(bob), 1_000e18);
        assertEq(gmer.getVotes(alice), 0); // alice kept no votes for herself
    }

    function test_delegate_selfDelegate() public {
        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        gmer.delegate(alice);
        assertEq(gmer.getVotes(alice), 1_000e18);
    }

    function test_undelegated_votesNotCounted() public {
        // OZ v5 Votes semantics (verified in the vendored docstring): voting
        // units MUST be delegated to count. Undelegated gMER exists only in the
        // total-supply checkpoint — it votes for nobody, not even its holder.
        _depositFor(alice, 1_000e18);
        assertEq(gmer.getVotes(alice), 0);
        assertEq(gmer.getVotes(address(0)), 0);
        vm.roll(block.number + 1);
        assertEq(gmer.getPastTotalSupply(block.number - 1), 1_000e18); // still "available"
    }

    function test_delegateToZero_isInert() public {
        // OZ v5.7 `_moveDelegateVotes` short-circuits on from == to (both
        // address(0) here), so delegate(address(0)) writes NOTHING: the votes
        // stay unaccounted (present in total supply, in no one's checkpoint).
        // "Delegating to zero" is indistinguishable from never delegating.
        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        gmer.delegate(address(0));
        assertEq(gmer.delegates(alice), address(0));
        assertEq(gmer.getVotes(address(0)), 0);
        assertEq(gmer.getVotes(alice), 0);
        vm.roll(block.number + 1);
        assertEq(gmer.getPastTotalSupply(block.number - 1), 1_000e18); // still "available"
    }

    function test_transfer_movesVotesBetweenDelegates() public {
        _depositFor(alice, 1_000e18);
        _fundAndApprove(carol, 1_000e18);
        _depositFor(carol, 1_000e18);
        vm.prank(alice);
        gmer.delegate(bob);
        vm.prank(carol);
        gmer.delegate(dave);

        vm.prank(alice);
        gmer.transfer(carol, 400e18);

        assertEq(gmer.getVotes(bob), 600e18); // alice's delegate lost exactly 400
        assertEq(gmer.getVotes(dave), 1_400e18); // carol's delegate gained exactly 400
        assertEq(gmer.getVotes(alice), 0);
    }

    function test_transfer_undelegatedToDelegated() public {
        // Sender undelegated, receiver delegated: the receiver's delegate gains.
        _depositFor(alice, 1_000e18); // alice never delegates
        _depositFor(carol, 0);
        vm.prank(carol);
        gmer.delegate(dave);

        vm.prank(alice);
        gmer.transfer(carol, 100e18);
        assertEq(gmer.getVotes(dave), 100e18);
    }

    // ── historical votes ──────────────────────────────────────────────────────

    function test_getPastVotes_historicalCheckpoint() public {
        vm.roll(block.number + 1);
        uint256 snapshotBlock = block.number;
        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        gmer.delegate(bob);

        vm.roll(block.number + 10);
        assertEq(gmer.getPastVotes(bob, snapshotBlock), 1_000e18);

        // and the checkpoint is immutable: later changes don't rewrite history
        vm.prank(alice);
        gmer.withdraw(1_000e18);
        vm.roll(block.number + 1);
        assertEq(gmer.getPastVotes(bob, snapshotBlock), 1_000e18);
        assertEq(gmer.getVotes(bob), 0);
    }

    function test_getPastVotes_future_reverts() public {
        _depositFor(alice, 1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(Votes.ERC5805FutureLookup.selector, block.number + 100, uint48(block.number))
        );
        gmer.getPastVotes(alice, block.number + 100);
    }

    function test_getPastVotes_currentBlock_reverts() public {
        // Strictly-past rule (verified in Votes._validateTimepoint):
        // timepoint >= clock() reverts — the CURRENT block is not queryable.
        _depositFor(alice, 1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(Votes.ERC5805FutureLookup.selector, block.number, uint48(block.number))
        );
        gmer.getPastVotes(alice, block.number);
    }

    function test_getPastVotes_beforeFirstCheckpoint_zero() public {
        vm.roll(block.number + 5);
        _depositFor(alice, 1_000e18);
        // Query the block BEFORE the deposit: strictly past, no checkpoint → 0.
        assertEq(gmer.getPastVotes(alice, block.number - 5), 0);
    }

    function test_getPastTotalSupply_tracksDepositsAndWithdrawals() public {
        vm.roll(block.number + 1);
        uint256 depositBlock = block.number;
        _depositFor(alice, 1_000e18);
        vm.roll(block.number + 2);
        uint256 withdrawBlock = block.number;
        vm.prank(alice);
        gmer.withdraw(300e18);

        vm.roll(block.number + 1);
        assertEq(gmer.getPastTotalSupply(depositBlock), 1_000e18);
        assertEq(gmer.getPastTotalSupply(withdrawBlock), 700e18);
    }

    // ── delegateBySig ─────────────────────────────────────────────────────────

    function test_delegateBySig_delegatesSigner() public {
        // The signature delegates the SIGNER, whoever submits it.
        _depositFor(alice, 1_000e18);
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(ALICE_KEY, bob, 0, block.timestamp + 1 days);

        vm.prank(carol); // third-party submission
        gmer.delegateBySig(bob, 0, block.timestamp + 1 days, v, r, s);

        assertEq(gmer.delegates(alice), bob);
        assertEq(gmer.getVotes(bob), 1_000e18);
        assertEq(gmer.nonces(alice), 1);
        assertEq(gmer.delegates(carol), address(0)); // the submitter is untouched
    }

    function test_delegateBySig_replay_reverts() public {
        _depositFor(alice, 1_000e18);
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(ALICE_KEY, bob, 0, block.timestamp + 1 days);

        gmer.delegateBySig(bob, 0, block.timestamp + 1 days, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, 1));
        gmer.delegateBySig(bob, 0, block.timestamp + 1 days, v, r, s);
    }

    function test_delegateBySig_expired_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(ALICE_KEY, bob, 0, block.timestamp + 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSelector(IVotes.VotesExpiredSignature.selector, block.timestamp - 1 days));
        gmer.delegateBySig(bob, 0, block.timestamp - 1 days, v, r, s);
    }

    function test_delegateBySig_tamperedSignature_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(ALICE_KEY, bob, 0, block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector));
        // s = 0 is not low-s-valid and ecrecover yields address(0) → the OZ
        // ECDSA library deterministically reverts ECDSAInvalidSignature.
        gmer.delegateBySig(bob, 0, block.timestamp + 1 days, v, r, bytes32(0));
    }

    // ── shared EIP-712 / Nonces space (real v5.7 finding) ────────────────────

    function test_permitAndDelegation_shareNonceSpace() public {
        // ERC20Permit and Votes each inherit Nonces + EIP712; in one contract
        // they are the SAME instance (C3 merges the bases). So permit and
        // delegateBySig consume one shared per-owner nonce counter.
        (uint8 v1, bytes32 r1, bytes32 s1) = _signPermit(ALICE_KEY, alice, bob, 100e18, block.timestamp + 1 days, 0);
        (uint8 v2, bytes32 r2, bytes32 s2) = _signDelegation(ALICE_KEY, bob, 0, block.timestamp + 1 days);

        // permit consumes nonce 0...
        gmer.permit(alice, bob, 100e18, block.timestamp + 1 days, v1, r1, s1);
        assertEq(gmer.nonces(alice), 1);

        // ...so the delegation signed with nonce 0 is dead on arrival.
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, alice, 1));
        gmer.delegateBySig(bob, 0, block.timestamp + 1 days, v2, r2, s2);
        // The revert is atomic: the increment _useCheckedNonce made before the
        // check is rolled back, so a FAILED call burns nothing (verified in-run;
        // griefing by burning someone's nonce with a stale signature does not
        // work — the nonce only advances on success).
        assertEq(gmer.nonces(alice), 1);
    }

    function test_delegationAndPermit_shareNonceSpace_reverse() public {
        (uint8 v1, bytes32 r1, bytes32 s1) = _signPermit(ALICE_KEY, alice, bob, 100e18, block.timestamp + 1 days, 0);
        (uint8 v2, bytes32 r2, bytes32 s2) = _signDelegation(ALICE_KEY, bob, 0, block.timestamp + 1 days);

        // Same collision in the other order — but the failure mode is DIFFERENT
        // (pinned in-run against OZ v5.7 ERC20Permit): permit hashes
        // `_useNonce(owner)` INTO the struct (line 55 of the vendored source),
        // so a stale-nonce permit is validated against the CURRENT nonce (1)
        // and fails as a WRONG SIGNER — ERC2612InvalidSigner — not
        // InvalidAccountNonce. The revert is atomic: neither call advances the
        // nonce past 1 (0→1 on the delegation; the failed permit rolls back its
        // _useNonce, so a stale signature cannot be used to burn a nonce).
        gmer.delegateBySig(bob, 0, block.timestamp + 1 days, v2, r2, s2);
        assertEq(gmer.nonces(alice), 1);

        // Recover the address the stale signature now "belongs" to: the digest
        // built over nonce 1 (the current nonce at permit time).
        bytes32 staleDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                gmer.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 100e18, 1, block.timestamp + 1 days))
            )
        );
        address recovered = ECDSA.recover(staleDigest, v1, r1, s1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, alice));
        gmer.permit(alice, bob, 100e18, block.timestamp + 1 days, v1, r1, s1);
        assertEq(gmer.nonces(alice), 1); // atomic revert: nothing burned
    }

    // ── flash-vote demo (Beanstalk shape, delay = 0) ──────────────────────────

    function test_flashDeposit_votesVisibleAtSnapshotBlock() public {
        // The exact Beanstalk-shaped hazard at votingDelay = 0: deposit +
        // delegate + vote all land in the SNAPSHOT block, so the checkpoint at
        // that block carries the flash power. Checkpointing alone is NOT the
        // defense — the voting delay (which pushes the snapshot into the past,
        // unreachable by a same-block flash loan) is. Ch 25 wires the delay.
        vm.roll(block.number + 1);
        uint256 snapshotBlock = block.number;

        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        gmer.delegate(alice); // same block as the deposit

        vm.roll(block.number + 1);
        assertEq(gmer.getPastVotes(alice, snapshotBlock), 1_000e18); // counted at S

        // Withdrawing afterwards cannot rewrite the snapshot.
        vm.prank(alice);
        gmer.withdraw(1_000e18);
        vm.roll(block.number + 1);
        assertEq(gmer.getPastVotes(alice, snapshotBlock), 1_000e18);
        assertEq(gmer.getVotes(alice), 0);
    }

    // ── checkpoint coalescing ─────────────────────────────────────────────────

    function test_checkpoints_coalesceWithinBlock() public {
        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        gmer.delegate(bob);
        assertEq(gmer.numCheckpoints(bob), 1);

        // Three vote movements in ONE block → a single coalesced checkpoint.
        vm.prank(alice);
        gmer.transfer(carol, 100e18); // bob -100
        vm.prank(carol);
        gmer.transfer(alice, 10e18); // bob +10 (carol is undelegated)
        assertEq(gmer.numCheckpoints(bob), 1);
        assertEq(gmer.getVotes(bob), 910e18);

        // Next block: a new checkpoint entry.
        vm.roll(block.number + 1);
        vm.prank(carol);
        gmer.transfer(alice, 10e18);
        assertEq(gmer.numCheckpoints(bob), 2);
        assertEq(gmer.getVotes(bob), 920e18);
    }

    // ── wrapper integrity ─────────────────────────────────────────────────────

    function test_donation_toWrapper_isInert() public {
        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        mer.transfer(address(gmer), 500e18); // direct donation, no deposit()

        assertEq(gmer.totalSupply(), 1_000e18); // no shares were minted
        assertEq(mer.balanceOf(address(gmer)), 1_500e18);
        // withdraw still returns exactly the deposited amount; the 500 is stuck
        // by design (no rescue function — a rescue key is an admin key, Ch 25).
        vm.prank(alice);
        gmer.withdraw(1_000e18);
        assertEq(mer.balanceOf(alice), ALICE_FUNDING - 1_000e18 + 500e18);
    }

    // ── fuzz pins ─────────────────────────────────────────────────────────────

    function testFuzz_depositWithdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, 0, ALICE_FUNDING);
        _depositFor(alice, amount);
        assertEq(gmer.totalSupply(), amount);
        assertEq(mer.balanceOf(address(gmer)), amount);

        vm.prank(alice);
        gmer.withdraw(amount);
        assertEq(gmer.totalSupply(), 0);
        assertEq(mer.balanceOf(address(gmer)), 0);
        assertEq(mer.balanceOf(alice), ALICE_FUNDING);
    }

    function testFuzz_deposit_mintsOneForOne(uint256 amount) public {
        amount = bound(amount, 0, ALICE_FUNDING);
        _depositFor(alice, amount);
        assertEq(gmer.balanceOf(alice), amount);
        assertEq(gmer.totalSupply(), amount);
        assertEq(mer.balanceOf(address(gmer)), amount);
    }

    function testFuzz_transfer_movesVotesProportionally(uint256 amount) public {
        _depositFor(alice, 1_000e18);
        _depositFor(carol, 0);
        vm.prank(alice);
        gmer.delegate(bob);
        vm.prank(carol);
        gmer.delegate(dave);

        amount = bound(amount, 0, 1_000e18);
        vm.prank(alice);
        gmer.transfer(carol, amount);

        assertEq(gmer.getVotes(bob), 1_000e18 - amount);
        assertEq(gmer.getVotes(dave), amount);
    }

    // ── gas probes (log-only, loop-amplified min-deltas, warm-up first) ──────

    function test_gas_deposit() public {
        vm.prank(alice);
        gmer.delegate(alice); // governance participant: checkpoints active
        vm.prank(alice);
        gmer.deposit(1); // warm-up
        vm.prank(alice);
        gmer.withdraw(1);
        mer.mint(alice, 100); // test contract holds MINTER_ROLE — no prank

        uint256 min = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                vm.prank(alice);
                gmer.deposit(1);
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < min) min = perCall;
        }
        console2.log("gMER deposit (delegated holder, per call):", min);
    }

    function test_gas_withdraw() public {
        vm.prank(alice);
        gmer.delegate(alice);
        vm.prank(alice);
        gmer.deposit(1_000e18);
        vm.prank(alice);
        gmer.withdraw(1); // warm-up

        uint256 min = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            vm.prank(alice);
            gmer.deposit(100);
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                vm.prank(alice);
                gmer.withdraw(1);
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < min) min = perCall;
        }
        console2.log("gMER withdraw (per call):", min);
    }

    function test_gas_delegate_warm() public {
        _depositFor(alice, 1_000e18);
        vm.prank(alice);
        gmer.delegate(bob); // first (cold) delegation — setup, not measured
        vm.prank(alice);
        gmer.delegate(carol); // warm-up

        uint256 min = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                vm.prank(alice);
                gmer.delegate(i % 2 == 0 ? bob : carol); // real re-delegations
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < min) min = perCall;
        }
        console2.log("gMER delegate (warm re-delegate, per call):", min);
    }

    function test_gas_delegateBySig() public {
        _depositFor(alice, 1_000e18);
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(ALICE_KEY, bob, 0, block.timestamp + 1 days);
        gmer.delegateBySig(bob, 0, block.timestamp + 1 days, v, r, s); // warm-up

        uint256 nonce = 1;
        uint256 min = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                address target = nonce % 2 == 0 ? bob : carol;
                (v, r, s) = _signDelegation(ALICE_KEY, target, nonce, block.timestamp + 1 days);
                gmer.delegateBySig(target, nonce, block.timestamp + 1 days, v, r, s);
                nonce++;
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < min) min = perCall;
        }
        console2.log("gMER delegateBySig (per call):", min);
    }

    function test_gas_transfer_movesVotes() public {
        _depositFor(alice, 10_000e18);
        vm.prank(alice);
        gmer.delegate(bob);
        vm.prank(alice);
        gmer.transfer(carol, 1); // warm-up

        uint256 min = type(uint256).max;
        for (uint256 round = 0; round < 3; round++) {
            uint256 before = gasleft();
            for (uint256 i = 0; i < 10; i++) {
                vm.prank(alice);
                gmer.transfer(carol, 1);
            }
            uint256 perCall = (before - gasleft()) / 10;
            if (perCall < min) min = perCall;
        }
        console2.log("gMER transfer w/ vote movement (per call):", min);
    }

    function test_gas_getPastVotes_deepHistory() public {
        // 1,001 checkpoints for bob; measure a recent lookup (sqrt-probe
        // shortcut) vs an old lookup (full binary search).
        _depositFor(alice, 2_000e18);
        vm.prank(alice);
        gmer.delegate(bob);
        _fundAndApprove(carol, 2_000e18);
        _depositFor(carol, 2_000e18); // carol: undelegated dripper

        vm.roll(block.number + 1);
        uint256 firstTransferBlock = block.number;
        for (uint256 i = 0; i < 1000; i++) {
            vm.roll(firstTransferBlock + i);
            vm.prank(carol);
            gmer.transfer(alice, 1e18); // carol(0) → alice(delegate bob): bob +1e18
        }
        vm.roll(firstTransferBlock + 1000);
        // bob's history: 2_000e18 at the delegate block, then +1e18 per block.
        assertEq(gmer.numCheckpoints(bob), 1001);
        assertEq(gmer.getPastVotes(bob, firstTransferBlock), 2_001e18);

        gmer.getPastVotes(bob, block.number - 1); // warm-up
        uint256 minRecent = type(uint256).max;
        uint256 minOld = type(uint256).max;
        for (uint256 i = 0; i < 20; i++) {
            uint256 before = gasleft();
            gmer.getPastVotes(bob, block.number - 1);
            uint256 used = before - gasleft();
            if (used < minRecent) minRecent = used;

            before = gasleft();
            gmer.getPastVotes(bob, firstTransferBlock);
            used = before - gasleft();
            if (used < minOld) minOld = used;
        }
        console2.log("getPastVotes over 1,001 checkpoints - recent lookup:", minRecent);
        console2.log("getPastVotes over 1,001 checkpoints - oldest lookup:", minOld);
    }
}
