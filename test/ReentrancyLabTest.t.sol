// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReentrancyLab} from "../src/ReentrancyLab.sol";
import {IReentrancyLab} from "../src/IReentrancyLab.sol";

/// @dev Reentrant attacker: re-enters on receive(), choosing the method.
///      Single re-entry with (bal - msg.value): msg.value is the ETH the lab
///      just pushed — the outer frame's withdrawal amount — so the re-entry
///      takes exactly the balance the outer frame will NOT decrement.
///      Against the naive withdraw the balance read is STALE (the decrement
///      happens after the call), so this lands the double-spend and drains
///      the full balance; against CEI it is capped at the legal remainder.
contract ReentrantAttacker {
    ReentrancyLab internal lab;
    bool public useCEI;
    uint256 public depth;

    constructor(ReentrancyLab lab_) {
        lab = lab_;
    }

    receive() external payable {
        depth++;
        uint256 bal = lab.balanceOf(address(this));
        if (bal > msg.value && depth < 2) {
            uint256 amt = bal - msg.value;
            if (useCEI) lab.withdrawCEI(amt);
            else lab.withdraw(amt);
        }
    }

    function attack() external payable {
        lab.withdraw(1 ether);
    }

    function attackCEI() external payable {
        lab.withdrawCEI(1 ether);
    }

    function setUseCEI(bool v) external {
        useCEI = v;
    }
}

/// @dev Attacker whose receive() re-enters via the guarded twin (cross-function).
contract CrossFunctionAttacker {
    ReentrancyLab internal lab;
    address internal victim;

    constructor(ReentrancyLab lab_, address victim_) {
        lab = lab_;
        victim = victim_;
    }

    receive() external payable {
        if (lab.balanceOf(address(this)) > 0) lab.transferTo(victim, 1);
    }

    function attack() external payable {
        lab.withdrawGuarded(msg.value);
    }
}

contract ReentrancyLabTest is Test {
    ReentrancyLab internal lab;
    ReentrantAttacker internal attacker;
    CrossFunctionAttacker internal crossAttacker;
    address internal victim = address(0xBEEF);

    function setUp() public {
        lab = new ReentrancyLab();
        attacker = new ReentrantAttacker(lab);
        crossAttacker = new CrossFunctionAttacker(lab, victim);
        // lab needs ETH to push; attackers need ETH to deposit
        vm.deal(address(lab), 200 ether);
        vm.deal(address(attacker), 50 ether);
        vm.deal(address(crossAttacker), 50 ether);
        // fund the attackers through the honest deposit() path — the drain
        // test must attack against a REAL balance entry (audit A2), and the
        // deposit is the audit-mandated funding mechanism for it
        vm.prank(address(attacker));
        lab.deposit{value: 40 ether}();
        vm.prank(address(crossAttacker));
        lab.deposit{value: 40 ether}();
        // deployer keeps its constructor balance (100 ether) for the atomic test
    }

    /// @dev Classic reentrancy against a REAL balance entry: the naive
    ///      withdraw checks the balance BEFORE the decrement, so the
    ///      re-entering frame reads the stale full balance, the balance
    ///      check passes on re-entry (no guard involved), the double-spend
    ///      lands, and the FULL balance is drained — the tx SUCCEEDS.
    function testClassicReentrancyDrains() public {
        uint256 bal = lab.balanceOf(address(attacker));
        uint256 before = address(attacker).balance;
        attacker.attack();
        uint256 gained = address(attacker).balance - before;
        // re-entry took bal - 1 ether against the stale balance; the outer
        // frame's 1 ether lands after. Sum = bal — nothing left in the lab.
        assertEq(gained, bal, "classic: the full balance is drained by the double-spend");
        assertEq(lab.balanceOf(address(attacker)), 0, "classic: nothing left in the lab");
    }

    /// @dev CEI: reentry can still withdraw the LEGAL remaining balance, but
    ///      never double-spend — the outer frame already decremented, so the
    ///      re-entry is capped at bal - 1 ether and 1 ether stays in the lab.
    function testCEIPrevents() public {
        attacker.setUseCEI(true);
        uint256 bal = lab.balanceOf(address(attacker));
        uint256 before = address(attacker).balance;
        attacker.attackCEI();
        uint256 gained = address(attacker).balance - before;
        assertEq(gained, bal - 1 ether, "CEI: exactly the legal remaining balance");
        assertEq(lab.balanceOf(address(attacker)), 1 ether, "CEI: no double-spend");
    }

    /// @dev A fresh attacker with NO lab balance: withdraw reverts on the
    ///      balance check (InsufficientBalance), not on any reentrancy
    ///      protection — the zero-balance case, kept honest.
    function testWithdrawRevertsWithoutBalance() public {
        ReentrantAttacker poor = new ReentrantAttacker(lab);
        vm.expectRevert(
            abi.encodeWithSelector(IReentrancyLab.InsufficientBalance.selector, 0, 1 ether)
        );
        poor.attack();
    }

    /// @dev Transient guard blocks the cross-function twin mid-call.
    function testTransientGuardBlocksCrossFunction() public {
        vm.expectRevert(IReentrancyLab.ReentrantCall.selector);
        crossAttacker.attack{value: 1 ether}();
    }

    /// @dev Guarded transfer is atomic when no reentry happens.
    function testGuardedTransferAtomic() public {
        uint256 before = lab.balanceOf(victim);
        lab.transferTo(victim, 10 ether);
        assertEq(lab.balanceOf(victim), before + 10 ether);
    }
}
