// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {OracleRegistry} from "../src/OracleRegistry.sol";

/// @notice Ch 40 smoke test — runs the capstone deploy script IN a test and
///         asserts the deployed system is coherent and operational: roles,
///         oracle wiring, market math, and a full deposit->borrow->repay
///         round trip. The deployer in this context is the test contract
///         (the script uses msg.sender), which is exactly how the script
///         behaves under `forge script --broadcast`.
contract DeploySmoke is Test {
    Deploy.Deployment internal d;

    function setUp() public {
        d = new Deploy().run();
    }

    function test_deploy_wiresTokensAndRoles() public view {
        assertEq(d.mer.totalSupply(), 10_000_000e18);
        assertEq(d.gmer.name(), "Meridian Governance");
        assertEq(address(d.smer.underlying()), address(d.mer));
        // The deployer (this test contract) holds every bootstrap role.
        assertTrue(d.mer.hasRole(d.mer.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(d.mer.hasRole(d.mer.MINTER_ROLE(), address(this)));
        assertEq(d.factory.owner(), address(this));
    }

    function test_deploy_wiresOracleThroughRegistry() public view {
        // The vault consumes the Ch 22 registry path, not a raw feed.
        assertEq(
            address(MeridianVault(address(d.ethUsdcVault)).oracle()), address(d.oracleRegistry)
        );
        // Registry normalizes to its canonical 18-dec WAD USD per token
        // (PRICE_DECIMALS = 18); the vault's health-factor/capacity math is
        // price-convention-agnostic because both assets scale together.
        assertEq(d.oracleRegistry.getPrice(address(d.weth)), 2000e18);
        assertEq(d.oracleRegistry.getPrice(address(d.usdc)), 1e18);
    }

    function test_deploy_marketOperational_roundTrip() public {
        address alice = makeAddr("alice");

        // Fund alice with testnet assets.
        d.weth.mint(alice, 10e18);
        d.usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        d.weth.approve(address(d.ethUsdcVault), type(uint256).max);
        d.usdc.approve(address(d.ethUsdcVault), type(uint256).max);
        d.ethUsdcVault.depositCollateral(10e18);
        vm.stopPrank();

        // Seed the debt pool (the test contract is the vault admin).
        d.usdc.mint(address(this), 1_000_000e6);
        d.usdc.approve(address(d.ethUsdcVault), type(uint256).max);
        d.ethUsdcVault.supplyDebtLiquidity(1_000_000e6);

        // Borrow to capacity: 75% CF of 10 ETH @ 2000 = 15,000 USDC.
        vm.prank(alice);
        d.ethUsdcVault.borrow(15_000e6);
        assertEq(d.ethUsdcVault.debtOf(alice), 15_000e6);
        assertGt(d.ethUsdcVault.healthFactor(alice), 1e18); // HF = LT/CF = 1.0667

        // Repay fully, then withdraw all collateral.
        vm.startPrank(alice);
        d.ethUsdcVault.repay(15_000e6);
        d.ethUsdcVault.withdrawCollateral(10e18);
        vm.stopPrank();
        assertEq(d.ethUsdcVault.debtOf(alice), 0);
        assertEq(d.ethUsdcVault.collateralOf(alice), 0);
    }
}
