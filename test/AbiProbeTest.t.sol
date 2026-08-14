// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AbiProbe, IAbiProbe} from "../src/AbiProbe.sol";

/// @notice Foundry lab for Chapter 3: selectors, head/tail layout, packed-hash
///         ambiguity, decoder behavior, calldata-vs-memory gas.
/// @dev Plain `forge test -vvv`; gas via loop-amplified min-delta (Ch 2 note).
contract AbiProbeTest is Test {
    AbiProbe internal probe;

    function setUp() public {
        probe = new AbiProbe();
    }

    /// @dev Canonical selectors must match the registry values.
    function test_Selectors_Canonical() public {
        assertEq(probe.selectorOf("transfer(address,uint256)"), bytes4(0xa9059cbb));
        assertEq(probe.selectorOf("balanceOf(address)"), bytes4(0x70a08231));
        assertEq(probe.selectorOf("latestRoundData()"), bytes4(0xfeaf968c));
    }

    /// @dev Non-canonical strings hash to different selectors (the footgun).
    function test_Selectors_NonCanonicalMismatch() public {
        assertEq(probe.selectorOf("f(uint)"), bytes4(0x693c6139));
        assertEq(probe.selectorOf("f(uint256)"), bytes4(0xb3de648b));
        assertTrue(probe.selectorOf("f(uint)") != probe.selectorOf("f(uint256)"));
    }

    /// @dev Every byte region of a 160-byte encode(uint256,address,bytes) payload.
    function testHeadTailLayoutExact() public {
        bytes memory payload = abi.encode(uint256(1), address(0x2), bytes("meridian"));
        assertEq(payload.length, 160);

        // head: word 0 = a; word 1 = b right-aligned; word 2 = offset 96
        assertEq(probe.headWord(payload, 0), 1);
        assertEq(probe.headWord(payload, 1), uint256(uint160(address(0x2))));
        assertEq(probe.headWord(payload, 2), 96);
        // tail: word 3 = length (8); word 4 = "meridian" right-padded
        assertEq(probe.headWord(payload, 3), 8);
        assertEq(probe.headWord(payload, 4), uint256(bytes32("meridian")));
        assertEq(probe.headOffset(payload), 96);
    }

    /// @dev abi.encodeCall output = 4-byte selector + ABI-encoded args.
    ///      For a single dynamic `bytes` arg that is selector + 32 (offset)
    ///      + 32 (length) + data.
    function testEncodeCallPrefixIsSelector() public {
        bytes memory payload = abi.encode(uint256(1), address(0x2), hex"deadbeef");
        bytes memory data = abi.encodeCall(IAbiProbe.decodePayload, (payload));
        bytes memory expected = abi.encodePacked(IAbiProbe.decodePayload.selector, abi.encode(payload));
        assertEq(data, expected, "encodeCall must be selector + abi.encode(args)");
        assertEq(bytes4(data), IAbiProbe.decodePayload.selector);
        assertEq(probe.headWord(payload, 3), 4); // c length = 4 bytes
    }

    /// @dev The canonical packed-encoding ambiguity: two words == one word.
    function testPackedHash16Equals32() public {
        assertEq(
            probe.packedHash16(0x1234, 0x5678),
            probe.packedHash32(0x12345678)
        );
    }

    /// @dev Fuzz: every (uint8, uint8) pair collides with the packed uint16.
    function testFuzzPackedConcatenationIsAmbiguous(uint8 a, uint8 b) public {
        bytes32 twoWord = keccak256(abi.encodePacked(a, b));
        bytes32 oneWord = keccak256(abi.encodePacked(uint16((uint16(a) << 8) | b)));
        assertEq(twoWord, oneWord, "distinct values hash identically - ambiguity");
    }

    /// @dev Measured: the solc 0.8.24 decoder does NOT validate trailing padding.
    function testDecodePaddingNotValidated() public {
        bytes memory payload = abi.encode(uint256(1), address(0x2), bytes("meridian"));
        bytes memory truncated = new bytes(payload.length - 24); // drop c's padding
        for (uint256 i; i < truncated.length; ++i) truncated[i] = payload[i];

        (uint256 a, address b, bytes memory c) = probe.decodePayload(truncated);
        assertEq(a, 1);
        assertEq(b, address(0x2));
        assertEq(c, bytes("meridian"));
    }

    /// @dev Structural violation (truncated tail) reverts with EMPTY data.
    function testDecodeTruncatedPayloadRevertsEmpty() public {
        bytes memory payload = abi.encode(uint256(1), address(0x2), bytes("meridian"));
        bytes memory truncated = new bytes(payload.length - 40);
        for (uint256 i; i < truncated.length; ++i) truncated[i] = payload[i];

        vm.expectRevert(bytes(""));
        probe.decodePayload(truncated);
    }

    /// @dev A bogus head offset reverts with EMPTY data (not Panic, not Error).
    function testDecodeBogusOffsetRevertsEmpty() public {
        bytes memory payload = abi.encodePacked(
            uint256(1),
            uint256(uint160(address(0x2))),
            uint256(999) // offset beyond the payload
        );
        vm.expectRevert(bytes(""));
        probe.decodePayload(payload);
    }

    /// @dev Fuzz roundtrip: encode then decode preserves all three values.
    function testFuzzEncodeDecodeRoundtrip(uint256 a, address b, bytes calldata c) public {
        (uint256 ra, address rb, bytes memory rc) = probe.decodePayload(abi.encode(a, b, c));
        assertEq(ra, a);
        assertEq(rb, b);
        assertEq(rc, c);
    }

    /// @dev Calldata inline read must beat calldata->memory copy (measured
    ///      17,619 vs 18,178 for 64 words). Loop-amplified min-delta.
    function test_CalldataCheaperThanCopy() public {
        uint256[] memory arr = new uint256[](64);
        for (uint256 i; i < 64; ++i) arr[i] = i;

        uint256 bestCalldata = type(uint256).max;
        uint256 bestCopy = type(uint256).max;
        for (uint256 round; round < 8; ++round) {
            uint256 g0 = gasleft();
            probe.sumCalldata(arr);
            uint256 usedCalldata = g0 - gasleft();
            if (usedCalldata < bestCalldata) bestCalldata = usedCalldata;

            uint256 g1 = gasleft();
            probe.sumCopied(arr);
            uint256 usedCopy = g1 - gasleft();
            if (usedCopy < bestCopy) bestCopy = usedCopy;
        }
        assertLt(bestCalldata, bestCopy, "calldata read must beat memory copy");
        emit log_named_uint("sumCalldata 64 words (approx)", bestCalldata);
        emit log_named_uint("sumCopied 64 words (approx)", bestCopy);
    }
}
