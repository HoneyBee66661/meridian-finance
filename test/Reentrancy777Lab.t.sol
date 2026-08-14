// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ITokenSecurityLab} from "../src/ITokenSecurityLab.sol";
import {HookToken, ReentrantRewardPool, FixedRewardPool, ReentrantAttacker, PassiveHookRecipient, WrongMagicRecipient} from "../src/Reentrancy777Lab.sol";

/// @notice Ch 17 EIP-777-style callback reentrancy demo (SIMPLIFIED, labeled).
///         A hook token whose transfers fire `tokensReceived` on the recipient
///         drains a pool that updates state AFTER the payout transfer — the
///         same class as the Aug 2019 imBTC/Uniswap v1 incident. The CEI-fixed
///         pool defeats the same attacker. Gas probe at the bottom.
contract Reentrancy777LabTest is Test {
    HookToken internal token;
    ReentrantRewardPool internal naivePool;
    FixedRewardPool internal fixedPool;
    ReentrantAttacker internal attacker;
    PassiveHookRecipient internal passive;
    WrongMagicRecipient internal wrong;

    address internal alice;
    address internal eoa;

    function setUp() public {
        token = new HookToken();
        naivePool = new ReentrantRewardPool(token);
        fixedPool = new FixedRewardPool(token);
        attacker = new ReentrantAttacker(naivePool);
        passive = new PassiveHookRecipient();
        wrong = new WrongMagicRecipient();
        alice = makeAddr("alice");
        eoa = makeAddr("eoa");
    }

    // ── hook mechanics ──────────────────────────────────────────────────────

    function test_hookToken_firesTokensReceivedOnContract() public {
        token.mint(alice, 100);
        vm.prank(alice);
        token.transfer(address(passive), 10);

        assertEq(token.balanceOf(address(passive)), 10);
        assertEq(passive.hookCount(), 1);
    }

    function test_hookToken_transferToEOA_noHook() public {
        token.mint(alice, 100);
        vm.prank(alice);
        token.transfer(eoa, 10);

        assertEq(token.balanceOf(eoa), 10);
        assertEq(token.balanceOf(alice), 90);
    }

    /// @dev The mandatory callback is the DoS surface: a recipient whose hook
    ///      returns the wrong magic value rejects every transfer to it.
    function test_hookToken_revertsOnWrongMagic() public {
        token.mint(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(ITokenSecurityLab.HookNotAccepted.selector, address(wrong)));
        vm.prank(alice);
        token.transfer(address(wrong), 10);
    }

    // ── the reentrancy drain ────────────────────────────────────────────────

    /// @dev The attack: the pool holds 5 HOOK and owes the attacker 1. The
    ///      attacker's `tokensReceived` re-enters `claim` while the outer
    ///      transfer is in flight and the claimable balance is un-zeroed, so
    ///      the whole pool drains. Reward owed: 1. Drained: 5.
    function test_naivePool_drainedByHook() public {
        token.mint(address(naivePool), 5);
        naivePool.grantReward(address(attacker), 1);

        attacker.attack();

        assertEq(attacker.drained(), 5);
        assertEq(token.balanceOf(address(naivePool)), 0);
        assertEq(token.balanceOf(address(attacker)), 5);
    }

    /// @dev The CEI fix: clear the balance BEFORE the transfer. The attacker's
    ///      re-entrant `claim` reads a zeroed balance and reverts, rolling back
    ///      the whole attack call. At most the owed amount can ever move.
    function test_fixedPool_attackReverts_noDrain() public {
        token.mint(address(fixedPool), 5);
        ReentrantAttacker fixedAttacker = new ReentrantAttacker(fixedPool);
        fixedPool.grantReward(address(fixedAttacker), 1);

        // The CEI fix means the re-entrant claim sees a zeroed balance and
        // reverts; the revert propagates out of the hook, so the whole attack
        // call reverts and the pool keeps its 5.
        vm.expectRevert(abi.encodeWithSelector(ITokenSecurityLab.HookNotAccepted.selector, address(fixedAttacker)));
        fixedAttacker.attack();

        assertEq(fixedAttacker.drained(), 0);
        assertEq(token.balanceOf(address(fixedPool)), 5);
    }

    // ── gas probe (log-only, warm-up first) ─────────────────────────────────

    /// @dev The price of the mandatory hook: a transfer to a hook-bearing
    ///      contract pays an extra external CALL into the recipient vs an EOA
    ///      transfer. Loop-amplified min-deltas.
    function test_gasProbe_hookToken_EOAvsContract() public {
        token.mint(alice, 1_000_000);
        vm.prank(alice);
        token.transfer(eoa, 1); // warm-up
        vm.prank(alice);
        token.transfer(address(passive), 1);
        uint256 bestEoa = type(uint256).max;
        uint256 bestHook = type(uint256).max;
        for (uint256 i = 0; i < 10; ++i) {
            uint256 g0 = gasleft();
            vm.prank(alice);
            token.transfer(eoa, 1);
            uint256 e = g0 - gasleft();
            if (e < bestEoa) bestEoa = e;
            g0 = gasleft();
            vm.prank(alice);
            token.transfer(address(passive), 1);
            uint256 h = g0 - gasleft();
            if (h < bestHook) bestHook = h;
        }
        console2.log("hook token transfer to EOA gas (min of 10):", bestEoa);
        console2.log("hook token transfer to contract gas (min of 10):", bestHook);
    }
}
