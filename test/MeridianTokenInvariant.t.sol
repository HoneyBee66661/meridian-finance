// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianTokenHandler} from "./MeridianTokenHandler.sol";

/// @notice Ch 14 invariant suite for MeridianToken — accounting conservation
///         across mint/transfer/burn sequences (256 runs × 64 depth per the
///         [invariant] config).
/// @dev The complete holder set is {handler, user0, user1, user2}: initial
///      supply is zero at deployment, the minter mints only to the handler,
///      and nobody else can receive tokens. The invariant recomputes the sum
///      of ALL balances from that fixed set and pins it to totalSupply — a
///      conservation check that would catch any hypothetical mint/destroy bug
///      in a transfer path (there are none in OZ's audited base; the suite
///      exists to prove the property holds on Meridian's actual inheritance).
contract MeridianTokenInvariantTest is Test {
    MeridianToken internal token;
    MeridianTokenHandler internal handler;

    address internal owner;
    address internal minter;
    address internal user0;
    address internal user1;
    address internal user2;

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        user0 = makeAddr("user0");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Zero initial supply; the recipient must be non-zero (constructor
        // guard), so the owner stands in as the (empty) initial recipient.
        token = new MeridianToken(owner, minter, owner, 0);
        handler = new MeridianTokenHandler(token, user0, user1, user2);

        // Read the role BEFORE vm.prank — evaluating `token.MINTER_ROLE()` as
        // a call argument would consume the prank (Ch 14 finding).
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(owner);
        token.grantRole(minterRole, address(handler));
        vm.prank(minter);
        token.mint(address(handler), 1e24); // seed the handler as sole holder

        targetContract(address(handler));
    }

    /// @dev Sum of ALL holders must equal totalSupply — no value appears or
    ///      disappears through any op sequence.
    function invariant_holdersSumEqualsTotalSupply() public view {
        uint256 sum = token.balanceOf(address(handler)) + token.balanceOf(user0)
            + token.balanceOf(user1) + token.balanceOf(user2);
        assertEq(sum, token.totalSupply(), "holder sum != totalSupply");
    }
}
