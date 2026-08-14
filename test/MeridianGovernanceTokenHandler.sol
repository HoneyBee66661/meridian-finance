// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianGovernanceToken} from "../src/MeridianGovernanceToken.sol";

/// @notice Ch 15 invariant handler for MeridianGovernanceToken (gMER). Four ops
///         — deposit / withdraw / transfer / delegate — over three actors. Every
///         revert edge is pre-checked by clamping (`bound`, per the Ch 12 rule:
///         no `vm.assume` in handlers, `[invariant] fail_on_revert = true` holds).
/// @dev The handler holds MINTER_ROLE on MER so `deposit` can always be funded:
///      MER supply is not part of the pinned invariant — only the wrapper
///      conservation (gMER supply == MER held) is, and that is independent of
///      how much MER exists.
contract MeridianGovernanceTokenHandler is Test {
    MeridianGovernanceToken internal gmer;
    MeridianToken internal mer;

    address internal alice;
    address internal bob;
    address internal carol;
    address[] internal actors;

    /// @dev Cap on a single deposit so cumulative supply stays far below the
    ///      2^208 - 1 checkpoint cap (16,384 sequences × 1e30 ≪ 4.1e62).
    uint256 internal constant MAX_DEPOSIT = 1e30;

    constructor(MeridianGovernanceToken gmer_, MeridianToken mer_) {
        gmer = gmer_;
        mer = mer_;
        alice = makeAddr("h_alice");
        bob = makeAddr("h_bob");
        carol = makeAddr("h_carol");
        actors = [alice, bob, carol];
    }

    function _actor(uint256 index) internal view returns (address) {
        return actors[index % actors.length];
    }

    /// @dev The actor set, for the invariant suite's approval setup.
    function actorsList() external view returns (address[] memory) {
        return actors;
    }

    /// @dev Deposit `amount` MER (minted on demand) into the wrapper. Never
    ///      reverts: the handler mints any balance shortfall and the actors
    ///      pre-approved the wrapper in the invariant suite's setUp.
    function deposit(uint256 actorIndex, uint256 amount) external {
        address actor = _actor(actorIndex);
        amount = bound(amount, 0, MAX_DEPOSIT);
        uint256 bal = mer.balanceOf(actor);
        if (bal < amount) {
            mer.mint(actor, amount - bal); // handler holds MINTER_ROLE
        }
        vm.prank(actor);
        gmer.deposit(amount);
    }

    /// @dev Withdraw `amount` gMER. Never reverts: clamped to the actor's balance.
    function withdraw(uint256 actorIndex, uint256 amount) external {
        address actor = _actor(actorIndex);
        amount = bound(amount, 0, gmer.balanceOf(actor));
        vm.prank(actor);
        gmer.withdraw(amount);
    }

    /// @dev Transfer `amount` gMER between actors. Never reverts: clamped to the
    ///      sender's balance (self-transfers are legal ERC-20, no extra edge).
    function transfer(uint256 fromIndex, uint256 toIndex, uint256 amount) external {
        address from = _actor(fromIndex);
        address to = _actor(toIndex);
        amount = bound(amount, 0, gmer.balanceOf(from));
        vm.prank(from);
        gmer.transfer(to, amount);
    }

    /// @dev Delegate all of the actor's voting units to another actor. OZ Votes
    ///      allows any delegatee (including self), so this never reverts.
    function delegate(uint256 actorIndex, uint256 targetIndex) external {
        address actor = _actor(actorIndex);
        address target = _actor(targetIndex);
        vm.prank(actor);
        gmer.delegate(target);
    }
}
