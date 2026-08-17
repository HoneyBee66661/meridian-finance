// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MeVLab} from "../src/MeVLab.sol";
import {IMeVLab} from "../src/IMeVLab.sol";

contract MeVLabTest is Test {
    MeVLab internal lab;

    function setUp() public {
        lab = new MeVLab(address(this));
    }

    /// @dev The health-factor arithmetic: liquidatable when D > C·P·τ.
    ///      Price is WAD-scaled (2500e18) to match collateral/debt WAD.
    ///      D=100_001 > C·P·τ = 100_000 exactly (strict >).
    function testLiquidatable() public {
        assertTrue(lab.isLiquidatable(50 ether, 100_001 ether, 2500e18, 8000));
    }

    /// @dev Healthy when the position is above the threshold.
    function testHealthy() public {
        assertFalse(lab.isLiquidatable(50 ether, 50_000 ether, 2500e18, 8000));
    }

    /// @dev Bonus is the extractable value.
    function testBonus() public {
        assertEq(lab.liquidationBonus(100_000 ether, 500), 5_000 ether); // 5%
    }

    /// @dev Only the liquidator may enter the (lab) race.
    function testLiquidatorOnly() public {
        vm.expectRevert(abi.encodeWithSelector(IMeVLab.NotLiquidator.selector, address(0xBAD)));
        vm.prank(address(0xBAD));
        lab.tryLiquidate(50 ether, 100_000 ether, 2500e18);
    }
}
