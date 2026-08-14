// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GasOptProbe
/// @notice Lab contract for gas optimization patterns: immutables, cached
///         storage reads, no-SLOAD-in-loop, unchecked arithmetic.
/// @dev Pedagogical only — NOT part of the Meridian protocol.
contract GasOptProbe {
    address public immutable ORACLE;   // 3 gas/read, never a storage read
    address public oracleStorage;      // the "before": cold SLOAD 2,100

    uint256 public lastUpdate;         // storage scalar, read via cache below
    uint256 public counter;            // write target for coalescing demo
    mapping(uint256 => bool) public flagEnabled;

    /// @notice Constructor fixes the immutable; `oracleStorage` is the slow twin.
    constructor(address oracle) {
        ORACLE = oracle;
        oracleStorage = oracle;
    }

    /// @notice Read the immutable — a PUSH32, ~3 gas, no state trie touch.
    function readImmutable() external view returns (address) { return ORACLE; }

    /// @notice Read the storage twin — cold 2,100 on a fresh account.
    function readStorageOracle() external view returns (address) {
        return oracleStorage;
    }

    /// @notice Cache a storage scalar: 1 SLOAD + local reads, never N SLOADs.
    function cachedReads(uint256 n) external view returns (uint256 acc) {
        uint256 lu = lastUpdate;                // 1 SLOAD
        for (uint256 i; i < n; ++i) acc += lu;  // local reads, ~3 gas each
    }

    /// @notice The anti-pattern: SLOAD inside the loop, one per iteration.
    function sloadInLoop(uint256 n) external view returns (uint256 acc) {
        for (uint256 i; i < n; ++i) acc += lastUpdate;  // 1 SLOAD per iter
    }

    /// @notice Coalesced write: one SLOAD, one SSTORE.
    function coalescedWrite(uint256 newVal) external {
        uint256 prev = counter;                 // 1 SLOAD
        counter = prev + newVal;                // 1 SSTORE
    }

    /// @notice unchecked, safe because the sum of 0..n-1 overflows only beyond
    ///         n ~ 2^255 — the proof sits next to the unchecked (Ch 4 lock).
    function uncheckedSum(uint256 n) external pure returns (uint256 acc) {
        unchecked { for (uint256 i; i < n; ++i) acc += i; }
    }
}
