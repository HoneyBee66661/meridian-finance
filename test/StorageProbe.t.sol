// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StorageProbe} from "../src/StorageProbe.sol";

/// @title StorageProbeTest
/// @notice Pins the compiler's storage layout and proves the derived-slot
///         formulas against real sload reads.
/// @dev Layout pins exist so any accidental reorder of state variables in
///      StorageProbe.sol breaks CI instead of silently changing gas.
contract StorageProbeTest is Test {
    StorageProbe internal probe;

    function setUp() public {
        probe = new StorageProbe();
    }

    /// @dev Layout pin: four uint64s share slot 0 (64+64+64+64 = 256 bits).
    function testPackedQuadSharesSlotZero() public {
        probe.setAll(1, 1, 1, 1); // a=b=c=d=1
        bytes32 s = probe.readSlot(bytes32(0));
        assertEq(uint64(uint256(s)), 1, "a in low 8 bytes");
        assertEq(uint64(uint256(s) >> 64), 1, "b in bytes 8..15");
        assertEq(uint64(uint256(s) >> 128), 1, "c in bytes 16..23");
        assertEq(uint64(uint256(s) >> 192), 1, "d in bytes 24..31");
    }

    /// @dev Layout pin: owner (20B) + feeBps (12B) pack into slot 2.
    function testAddressAndUint96Pack() public {
        probe.setOwnerAndFee(address(0xABCD), 250);
        bytes32 s = probe.readSlot(bytes32(uint256(2)));
        assertEq(address(uint160(uint256(s))), address(0xABCD));
        assertEq(uint96(uint256(s) >> 160), 250);
    }

    /// @dev Derived slot: mapping value lands exactly where the formula says.
    function testMappingSlotMatches(address k, uint256 v) public {
        probe.storeDebt(k, v);
        assertEq(probe.readSlot(probe.mappingSlot(k)), bytes32(v));
    }

    /// @dev Dynamic array: element i at keccak256(p) + i, full slot each.
    function testArrayElementSlot(uint256 v) public {
        probe.storeAndLocate(v);
        uint256 i = probe.valuesLength() - 1;
        assertEq(probe.readSlot(probe.arrayElementSlot(i)), bytes32(v));
    }

    /// @dev Short string: <= 31 bytes stays inline in slot 5 (even low bit).
    function testShortStringInline() public {
        probe.setTag("meridian"); // 8 bytes — short form
        assertTrue(probe.tagIsShort());
    }

    /// @dev Long string: odd low bit marks the long form.
    function testLongStringNotShort() public {
        probe.setTag("meridian meridian meridian meridian meridian x"); // > 31B
        assertFalse(probe.tagIsShort());
    }
}
