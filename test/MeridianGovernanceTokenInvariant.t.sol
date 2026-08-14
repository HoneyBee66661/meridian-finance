// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianGovernanceToken} from "../src/MeridianGovernanceToken.sol";
import {MeridianGovernanceTokenHandler} from "./MeridianGovernanceTokenHandler.sol";

/// @notice Ch 15 invariant suite for the gMER wrapper. Pins the wrapper
///         conservation invariant — gMER totalSupply always equals the MER the
///         wrapper holds — over a 4-op sequence (deposit/withdraw/transfer/
///         delegate) × 256 runs × 64 depth = 16,384 calls.
/// @dev The invariant is meaningful because deposit/withdraw mint/burn 1:1 and
///      transfers never touch the underlying: any accounting bug in the wrapper
///      (mint without pull, burn without release, fee on either side) breaks it
///      immediately. Deliberately NOT pinned here: vote-delegation accounting
///      (that is a per-delegate ledger; sequence-exploration adds little over
///      the unit-level vote-movement pins — same scoping note as Ch 14).
contract MeridianGovernanceTokenInvariant is Test {
    MeridianToken internal mer;
    MeridianGovernanceToken internal gmer;
    MeridianGovernanceTokenHandler internal handler;

    address internal owner;
    address internal treasury;

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");

        // Zero initial MER supply: the wrapper starts empty and every gMER that
        // ever exists must be backed by a deposit — the strongest form of the
        // conservation invariant. The test contract bootstraps MINTER_ROLE and
        // hands it to the handler right after deploy (avoids a constructor cycle
        // between handler ↔ mer).
        mer = new MeridianToken(owner, address(this), treasury, 0);
        gmer = new MeridianGovernanceToken(address(mer), "Meridian Governance", "gMER");
        handler = new MeridianGovernanceTokenHandler(gmer, mer);

        // The handler mints MER for its actors; grant it MINTER_ROLE.
        // NOTE: the role read is hoisted — a next-call cheatcode is consumed by
        // argument-evaluation calls (Ch 14 finding #3): `vm.prank(owner);
        // mer.grantRole(mer.MINTER_ROLE(), ...)` would prank the VIEW call.
        bytes32 minterRole = mer.MINTER_ROLE();
        vm.prank(owner);
        mer.grantRole(minterRole, address(handler));

        // One-time max approval from every actor to the wrapper.
        address[] memory actors = handler.actorsList();
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            mer.approve(address(gmer), type(uint256).max);
        }

        targetContract(address(handler));
    }

    /// @dev The wrapper invariant: gMER supply is exactly the MER it holds.
    function invariant_wrapperConservation() public view {
        assertEq(
            gmer.totalSupply(),
            mer.balanceOf(address(gmer)),
            "wrapper conservation: every gMER must be backed by deposited MER"
        );
    }
}
