// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StaticProbe} from "../src/StaticProbe.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Lab-only mintable asset for the StaticProbe lab.
contract LabToken is ERC20 {
    constructor() ERC20("Lab", "LAB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Ch 13 lab tests: pin the BEHAVIOR of the deliberately flaggable probe.
/// @dev The point: tests prove behavior ("what the code does"), SAST flags patterns
///      ("what the code looks like"). This suite is green while Slither/Aderyn still
///      report findings on the same file — that is the triage lesson, not a paradox.
contract StaticProbeTest is Test {
    StaticProbe internal probe;
    LabToken internal token;

    // forge-std's Base.sol declares DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38 —
    // the address forge uses as tx.origin for every call in a test (verified in-run;
    // NOT the test contract address). Inherited from Test; see the sweep tests below.

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11CA);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new LabToken();
        vm.prank(owner);
        probe = new StaticProbe(token);
        token.mint(alice, 2_000e18);
        vm.startPrank(alice);
        token.approve(address(probe), type(uint256).max);
        probe.deposit(1_000e18);
        vm.stopPrank();
    }

    function test_setOwner_byOwner() public {
        vm.prank(owner);
        probe.setOwner(alice);
        assertEq(probe.owner(), alice);
    }

    // Ch 10 convention: every privileged function gets a non-privileged negative test.
    function test_setOwner_revertsForNonOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticProbe.NotAuthorized.selector, bob));
        probe.setOwner(bob);
    }

    /// @dev DOCUMENTED FINDING: zero-address is accepted here (Slither missing-zero-check).
    function test_setOwner_acceptsZero_documentedFinding() public {
        vm.prank(owner);
        probe.setOwner(address(0));
        assertEq(probe.owner(), address(0));
    }

    function test_setOwnerChecked_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(StaticProbe.ZeroAddress.selector);
        probe.setOwnerChecked(address(0));
    }

    function test_deposit_creditsBalance() public {
        vm.prank(alice);
        probe.deposit(500e18);
        assertEq(probe.balances(alice), 1_500e18);
        assertEq(token.balanceOf(address(probe)), 1_500e18);
    }

    function test_withdraw_paysOut() public {
        vm.prank(alice);
        probe.withdraw(400e18);
        assertEq(probe.balances(alice), 600e18);
        assertEq(token.balanceOf(alice), 1_400e18); // 1_000e18 remaining + 400e18 paid out
    }

    function test_withdraw_revertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticProbe.InsufficientBalance.selector, 1_000e18, 2_000e18)
        );
        probe.withdraw(2_000e18);
    }

    function test_withdrawChecked_paysOut_withReturndataGate() public {
        vm.prank(alice);
        probe.withdrawChecked(400e18);
        assertEq(probe.balances(alice), 600e18);
        assertEq(token.balanceOf(alice), 1_400e18);
    }

    /// @dev tx.origin in forge is the DEFAULT SENDER (0x1804c8AB…), not the test
    ///      contract and not the pranked msg.sender. So the owner (an EOA-shaped
    ///      address) can never satisfy the check from the harness — the check is
    ///      about an address the contract author does not control.
    function test_sweepByOrigin_reverts_whenTxOriginNotOwner() public {
        vm.prank(owner); // msg.sender is owner; tx.origin is still the default sender
        vm.expectRevert(abi.encodeWithSelector(StaticProbe.NotAuthorized.selector, tx.origin));
        probe.sweepByOrigin(bob);
    }

    /// @dev The phishing shape, demonstrated: a probe owned by the default sender is
    ///      sweepable by ANY caller, because authorization checks tx.origin. In
    ///      production this is the "owner clicks one malicious tx, drainer calls
    ///      sweepByOrigin, tx.origin == owner, pass" vector.
    function test_sweepByOrigin_succeeds_whenTxOriginIsOwner() public {
        vm.prank(DEFAULT_SENDER);
        StaticProbe probe2 = new StaticProbe(token);
        vm.prank(alice);
        token.transfer(address(probe2), 100e18);
        vm.prank(alice); // msg.sender is irrelevant — tx.origin authorizes
        probe2.sweepByOrigin(bob);
        assertEq(token.balanceOf(bob), 100e18);
    }

    function test_sweepByOrigin_revert_leavesStateUntouched() public {
        uint256 before = token.balanceOf(bob);
        vm.expectRevert();
        probe.sweepByOrigin(bob);
        assertEq(token.balanceOf(bob), before);
    }
}
