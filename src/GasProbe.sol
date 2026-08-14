// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GasProbe
/// @notice Lab contract for gas mechanics: cold/warm access, the SSTORE
///         state machine, memory expansion. Pedagogical only — NOT protocol.
contract GasProbe {
    mapping(uint256 => uint256) public slots;
    uint256 public probe; // hot scalar slot for SSTORE state-machine probes

    /// @notice Write a mapping slot. First touch in a tx = cold (22,100 or 5,000).
    function setSlot(uint256 k, uint256 v) external {
        slots[k] = v;
    }

    /// @notice Read a mapping slot. First touch in a tx = cold (2,100), then warm (100).
    function getSlot(uint256 k) external view returns (uint256) {
        return slots[k];
    }

    /// @notice SSTORE set: 0 -> nonzero. Warm cost 20,000.
    function sstoreSet() external {
        probe = 1;
    }

    /// @notice SSTORE reset: nonzero -> nonzero. Warm cost 2,900.
    function sstoreReset() external {
        probe = 2;
    }

    /// @notice SSTORE clear: nonzero -> 0. Warm cost 2,900; refund 4,800 capped at gas_used/5.
    function sstoreClear() external {
        probe = 0;
    }

    /// @notice Dirty restore: set, then restore original in one tx (refund 2,800, capped).
    function sstoreDirtyRestore() external {
        probe = 2;
        probe = 1;
    }

    /// @notice Clear then re-set in one tx — the re-clear refund rule (4,800, capped).
    function sstoreClearThenSet() external {
        probe = 0;
        probe = 1;
    }

    /// @notice Touch the same slot twice — second read is warm (100 vs 2,100).
    function touchTwice(uint256 k) external view returns (uint256 a, uint256 b) {
        a = slots[k];
        b = slots[k];
    }

    /// @notice Force memory expansion to `words` 32-byte words and touch the last one.
    function growMemory(uint256 words) external pure returns (uint256 acc) {
        bytes memory buf = new bytes(words * 32);
        assembly ("memory-safe") {
            acc := mload(add(buf, add(0x20, mul(words, 0x20))))
        }
    }
}
