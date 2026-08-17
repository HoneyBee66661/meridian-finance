// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RollupLab} from "../src/RollupLab.sol";
import {IRollupLab} from "../src/IRollupLab.sol";

contract RollupLabTest is Test {
    RollupLab internal lab;

    function setUp() public {
        lab = new RollupLab();
    }

    /// @dev A batch cannot finalize before the window closes.
    function testCannotFinalizeEarly() public {
        lab.submitBatch(keccak256("root"), "");
        vm.expectRevert(IRollupLab.ChallengeWindowOpen.selector);
        lab.finalizeBatch(0);
    }

    /// @dev After the window, an unchallenged batch finalizes.
    function testFinalizesAfterWindow() public {
        lab.submitBatch(keccak256("root"), "");
        vm.warp(block.timestamp + 7 days + 1);
        lab.finalizeBatch(0);
    }

    /// @dev A challenged batch can never finalize.
    function testChallengedBatchNeverFinalizes() public {
        lab.submitBatch(keccak256("root"), "");
        lab.challengeBatch(0, "");
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(); // InvalidStateRoot
        lab.finalizeBatch(0);
    }

    /// @dev Double finalization reverts.
    function testDoubleFinalizeReverts() public {
        lab.submitBatch(keccak256("root"), "");
        vm.warp(block.timestamp + 7 days + 1);
        lab.finalizeBatch(0);
        vm.expectRevert(); // AlreadyFinalized
        lab.finalizeBatch(0);
    }
}
