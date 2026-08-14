// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StorageProbe
/// @notice Lab contract demonstrating EVM storage layout: slot packing,
///         derived slots for dynamic arrays/mappings, short-string
///         optimization, and raw sload access.
/// @dev Pedagogical only — NOT part of the Meridian protocol. Layout pins
///      here are asserted by StorageProbeTest.t.sol so any accidental
///      reordering of state variables breaks tests instead of costing gas.
contract StorageProbe {
    // One slot: 64+64+64+64 = 256 bits exactly.
    uint64 public a;
    uint64 public b;
    uint64 public c;
    uint64 public d;

    // Declaration order decides packing: these can NOT share slots with a-d.
    uint256 public big; // slot 1
    address public owner; // slot 2 (20 bytes, owns slot 2 alone)
    uint96 public feeBps; // shares slot 2 with `owner` (20+12 = 32B)

    uint256[] public values; // slot 3: length; elements at keccak256(3) + i
    mapping(address => uint256) public debt; // slot 4
    string public tag; // slot 5: short-string inline or keccak(5)

    /// @notice Raw slot read — the audit primitive.
    /// @param slot The storage slot to read.
    /// @return data The 32 bytes stored at `slot`.
    function readSlot(bytes32 slot) public view returns (bytes32 data) {
        assembly ("memory-safe") {
            data := sload(slot)
        }
    }

    /// @notice Dynamic array element slot: keccak256(p) + i.
    /// @param i Element index.
    /// @return The slot holding `values[i]`.
    function arrayElementSlot(uint256 i) public pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(3)))) + i);
    }

    /// @notice Mapping value slot: keccak256(k . p), key left-packed.
    /// @param k Mapping key.
    /// @return The slot holding `debt[k]`.
    function mappingSlot(address k) external pure returns (bytes32) {
        return keccak256(abi.encode(k, uint256(4)));
    }

    /// @notice Stores a value and returns the slot it actually landed in.
    /// @param v Value to push onto `values`.
    /// @return slot The derived slot of the newly pushed element.
    function storeAndLocate(uint256 v) external returns (bytes32 slot) {
        values.push(v);
        slot = arrayElementSlot(values.length - 1);
        assert(readSlot(slot) == bytes32(v));
    }

    /// @notice Short-string check: len <= 31 → inline, low byte = 2 * len.
    /// @return True if `tag` uses the short (inline) form.
    function tagIsShort() external view returns (bool) {
        bytes32 s = readSlot(bytes32(uint256(5)));
        return uint8(uint256(s)) % 2 == 0; // even low bit ⇒ short form
    }

    /// @dev Test helpers (external, verbs-first, past-tense events not needed).
    function storeDebt(address k, uint256 v) external {
        debt[k] = v;
    }

    /// @notice Returns the number of pushed values.
    /// @return The length of `values`.
    function valuesLength() external view returns (uint256) {
        return values.length;
    }

    /// @notice Sets the tag string.
    /// @param t New tag value.
    function setTag(string calldata t) external {
        tag = t;
    }

    /// @dev Layout-pin helpers: write the packed groups for slot assertions.
    function setAll(uint64 _a, uint64 _b, uint64 _c, uint64 _d) external {
        a = _a;
        b = _b;
        c = _c;
        d = _d;
    }

    function setOwnerAndFee(address _owner, uint96 _feeBps) external {
        owner = _owner;
        feeBps = _feeBps;
    }
}
