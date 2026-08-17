// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InvariantLab} from "../src/InvariantLab.sol";
import {IInvariantLab} from "../src/IInvariantLab.sol";

contract InvariantLabTest is Test {
    InvariantLab internal lab;

    function setUp() public {
        lab = new InvariantLab();
    }

    /// @dev Round-trip never gains in the floor canon (conversionsNeverGain).
    function testRoundTripNeverGains(uint256 assets) public {
        assets = bound(assets, 1, 1e30);
        assertLe(lab.roundTrip(assets), assets, "conversionsNeverGain violated");
    }

    /// @dev Deposit then redeem (floor) returns no more than deposited.
    function testDepositRedeemNoGain() public {
        uint256 deposited = 1000 ether;
        lab.deposit(deposited);
        uint256 back = lab.redeem(lab.totalShares());
        assertLe(back, deposited);
    }

    /// @dev The ceil variant violates the invariant — demonstration only.
    ///      Keep this out of CI; it is the Balancer failure shape at 1 wei.
    function testCeilVariantViolates_expectedFailure() public {
        lab.setUseCeil(true);
        lab.deposit(1000 ether);
        uint256 shares = lab.totalShares();
        // redeem HALF — the ceil conversion grants +1 wei on the assets side,
        // diluting the remaining holders (the Balancer shape at 1 wei scale)
        uint256 assets = lab.redeem(shares / 2);
        assertGt(assets, 500 ether, "ceil variant should extract value per conversion");
        // fair value of half the shares is exactly 500 ether
        assertEq(assets, 500 ether + 1, "1 wei extracted from remaining holders");
    }

    /// @dev Zero-share deposit reverts.
    function testZeroShareDepositReverts() public {
        lab.deposit(1000 ether);
        // at a 1:1 price floor mode, 0 assets -> 0 shares
        vm.expectRevert(IInvariantLab.ZeroShares.selector);
        lab.deposit(0);
    }

    /// @dev Multiple deposits keep conversion monotonic (no free shares).
    function testMonotonicDeposits() public {
        lab.deposit(100 ether);
        lab.deposit(50 ether);
        lab.deposit(25 ether);
        assertEq(lab.totalShares(), 175 ether);
        assertEq(lab.totalAssets(), 175 ether);
    }
}
