// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IFoundryProbe, FoundryProbe} from "../src/FoundryProbe.sol";

/// @notice Mock that rejects plain ETH transfers — targets `TransferFailed`.
/// @dev Has a function but no `receive`/`fallback`, so a value-bearing empty
///      calldata call reverts and the probe's low-level `call` returns `false`.
contract EthRejector {
    /// @notice Any function; the point is the contract rejects ETH.
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Cheatcode lab for the Foundry Workflow chapter — 16 tests.
/// @dev Every test demonstrates one cheatcode family against `FoundryProbe`:
///      prank, expectRevert, expectEmit, expectCall, warp, roll, deal, store,
///      load, snapshot, revertTo, makeAddr, assume. No gasleft()-based tests
///      (the standing `--gas-report` ban does not apply; these are correctness
///      tests). Param'd custom errors are matched with the full encoded revert
///      data — `expectRevert(selector)` alone only matches no-arg errors.
contract FoundryProbeTest is Test {
    uint256 internal constant LOCK = 100;

    FoundryProbe internal probe;
    address internal owner;
    address internal alice;
    address internal bob;

    /// @dev Owner is set by pranking the constructor, so the probe is never
    ///      owned by the test contract itself.
    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.prank(owner);
        probe = new FoundryProbe(LOCK);
    }

    function testSetValueAsOwner() public {
        vm.prank(owner);
        probe.setValue(42);
        assertEq(probe.value(), 42);
    }

    function testSetValueRevertsForNonOwner() public {
        bytes memory err = abi.encodeWithSelector(IFoundryProbe.NotOwner.selector, bob, owner);
        vm.expectRevert(err);
        vm.prank(bob);
        probe.setValue(1);
    }

    function testExpectEmitValueSet() public {
        vm.expectEmit();
        emit IFoundryProbe.ValueSet(owner, 42);
        vm.prank(owner);
        probe.setValue(42);
    }

    function testAccrualNotMature() public {
        bytes memory err = abi.encodeWithSelector(
            IFoundryProbe.AccrualNotMature.selector, block.timestamp, probe.startTs() + LOCK
        );
        vm.expectRevert(err);
        vm.prank(owner);
        probe.accrue(1e18);
    }

    function testAccrualAfterWarp() public {
        // Warp 200 seconds past deployment: lock (100) has matured.
        vm.warp(probe.startTs() + LOCK + 100);
        vm.prank(owner);
        probe.accrue(1e18); // 200 elapsed seconds × 1e18 / 1e18 = 200 units
        assertEq(probe.accrued(), 200);
        assertEq(probe.lastTs(), probe.startTs() + LOCK + 100);
    }

    function testFeesAccruedEvent() public {
        vm.warp(probe.startTs() + LOCK + 100);
        vm.expectEmit();
        emit IFoundryProbe.FeesAccrued(200, probe.startTs(), block.timestamp);
        vm.prank(owner);
        probe.accrue(1e18);
    }

    function testWarpAndRoll() public {
        uint256 ts = block.timestamp;
        uint256 height = block.number;
        vm.warp(ts + 50);
        vm.roll(height + 10);
        assertEq(block.timestamp, ts + 50);
        assertEq(block.number, height + 10);
        assertEq(probe.blocksSinceDeploy(), 10);
    }

    function testDealFundsWithdrawal() public {
        vm.deal(address(probe), 1 ether);
        assertEq(address(probe).balance, 1 ether);
        vm.prank(owner);
        probe.withdrawEth(alice, 0.5 ether);
        assertEq(alice.balance, 0.5 ether);
        assertEq(address(probe).balance, 0.5 ether);
    }

    function testWithdrawEthRevertsOnRejectingContract() public {
        EthRejector rejector = new EthRejector();
        vm.deal(address(probe), 1 wei);
        bytes memory err =
            abi.encodeWithSelector(IFoundryProbe.TransferFailed.selector, address(rejector), 1);
        vm.expectRevert(err);
        vm.prank(owner);
        probe.withdrawEth(address(rejector), 1);
    }

    function testStoreWritesOwnerSlot() public {
        // Slot 0 is `owner`. Writing it directly swaps the owner without a setter.
        vm.store(address(probe), bytes32(uint256(0)), bytes32(uint256(uint160(alice))));
        assertEq(probe.owner(), alice);
        // Alice is now owner — prank alice to exercise the swapped slot.
        vm.prank(alice);
        probe.setValue(7);
        assertEq(probe.value(), 7);
    }

    function testLoadReadsOwnerSlot() public {
        bytes32 w = vm.load(address(probe), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(w))), owner);
    }

    function testSnapshotRevertTo() public {
        vm.prank(owner);
        probe.setValue(1);
        uint256 snap = vm.snapshot();
        vm.prank(owner);
        probe.setValue(2);
        assertEq(probe.value(), 2);
        vm.revertTo(snap);
        assertEq(probe.value(), 1);
    }

    function testMakeAddrDeterministic() public {
        address a = makeAddr("bob");
        assertEq(a, bob);
        vm.label(a, "bob");
        assertEq(a, makeAddr("bob"));
    }

    function testStartPrankScope() public {
        vm.startPrank(owner);
        probe.setValue(1);
        probe.setValue(2);
        vm.stopPrank();
        assertEq(probe.value(), 2);
        // After stopPrank the caller is the test contract again — revert expected.
        bytes memory err =
            abi.encodeWithSelector(IFoundryProbe.NotOwner.selector, address(this), owner);
        vm.expectRevert(err);
        probe.setValue(3);
    }

    function testExpectCall() public {
        vm.expectCall(address(probe), abi.encodeCall(IFoundryProbe.setValue, (42)));
        vm.prank(owner);
        probe.setValue(42);
    }

    /// @dev Fuzz filter: `vm.assume` narrows the input domain before execution.
    function testAssumeFiltersDomain(uint256 x) public {
        vm.assume(x != 0);
        vm.prank(owner);
        probe.setValue(x);
        assertEq(probe.value(), x);
    }
}
