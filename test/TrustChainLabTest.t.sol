// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TrustChainLab} from "../src/TrustChainLab.sol";
import {ITrustChainLab} from "../src/ITrustChainLab.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TrustChainLabTest is Test {
    TrustChainLab internal lab;
    address internal pauser = address(0x1A55E);
    address internal operator = address(0x0FEA);
    address internal risk = address(0x81A5);
    address internal admin = address(0xAD11);

    function setUp() public {
        lab = new TrustChainLab(); // deployer (this test) = admin
        lab.grantRole(lab.PAUSER_ROLE(), pauser);
        lab.grantRole(lab.OPERATOR_ROLE(), operator);
        lab.grantRole(lab.RISK_ROLE(), risk);
    }

    /// @dev Pauser can pause; operator cannot pause.
    function testPauserOnlyCanPause() public {
        vm.prank(pauser);
        lab.pause();
        assertTrue(lab.paused());
    }

    /// @dev Operator cannot pause — separated powers.
    function testOperatorCannotPause() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                operator,
                lab.PAUSER_ROLE()
            )
        );
        vm.prank(operator);
        lab.pause();
    }

    /// @dev Operator can unpause; pauser cannot — separation is symmetric.
    function testOperatorUnpauses() public {
        vm.prank(pauser);
        lab.pause();
        vm.prank(operator);
        lab.unpause();
        assertFalse(lab.paused());
    }

    /// @dev Pauser cannot unpause.
    function testPauserCannotUnpause() public {
        vm.prank(pauser);
        lab.pause();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                pauser,
                lab.OPERATOR_ROLE()
            )
        );
        vm.prank(pauser);
        lab.unpause();
    }

    /// @dev Risk change is two-step: RISK schedules, ADMIN executes.
    function testTwoStepRiskChange() public {
        vm.prank(risk);
        lab.scheduleCollateralFactor(0.8e18);
        lab.executeCollateralFactor(); // caller = this test = DEFAULT_ADMIN_ROLE
        assertEq(lab.collateralFactor(), 0.8e18);
    }

    /// @dev RISK cannot execute directly — the two-step chain is enforced.
    function testRiskCannotExecute() public {
        vm.prank(risk);
        lab.scheduleCollateralFactor(0.8e18);
        vm.expectRevert(); // onlyRole(DEFAULT_ADMIN_ROLE) — risk lacks it
        vm.prank(risk);
        lab.executeCollateralFactor();
    }

    /// @dev Unpause when not paused reverts.
    function testUnpauseWhenNotPaused() public {
        vm.expectRevert(ITrustChainLab.NotPaused.selector);
        vm.prank(operator);
        lab.unpause();
    }
}
