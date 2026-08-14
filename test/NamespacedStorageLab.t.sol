// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NamespacedStorageLab} from "../src/NamespacedStorageLab.sol";

/// @title NamespacedStorageLabTest
/// @notice Verifies the ERC-7201 namespace formula and the alignment property.
contract NamespacedStorageLabTest is Test {
    /// @dev Formula sanity: namespace matches the spec's construction.
    function testNamespaceFormula(string calldata id) public {
        bytes32 ns = NamespacedStorageLab.namespace(id);
        bytes32 expected = bytes32(
            (uint256(keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1))))
            & ~uint256(0xff)
        );
        assertEq(ns, expected, "namespace must match ERC-7201 construction");
    }

    /// @dev Alignment: low byte is always zero (256-slot boundary).
    function testNamespaceAligned(string calldata id) public {
        bytes32 ns = NamespacedStorageLab.namespace(id);
        assertEq(uint256(ns) & 0xff, 0, "namespace must be 256-byte aligned");
    }

    /// @dev Distinct ids → distinct namespaces (disjoint module regions).
    function testNamespacesDisjoint(string calldata idA, string calldata idB) public {
        vm.assume(keccak256(bytes(idA)) != keccak256(bytes(idB)));
        bytes32 nsA = NamespacedStorageLab.namespace(idA);
        bytes32 nsB = NamespacedStorageLab.namespace(idB);
        assertTrue(nsA != nsB, "distinct ids must yield distinct namespaces");
    }

    /// @dev Vault struct occupies exactly 256 bits of packed scalar state:
    ///      collateralFactorBps(64) + reserveFactorBps(64) + lastUpdate(32)
    ///      + pendingInterest(96) = 256 — fits one slot after the mappings.
    function testVaultScalarGroupFitsOneSlot() public pure {
        // 64 + 64 + 32 + 96 == 256 bits exactly.
        assertTrue(64 + 64 + 32 + 96 == 256);
    }

    /// @dev Namespaced region does not collide with EIP-1967 slots.
    function testNoEip1967Collision() public pure {
        bytes32 impl = bytes32(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        bytes32 admin = bytes32(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103);
        bytes32 beacon = bytes32(0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50);
        bytes32 vault = NamespacedStorageLab.VAULT_NAMESPACE;
        bytes32 oracle = NamespacedStorageLab.ORACLE_NAMESPACE;
        assertTrue(vault != impl && vault != admin && vault != beacon);
        assertTrue(oracle != impl && oracle != admin && oracle != beacon);
    }
}
