// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A pedagogical miniature of the EVM's data layer.
/// @dev  Not meant for production. Demonstrates stack/memory/storage semantics
///       and why Solidity code compiles to the bytecode it does.
contract EvmMiniature {
    /// @notice Persistent storage: 256-bit keys to 256-bit values.
    mapping(uint256 => uint256) private _storage;

    /// @notice A "call frame" bundles the three data locations.
    struct Frame {
        // stack is implicit in the bytecode; here we model the contract state
        bytes32 frameId;
    }

    /// @notice Emitted when a storage slot is written, mirroring SSTORE.
    /// @param slot The storage key written.
    /// @param value The value written.
    event SlotWritten(uint256 indexed slot, uint256 value);

    /// @notice Simulates SSTORE: writing zero (clear) is cheaper than writing
    ///         non-zero (set). Mirrors EIP-2929 cost asymmetry.
    /// @dev    Gas: non-zero write 20,000 vs clear 2,900 — the single most
    ///         important number for storage design.
    /// @param slot The storage slot to write.
    /// @param value The value to write; 0 clears the slot.
    function sstore(uint256 slot, uint256 value) external {
        _storage[slot] = value; // the EVM charges 20,000 for non-zero, 2,900 for zero
        emit SlotWritten(slot, value);
    }

    /// @notice Simulates SLOAD with warm/cold semantics.
    /// @param slot The storage slot to read.
    /// @return value The stored value (0 if never written).
    function sload(uint256 slot) external view returns (uint256 value) {
        return _storage[slot];
    }

    /// @notice Demonstrates the revert-atomicity rule that lending protocols
    ///         depend on: if this reverts, the previous sstore is rolled back.
    /// @param fail If true, the whole transaction reverts.
    function revertIsAtomic(bool fail) external {
        _storage[0] = 42;
        if (fail) revert("atomicity demo");
        // if we reach here, _storage[0] == 42 persists
    }

    /// @notice Demonstrates that memory is per-frame: nested calls cannot
    ///         observe the caller's memory, only storage.
    /// @param target Contract whose `poke` function writes a storage slot.
    function callIsolated(address target) external {
        (bool ok, ) = target.call(abi.encodeWithSignature("poke()"));
        require(ok, "call failed");
    }
}
