// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InvariantLab} from "../src/InvariantLab.sol";
import {InvariantLabHandler} from "./InvariantLabHandler.sol";

/// @title InvariantLabInvariantTest
/// @notice Ghost-accounting invariant suite for InvariantLab (Ch 12 lock).
/// @dev Green in floor mode (default). `foundry.toml` pins
///      `[invariant] runs = 256, fail_on_revert = true`; the handler
///      pre-checks every revert edge so sequences stay valid.
///      Flip `useCeil` (e.g. via a handler passthrough) to observe the
///      conversionsNeverGain failure this suite detects.
contract InvariantLabInvariantTest is Test {
    InvariantLab internal lab;
    InvariantLabHandler internal handler;

    function setUp() public {
        lab = new InvariantLab();
        handler = new InvariantLabHandler(lab);
        targetContract(address(handler));
    }

    /// @dev Conservation: the tracked total equals deposits minus redemptions.
    function invariant_conservation() public view {
        assertEq(lab.totalAssets(), handler.ghost_deposited() - handler.ghost_redeemed());
    }

    /// @dev conversionsNeverGain, cumulatively: value redeemed never exceeds value deposited.
    function invariant_noValueExtraction() public view {
        assertLe(handler.ghost_redeemed(), handler.ghost_deposited());
    }
}
