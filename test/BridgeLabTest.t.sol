// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BridgeLab} from "../src/BridgeLab.sol";
import {IBridgeLab} from "../src/IBridgeLab.sol";

contract BridgeLabTest is Test {
    BridgeLab internal lab;
    address internal source = address(0x50C4CE);

    function setUp() public {
        lab = new BridgeLab(source);
    }

    /// @dev Only the authorized source may submit.
    function testUnauthorizedSourceRejected() public {
        bytes memory payload = abi.encodeCall(lab.applyMarketUpdate, (address(1), 1e18));
        vm.expectRevert(
            abi.encodeWithSelector(IBridgeLab.UnauthorizedSender.selector, address(0xBEEF))
        );
        vm.prank(address(0xBEEF));
        lab.executeMessage(address(this), payload);
    }

    /// @dev Non-whitelisted payload reverts (the Nomad shape).
    function testNonWhitelistedPayloadRejected() public {
        bytes memory bad = abi.encodeWithSignature("setAdmin(address)", address(1));
        vm.expectRevert(
            abi.encodeWithSelector(IBridgeLab.UnauthorizedPayload.selector, bytes4(bad))
        );
        vm.prank(source);
        lab.executeMessage(address(this), bad);
    }

    /// @dev Same message twice = replay.
    function testReplayRejected() public {
        bytes memory payload = abi.encodeCall(lab.applyMarketUpdate, (address(1), 1e18));
        vm.prank(source);
        lab.executeMessage(address(this), payload);

        bytes32 h = keccak256(abi.encode(address(this), payload));
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.MessageReplay.selector, h));
        vm.prank(source);
        lab.executeMessage(address(this), payload);
    }

    /// @dev Whitelisted payload executes exactly once.
    function testWhitelistedExecutes() public {
        bytes memory payload = abi.encodeCall(lab.applyCollateralFactor, (0.8e18));
        vm.prank(source);
        lab.executeMessage(address(this), payload);

        bytes32 h = keccak256(abi.encode(address(this), payload));
        assertTrue(lab.executed(h));
    }

    /// @dev Target functions are not public entry points: only the self-call
    ///      from executeMessage may invoke them.
    function testDirectTargetCallRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(IBridgeLab.UnauthorizedSender.selector, address(this))
        );
        lab.applyMarketUpdate(address(1), 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(IBridgeLab.UnauthorizedSender.selector, address(this))
        );
        lab.applyCollateralFactor(0.8e18);
    }

    /// @dev Payloads shorter than a selector revert with the custom error,
    ///      not an opaque slice panic.
    function testShortPayloadRejected() public {
        bytes memory short = hex"aabbcc";
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.UnauthorizedPayload.selector, bytes4(0)));
        vm.prank(source);
        lab.executeMessage(address(this), short);
    }

    /// @dev Destination-side re-validation: out-of-bounds arguments revert
    ///      even though the selector is whitelisted.
    function testOutOfBoundsRejected() public {
        bytes memory payload = abi.encodeCall(lab.applyMarketUpdate, (address(1), 2e27));
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.ValueOutOfBounds.selector, 2e27));
        vm.prank(source);
        lab.executeMessage(address(this), payload);
    }
}
