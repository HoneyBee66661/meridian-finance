// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MeVDesignLab} from "../src/MeVDesignLab.sol";
import {IMeVDesignLab} from "../src/IMeVDesignLab.sol";

contract MeVDesignLabTest is Test {
    MeVDesignLab internal lab;

    function setUp() public {
        lab = new MeVDesignLab();
        // default timestamp is 1; deadlines: commit=3601, reveal=3601, settle=7201
        // (reveal opens the moment commit closes — no dead hour)
    }

    function _afterSettle() internal {
        vm.warp(block.timestamp + 4 hours + 1);
    }

    /// @dev Commit, wait, reveal — the highest bid wins.
    function testAuctionFlow() public {
        bytes32 c1 = keccak256(abi.encode(address(0xA), 100 ether, bytes32("s1")));
        bytes32 c2 = keccak256(abi.encode(address(0xB), 200 ether, bytes32("s2")));
        vm.prank(address(0xA));
        lab.commitBid(c1);
        vm.prank(address(0xB));
        lab.commitBid(c2);
        vm.warp(block.timestamp + 1 hours + 30 minutes); // past commit deadline, inside reveal window

        vm.prank(address(0xA));
        lab.revealBid(100 ether, bytes32("s1"));
        vm.prank(address(0xB));
        lab.revealBid(200 ether, bytes32("s2"));
        _afterSettle(); // past reveal window
        lab.settleAuction();
        (,, address winner, uint256 bid) = lab.auctionState();
        assertEq(winner, address(0xB));
        assertEq(bid, 200 ether);
    }

    /// @dev A bidder who commits but never reveals loses — the auction has no
    ///      winner and settlement reverts with NoBids.
    function testNoRevealLoses() public {
        bytes32 c1 = keccak256(abi.encode(address(0xA), 100 ether, bytes32("s1")));
        vm.prank(address(0xA));
        lab.commitBid(c1);
        _afterSettle();
        vm.expectRevert(IMeVDesignLab.NoBids.selector);
        lab.settleAuction();
    }

    /// @dev Bids cannot be revealed before the reveal window opens.
    function testRevealTooEarly() public {
        bytes32 c1 = keccak256(abi.encode(address(0xA), 100 ether, bytes32("s1")));
        vm.prank(address(0xA));
        lab.commitBid(c1);
        vm.warp(block.timestamp + 30 minutes);
        vm.expectRevert(); // RevealTooEarly
        vm.prank(address(0xA));
        lab.revealBid(100 ether, bytes32("s1"));
    }

    /// @dev A wrong salt fails the commitment check.
    function testWrongSaltRejected() public {
        bytes32 c1 = keccak256(abi.encode(address(0xA), 100 ether, bytes32("s1")));
        vm.prank(address(0xA));
        lab.commitBid(c1);
        vm.warp(block.timestamp + 1 hours + 30 minutes); // inside reveal window, before settle
        vm.expectRevert(); // NotWinner (commitment mismatch)
        vm.prank(address(0xA));
        lab.revealBid(100 ether, bytes32("WRONG"));
    }
}
