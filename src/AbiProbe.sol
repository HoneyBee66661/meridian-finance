// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAbiProbe
/// @notice Interface for `AbiProbe` — the Chapter 3 ABI lab.
/// @dev I-prefix convention (Ch 2): the whole external surface in one place.
interface IAbiProbe {
    /// @notice Returns the 4-byte selector of a canonical signature string.
    /// @param signature Canonical signature, e.g. "transfer(address,uint256)".
    /// @return The first 4 bytes of keccak256(bytes(signature)).
    function selectorOf(string calldata signature) external pure returns (bytes4);

    /// @notice Reads the head of an ABI payload word-by-word (calldata slicing).
    /// @param data The payload (e.g. encode(uint256,address,bytes)).
    /// @param idx 0-based 32-byte word index.
    /// @return The word as uint256.
    function headWord(bytes calldata data, uint256 idx) external pure returns (uint256);

    /// @notice The offset word of the first dynamic argument in a head.
    /// @param data The payload.
    /// @return headWord(data, 2) for encode(uint256,address,bytes).
    function headOffset(bytes calldata data) external pure returns (uint256);

    /// @notice keccak256 of packed (uint16, uint16).
    function packedHash16(uint16 a, uint16 b) external pure returns (bytes32);

    /// @notice keccak256 of packed uint32 — byte-identical to packedHash16
    ///         when the uint32 is (a << 16) | b (the ambiguity class).
    function packedHash32(uint32 c) external pure returns (bytes32);

    /// @notice Decodes an (uint256,address,bytes) payload (for decoder probes).
    function decodePayload(bytes calldata data)
        external
        pure
        returns (uint256 a, address b, bytes memory c);

    /// @notice Sums an array reading inline from calldata.
    function sumCalldata(uint256[] calldata arr) external pure returns (uint256);

    /// @notice Sums an array after a calldata -> memory copy.
    function sumCopied(uint256[] memory arr) external pure returns (uint256);
}

/// @title AbiProbe
/// @notice Pedagogical ABI lab for Chapter 3. NOT part of the Meridian
///         protocol. Pins selector mechanics, head/tail layout, packed-hash
///         ambiguity, decoder behavior, and calldata-vs-memory cost.
/// @dev Reconstructed from the chapter spec after the VPS migration
///      (original lived on the decommissioned host).
contract AbiProbe is IAbiProbe {
    /// @inheritdoc IAbiProbe
    function selectorOf(string calldata signature) external pure returns (bytes4) {
        return bytes4(keccak256(bytes(signature)));
    }

    /// @inheritdoc IAbiProbe
    function headWord(bytes calldata data, uint256 idx) external pure returns (uint256) {
        return _headWord(data, idx);
    }

    /// @dev Internal word reader shared by `headWord` and `headOffset`.
    function _headWord(bytes calldata data, uint256 idx) private pure returns (uint256) {
        bytes calldata slice = data[idx * 32:idx * 32 + 32];
        return uint256(bytes32(slice));
    }

    /// @inheritdoc IAbiProbe
    function headOffset(bytes calldata data) external pure returns (uint256) {
        return _headWord(data, 2); // the offset word for encode(uint256,address,bytes)
    }

    /// @inheritdoc IAbiProbe
    function packedHash16(uint16 a, uint16 b) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    /// @inheritdoc IAbiProbe
    function packedHash32(uint32 c) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(c));
    }

    /// @inheritdoc IAbiProbe
    function decodePayload(bytes calldata data)
        external
        pure
        returns (uint256 a, address b, bytes memory c)
    {
        (a, b, c) = abi.decode(data, (uint256, address, bytes));
    }

    /// @inheritdoc IAbiProbe
    function sumCalldata(uint256[] calldata arr) external pure returns (uint256 acc) {
        for (uint256 i; i < arr.length; ++i) {
            acc += arr[i];
        }
    }

    /// @inheritdoc IAbiProbe
    function sumCopied(uint256[] memory arr) external pure returns (uint256 acc) {
        for (uint256 i; i < arr.length; ++i) {
            acc += arr[i];
        }
    }
}
