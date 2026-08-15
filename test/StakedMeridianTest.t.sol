// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakedMeridian} from "../src/StakedMeridian.sol";
import {IStakedMeridian} from "../src/IStakedMeridian.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal mintable MER stand-in for the lab (protocol MER is Ch 14).
contract MintableERC20 {
    string public name = "Mintable MER";
    string public symbol = "mMER";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakedMeridianTest is Test {
    StakedMeridian internal smer;
    MintableERC20 internal mer;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal vault = address(0xBA5E);
    address internal attacker = address(0xA77A);

    function setUp() public {
        mer = new MintableERC20();
        smer = new StakedMeridian(address(mer), address(this), vault);
        mer.mint(alice, 1000 ether);
        mer.mint(bob, 1000 ether);
        mer.mint(attacker, 100_000 ether);
        mer.mint(vault, 100_000 ether);
        vm.startPrank(alice);
        mer.approve(address(smer), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        mer.approve(address(smer), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(attacker);
        mer.approve(address(smer), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(vault);
        mer.approve(address(smer), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev First deposit at the offset price: 100 MER -> 100 shares (no inflation edge).
    function testFirstDepositExact() public {
        vm.prank(alice);
        uint256 shares = smer.deposit(100 ether, alice);
        assertEq(shares, 100 ether);
        assertEq(smer.totalSupply(), 100 ether);
        assertEq(smer.totalAssets(), 100 ether);
    }

    /// @dev Donation attack: a direct transfer must NOT move the share price.
    function testDirectTransferDoesNotInflatePrice() public {
        vm.prank(alice);
        smer.deposit(100 ether, alice);
        uint256 priceBefore = smer.convertToAssets(1 ether);

        // attacker donates 10,000 MER directly to the vault (no deposit)
        vm.prank(attacker);
        mer.transfer(address(smer), 10_000 ether);

        uint256 priceAfter = smer.convertToAssets(1 ether);
        assertEq(priceBefore, priceAfter, "direct donation must not move share price");
    }

    /// @dev Revenue accrual: notifyReward raises redeemable assets pro rata.
    function testRevenueAccruesToAllStakers() public {
        vm.prank(alice);
        smer.deposit(100 ether, alice);
        vm.prank(bob);
        smer.deposit(100 ether, bob);

        vm.prank(vault);
        smer.notifyReward(10 ether);

        uint256 aliceAssets = smer.convertToAssets(100 ether);
        assertGt(aliceAssets, 100 ether, "alice must gain from revenue");
        assertEq(aliceAssets, smer.convertToAssets(100 ether)); // pro rata, same price
    }

    /// @dev Sub-offset deposit: 1 wei mints 1 share pegged to the offset
    ///      baseline (~1 wei value) — a donation cannot turn it into a hostage.
    function testOneWeiDepositSafeUnderDonation() public {
        vm.prank(attacker);
        smer.deposit(1, attacker); // 1 wei -> 1 share (offset baseline)
        vm.prank(attacker);
        mer.transfer(address(smer), 1000 ether); // huge untracked donation

        // a real deposit right after still converts ~1:1 — victim is not robbed
        vm.prank(alice);
        uint256 shares = smer.deposit(1000 ether, alice);
        assertGt(shares, 999 ether, "victim must keep ~all value despite donation");
    }

    /// @dev Zero deposit reverts with ZeroShares.
    function testZeroDepositReverts() public {
        vm.expectRevert(IStakedMeridian.ZeroShares.selector);
        vm.prank(alice);
        smer.deposit(0, alice);
    }

    /// @dev Redeem round-trips at the correct price; balance is enforced.
    function testRedeemRoundTrip() public {
        vm.prank(alice);
        uint256 shares = smer.deposit(100 ether, alice);
        vm.prank(alice);
        uint256 assets = smer.redeem(shares, alice, alice);
        assertEq(assets, 100 ether);
        assertEq(mer.balanceOf(alice), 1000 ether); // original restored
    }

    /// @dev Only the vault/admin may notify.
    function testNotifyAuthorization() public {
        vm.expectRevert(abi.encodeWithSelector(IStakedMeridian.NotAuthorized.selector, attacker));
        vm.prank(attacker);
        smer.notifyReward(1 ether);
    }

    /// @dev Attacker's 1-wei share is worth 0 after virtual offset — no hostage.
    function testNoInflationEdge() public {
        vm.prank(attacker);
        smer.deposit(1 ether, attacker); // 1 ether -> 1 ether shares at price 1
        vm.prank(attacker);
        mer.transfer(address(smer), 50_000 ether); // huge donation
        vm.prank(alice);
        uint256 aliceShares = smer.deposit(100 ether, alice);
        // price still ~1: alice gets ~100 shares, attacker's share not inflated
        assertGt(aliceShares, 99 ether);
        assertLt(aliceShares, 101 ether);
    }
}
