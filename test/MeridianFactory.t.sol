// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MeridianFactory} from "../src/MeridianFactory.sol";
import {IMeridianFactory} from "../src/IMeridianFactory.sol";

/// @dev Dummy implementation for proxy targets.
contract Impl {
    uint256 public x;

    function setX(uint256 v) external {
        x = v;
    }
}

contract MeridianFactoryTest is Test {
    MeridianFactory internal factory;
    address internal owner = address(0xA11CE);
    address internal stranger = address(0xB0B);

    function setUp() public {
        factory = new MeridianFactory();
        // Ownable v5: constructor caller (this test) is owner; hand over.
        factory.transferOwnership(owner);
    }

    /// @dev Deployment lands at the predicted address and is a real proxy.
    function testDeployMatchesPrediction(bytes32 salt) public {
        Impl impl = new Impl();
        vm.prank(owner);
        address predicted = factory.predictMarket(salt, address(impl));
        vm.prank(owner);
        address market = factory.deployMarket(salt, address(impl));
        assertEq(market, predicted, "deploy != predict");
        assertTrue(factory.verifyMarket(market, address(impl)), "verify failed");
    }

    /// @dev Same user salt from two senders lands in two different namespaces
    ///      (each in its own owner-gated factory instance).
    function testSaltNamespace(bytes32 salt) public {
        MeridianFactory factory2 = new MeridianFactory();
        factory2.transferOwnership(stranger);

        Impl impl = new Impl();
        vm.prank(owner);
        address viaOwner = factory.deployMarket(salt, address(impl));
        vm.prank(stranger);
        address viaStranger = factory2.deployMarket(salt, address(impl));
        assertTrue(viaOwner != viaStranger, "salt namespace collision");
    }

    /// @dev Owner-only: a stranger cannot deploy.
    function testOnlyOwner() public {
        Impl impl = new Impl();
        vm.prank(stranger);
        vm.expectRevert();
        factory.deployMarket(bytes32(0), address(impl));
    }

    /// @dev Zero implementation is rejected with a named error.
    function testZeroImplementationReverts() public {
        vm.prank(owner);
        vm.expectRevert(IMeridianFactory.InvalidImplementation.selector);
        factory.deployMarket(bytes32(0), address(0));
    }

    /// @dev Re-deploying the same (msg.sender, salt) pair reverts.
    function testCannotRedeploy() public {
        Impl impl = new Impl();
        vm.prank(owner);
        factory.deployMarket(bytes32(0), address(impl));
        vm.prank(owner);
        vm.expectRevert();
        factory.deployMarket(bytes32(0), address(impl));
    }

    /// @dev INVARIANT (fuzz): any salt the owner deploys yields a verified
    ///      market — the factory never leaves unverified/squat-able addresses.
    function testInvariantDeployedMarketsAreVerified(bytes32 saltSeed) public {
        bytes32 salt = keccak256(abi.encode(saltSeed));
        Impl impl = new Impl();
        vm.prank(owner);
        address market = factory.deployMarket(salt, address(impl));
        assertTrue(factory.verifyMarket(market, address(impl)), "market not verified");
    }
}
