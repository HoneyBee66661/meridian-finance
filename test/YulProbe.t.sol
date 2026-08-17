// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YulProbe} from "../src/YulProbe.sol";

/// @notice Mock that returns a fixed bytes32 from its fallback — the shape a
///         low-level STATICCALL with empty calldata must tolerate.
/// @dev A Yul fallback returns raw bytes (arbitrary fallback return types are
///      illegal in Solidity), reinforcing this chapter's assembly lesson.
contract ReturnBytes32Mock {
    bytes32 public value;

    constructor(bytes32 v) {
        value = v;
    }

    /// @notice Fallback returns the 32-byte value as raw returndata.
    fallback() external {
        assembly ("memory-safe") {
            mstore(0x00, sload(value.slot))
            return(0x00, 0x20)
        }
    }
}

/// @notice Mock that returns nothing (the USDT/empty-return convention).
contract ReturnEmptyMock {
    /// @notice Fallback returns nothing.
    fallback() external {}
}

/// @notice Mock that returns 64 bytes — must be rejected by returndata checks.
contract ReturnLongMock {
    /// @notice Fallback returns two words as raw returndata.
    fallback() external {
        assembly ("memory-safe") {
            mstore(0x00, 1)
            mstore(0x20, 2)
            return(0x00, 0x40)
        }
    }
}

contract YulProbeTest is Test {
    YulProbe internal probe;

    function setUp() public {
        probe = new YulProbe();
    }

    /// @dev The assembly packed-read must decode the same four fields as the
    ///      Solidity struct path (correctness, not gas).
    function testHeaderAssemblyMatchesSolidity() public view {
        (uint64 cfA, uint64 rfA, uint64 tsA, uint64 flA) = probe.readHeaderAssembly();
        (uint64 cfB, uint64 rfB, uint64 tsB, uint64 flB) = probe.readHeaderSolidity();
        assertEq(cfA, cfB);
        assertEq(rfA, rfB);
        assertEq(tsA, tsB);
        assertEq(flA, flB);
    }

    /// @dev Fuzz: the scratch-space keccak must equal abi.encodePacked hashing.
    function testHashPairMatchesAbiEncodePacked(uint256 a, uint256 b) public view {
        assertEq(probe.hashPair(a, b), keccak256(abi.encodePacked(a, b)));
    }

    /// @dev MCOPY and the mload/mstore loop must be byte-identical for every
    ///      interesting length (empty, partial word, word-aligned, large).
    function testMcopyMatchesLoop(uint256 len) public {
        len = bound(len, 0, 8192);
        bytes memory data = new bytes(len);
        for (uint256 i; i < len; ++i) {
            data[i] = bytes1(uint8((i * 31) % 256));
        }
        assertEq(probe.copyMcopy(data), probe.copyLoop(data));
    }

    /// @dev STATICCALL capture returns the mock's 32 bytes.
    function testStaticReadBytes32() public {
        bytes32 v = keccak256("meridian");
        ReturnBytes32Mock mock = new ReturnBytes32Mock(v);
        assertEq(probe.staticRead(address(mock)), v);
    }

    /// @dev Empty returndata (USDT convention) reads back as bytes32(0).
    function testStaticReadEmptyReturnsZero() public {
        ReturnEmptyMock mock = new ReturnEmptyMock();
        assertEq(probe.staticRead(address(mock)), bytes32(0));
    }

    /// @dev Oversized returndata must be rejected, not silently truncated.
    function testStaticReadRejectsLongReturn() public {
        ReturnLongMock mock = new ReturnLongMock();
        vm.expectRevert();
        probe.staticRead(address(mock));
    }

    /// @dev One packed SLOAD + stack masks must beat four separate SLOADs for
    ///      the same logical data. Loop-amplified deltas; address warmed first
    ///      (locked lab convention from Ch 8).
    function testAssemblyPackedReadCheaperThanFourSlots() public {
        probe.readHeaderAssembly(); // warm the probe address + slot
        uint256 g0 = gasleft();
        for (uint256 i; i < 6; ++i) {
            probe.readFourSlotsSolidity();
        }
        uint256 fourSlots = g0 - gasleft();

        uint256 g1 = gasleft();
        for (uint256 i; i < 6; ++i) {
            probe.readHeaderAssembly();
        }
        uint256 packed = g1 - gasleft();

        assertLt(packed, fourSlots, "packed assembly read must beat four SLOADs");
        emit log_named_uint("6x four-slot read (approx)", fourSlots);
        emit log_named_uint("6x packed assembly read (approx)", packed);
    }

    /// @dev MCOPY must beat an mload/mstore loop for a 4 KiB (128-word) copy.
    ///      Loop-amplified; the allocation + return cost is identical on both
    ///      sides, isolating the copy method (768 gas vs 3 + expansion).
    function testMcopyCheaperThanLoop() public {
        bytes memory data = new bytes(4096);
        for (uint256 i; i < 4096; ++i) {
            data[i] = bytes1(uint8((i * 31) % 256));
        }
        probe.copyMcopy(data); // warm the probe address
        uint256 g0 = gasleft();
        for (uint256 i; i < 3; ++i) {
            probe.copyMcopy(data);
        }
        uint256 mc = g0 - gasleft();

        uint256 g1 = gasleft();
        for (uint256 i; i < 3; ++i) {
            probe.copyLoop(data);
        }
        uint256 lp = g1 - gasleft();

        assertLt(mc + 200, lp, "MCOPY must beat the mload/mstore copy loop");
        emit log_named_uint("3x mcopy (approx)", mc);
        emit log_named_uint("3x mload/mstore loop (approx)", lp);
    }
}
