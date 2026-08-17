// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UpgradeLab} from "../src/UpgradeLab.sol";
import {IUpgradeLab} from "../src/IUpgradeLab.sol";

contract ImplV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UpgradeLabTest is Test {
    UpgradeLab internal proxy;

    function setUp() public {
        proxy = new UpgradeLab();
    }

    /// @dev Only the admin may upgrade. (ImplV2 created OUTSIDE the call —
    ///      the create would consume the vm.prank otherwise.)
    function testOnlyAdminUpgrades() public {
        ImplV2 v2 = new ImplV2();
        vm.expectRevert(abi.encodeWithSelector(IUpgradeLab.NotAdmin.selector, address(0xBAD)));
        vm.prank(address(0xBAD));
        proxy.upgradeTo(address(v2));
    }

    /// @dev Admin upgrades to a code-bearing implementation.
    function testAdminUpgrades() public {
        proxy.upgradeTo(address(new ImplV2()));
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address impl = address(uint160(uint256(vm.load(address(proxy), slot))));
        assertTrue(impl.code.length > 0);
    }

    /// @dev Calls route through the proxy to the implementation (fallback →
    ///      delegatecall), proving routing, not just slot state.
    function testDelegatecallRoutesCorrectly() public {
        proxy.upgradeTo(address(new ImplV2()));
        (bool ok, bytes memory data) = address(proxy).call(abi.encodeWithSignature("version()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 2);
    }

    /// @dev Upgrading to an EOA (no code) reverts.
    function testNoCodeTargetRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(IUpgradeLab.InvalidImplementation.selector, address(0x1234))
        );
        proxy.upgradeTo(address(0x1234));
    }
}
