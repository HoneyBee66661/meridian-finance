// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CostProbe
/// @notice Lab contract for the EVM cost model (Project 1.1): one function per
///         interesting operation so `gasleft()` deltas isolate a single cost.
/// @dev Pedagogical only — NOT part of the Meridian protocol.
///      Measure with plain `forge test -vvv`; `--gas-report` distorts
///      `gasleft()`-based tests (Ch 1/2 methodology note).
contract CostProbe {
    mapping(uint256 => uint256) public slots;
    uint256 public scalar; // hot scalar slot for SSTORE-state probes

    /// @notice One cold or warm SLOAD, depending on tx history.
    /// @param k Slot to read.
    function readSlot(uint256 k) external view returns (uint256) {
        return slots[k];
    }

    /// @notice One fresh (0 -> nonzero) SSTORE on a mapping slot.
    /// @param k Slot to write.
    /// @param v Non-zero value.
    function writeSlot(uint256 k, uint256 v) external {
        slots[k] = v;
    }

    /// @notice One SSTORE-clear (nonzero -> 0) on a mapping slot.
    /// @param k Slot to clear.
    function clearSlot(uint256 k) external {
        slots[k] = 0;
    }

    /// @notice One SSTORE-set on the hot scalar slot (warm 20,000).
    function setScalar() external {
        scalar = 1;
    }

    /// @notice One SSTORE-clear on the hot scalar slot (warm 2,900 + refund).
    function clearScalar() external {
        scalar = 0;
    }

    /// @notice One LOG1: event with one indexed topic.
    event Logged(uint256 indexed value);

    /// @notice Emits a single LOG1 event (375 + 375 topics + data).
    /// @param value Topic value.
    function emitLog(uint256 value) external {
        emit Logged(value);
    }

    /// @notice Force memory expansion to `words` 32-byte words.
    /// @param words Number of 32-byte words to allocate (1 / 64 / 1024 used).
    function expandMemory(uint256 words) external pure returns (uint256 acc) {
        bytes memory buf = new bytes(words * 32);
        assembly ("memory-safe") {
            acc := mload(add(buf, add(0x20, mul(words, 0x20))))
        }
    }
}
