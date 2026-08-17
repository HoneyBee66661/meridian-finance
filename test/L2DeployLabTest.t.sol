// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {L2DeployLab} from "../src/L2DeployLab.sol";
import {IL2DeployLab} from "../src/IL2DeployLab.sol";

contract L2DeployLabTest is Test {
    /// @dev Arbitrum L1→L2 alias offset (AddressAliasHelper): canonical
    ///      delivery presents l1Vault's aliased form, not the raw address.
    uint160 internal constant L1_TO_L2_ALIAS_OFFSET =
        uint160(0x1111000000000000000000000000000000001111);

    L2DeployLab internal lab;
    address internal l1Vault = address(0x11);
    address internal aliasedL1Vault = address(uint160(l1Vault) + L1_TO_L2_ALIAS_OFFSET);
    address internal admin = address(0xA11);

    function setUp() public {
        lab = new L2DeployLab(l1Vault, admin);
        vm.warp(30 days); // realistic clock — staleness math must not underflow
    }

    /// @dev Only the L1 vault may submit cross-chain messages: canonical
    ///      delivery is aliased/messenger-routed, so the raw L1 address is
    ///      rejected as msg.sender.
    function testUnauthorizedCrossMessage() public {
        vm.expectRevert(
            abi.encodeWithSelector(IL2DeployLab.UnauthorizedSender.selector, address(0xBAD))
        );
        vm.prank(address(0xBAD));
        lab.executeCrossMessage(l1Vault, abi.encodeCall(lab.applyMarketState, (0.8e18)));
    }

    /// @dev A canonical (aliased) delivery declaring the wrong L1 source is rejected.
    function testCrossMessageWrongSource() public {
        vm.expectRevert(
            abi.encodeWithSelector(IL2DeployLab.UnauthorizedSender.selector, address(0xBAD))
        );
        vm.prank(aliasedL1Vault);
        lab.executeCrossMessage(address(0xBAD), abi.encodeCall(lab.applyMarketState, (0.8e18)));
    }

    /// @dev Canonical L1→L2 delivery (aliased sender + correct source) lands.
    function testAuthorizedCrossMessage() public {
        vm.prank(aliasedL1Vault);
        lab.executeCrossMessage(l1Vault, abi.encodeCall(lab.applyMarketState, (0.8e18)));
    }

    /// @dev Stale oracle updates are rejected.
    function testStaleOracleRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IL2DeployLab.OracleStale.selector, block.timestamp - 2 hours, lab.MAX_ORACLE_AGE()
            )
        );
        vm.prank(admin);
        lab.setOraclePrice(1000e8, block.timestamp - 2 hours);
    }

    /// @dev Fresh oracle updates land.
    function testFreshOracleAccepted() public {
        vm.prank(admin);
        lab.setOraclePrice(1000e8, block.timestamp);
        assertEq(lab.oraclePrice(), 1000e8);
    }

    /// @dev Non-whitelisted payload rejected.
    function testNonWhitelistedPayload() public {
        bytes memory bad = abi.encodeWithSignature("setAdmin(address)", address(1));
        vm.expectRevert(
            abi.encodeWithSelector(IL2DeployLab.UnauthorizedPayload.selector, bytes4(bad))
        );
        vm.prank(aliasedL1Vault);
        lab.executeCrossMessage(l1Vault, bad);
    }
}
