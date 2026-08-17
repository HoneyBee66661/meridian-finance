// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessagingLab} from "../src/MessagingLab.sol";
import {IMessagingLab} from "../src/IMessagingLab.sol";

contract MessagingLabTest is Test {
    MessagingLab internal lab;
    address internal source = address(0x50C);
    uint256 internal constant MAX = 1000 ether;

    /// @dev Arbitrum L1→L2 alias offset (Ch 31/32 aliasing note).
    uint160 internal constant L1_TO_L2_ALIAS_OFFSET =
        uint160(0x1111000000000000000000000000000000001111);

    /// @dev The address canonical L1→L2 delivery actually calls from.
    function aliased(address a) internal pure returns (address) {
        unchecked {
            return address(uint160(a) + L1_TO_L2_ALIAS_OFFSET);
        }
    }

    function setUp() public {
        lab = new MessagingLab(source, MAX);
    }

    /// @dev Unauthorized source rejected.
    function testUnauthorizedSource() public {
        bytes memory p = abi.encodeCall(lab.applyTransfer, (address(1), 1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IMessagingLab.UnauthorizedSource.selector, address(0xBAD))
        );
        vm.prank(address(0xBAD));
        lab.receiveMessage(source, p);
    }

    /// @dev The raw L1 address never matches — only the aliased sender passes.
    function testRawSourceRejected() public {
        bytes memory p = abi.encodeCall(lab.applyTransfer, (address(1), 1 ether));
        vm.expectRevert(abi.encodeWithSelector(IMessagingLab.UnauthorizedSource.selector, source));
        vm.prank(source);
        lab.receiveMessage(source, p);
    }

    /// @dev Replay rejected.
    function testReplay() public {
        bytes memory p = abi.encodeCall(lab.applyTransfer, (address(1), 1 ether));
        vm.prank(aliased(source));
        lab.receiveMessage(source, p);

        bytes32 h = keccak256(abi.encode(source, p));
        vm.expectRevert(abi.encodeWithSelector(IMessagingLab.Replay.selector, h));
        vm.prank(aliased(source));
        lab.receiveMessage(source, p);
    }

    /// @dev Over-limit amount rejected (destination re-validation).
    function testAmountBound() public {
        bytes memory p = abi.encodeCall(lab.applyTransfer, (address(1), MAX + 1));
        vm.expectRevert(abi.encodeWithSelector(IMessagingLab.InvalidAmount.selector, MAX + 1, MAX));
        vm.prank(aliased(source));
        lab.receiveMessage(source, p);
    }

    /// @dev Valid message accepted.
    function testValidMessage() public {
        bytes memory p = abi.encodeCall(lab.applyTransfer, (address(1), 1 ether));
        vm.prank(aliased(source));
        lab.receiveMessage(source, p);
    }
}
