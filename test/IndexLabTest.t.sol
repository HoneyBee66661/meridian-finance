// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexLab} from "../src/IndexLab.sol";
import {IIndexLab} from "../src/IIndexLab.sol";

contract IndexLabTest is Test {
    IndexLab internal lab;

    function setUp() public {
        lab = new IndexLab();
    }

    /// @dev Borrow emits the Borrow event with the indexed user (topic0+1).
    function testBorrowEventShape() public {
        vm.expectEmit(true, false, false, true);
        emit IIndexLab.Borrow(address(this), 100 ether, block.number);
        lab.borrow(100 ether);
    }

    /// @dev Repay emits the Repay event.
    function testRepayEventShape() public {
        lab.borrow(100 ether);
        vm.expectEmit(true, false, false, true);
        emit IIndexLab.Repay(address(this), 40 ether, block.number);
        lab.repay(40 ether);
    }

    /// @dev Liquidation emits with two indexed args (user, liquidator).
    function testLiquidationEventShape() public {
        address user = address(0xABC);
        vm.prank(user);
        lab.borrow(100 ether);
        vm.expectEmit(true, true, false, true);
        emit IIndexLab.Liquidation(user, address(this), 100 ether, 100 ether);
        lab.liquidate(user, 100 ether);
    }

    /// @dev The fold is replayable: debtOf equals the event-derived value.
    function testFoldConsistency() public {
        lab.borrow(100 ether);
        lab.borrow(50 ether);
        lab.repay(30 ether);
        assertEq(lab.debtOf(address(this)), 120 ether);
    }
}
