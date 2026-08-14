// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title NamespacedStorageLab
/// @notice ERC-7201 namespaced-storage demo: the namespace formula as a
///         library plus provisional Meridian namespace skeletons.
/// @dev Storage-only — deliberately NO protocol logic. The vault and oracle
///      namespaces are layout contracts refined in Ch 20 / Ch 22.
library NamespacedStorageLab {
    /// @notice ERC-7201 namespace:
    ///         keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff
    /// @param id Unique namespace identifier string.
    /// @return The 256-byte-aligned namespace slot.
    function namespace(string memory id) internal pure returns (bytes32) {
        return bytes32(
            (uint256(keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1))))
            & ~uint256(0xff)
        );
    }

    /// @notice Meridian vault market state — layout PROVISIONAL until Ch 20.
    /// @dev Hot fields (collateral/debt) grouped; the packed rate/interest
    ///      group is 64+64+32+96 = 256 bits exactly, one slot.
    struct VaultStorage {
        mapping(address => uint256) collateral;   // user => collateral (WAD)
        mapping(address => uint256) debt;          // user => debt (WAD)
        uint64 collateralFactorBps;
        uint64 reserveFactorBps;
        uint32 lastUpdate;
        uint96 pendingInterest;                    // 64+64+32+96 = 256 bits ✓
        bool paused;
    }

    /// @notice Meridian oracle feed state — layout PROVISIONAL until Ch 22.
    struct OracleStorage {
        mapping(address => address) primaryFeed;  // asset => Chainlink feed
        mapping(address => uint32) twapWindow;    // asset => TWAP window (s)
        uint64 maxStaleness;                      // max feed age before fallback
        bool fallbackEnabled;
    }

    /// @notice Namespace constant for "meridian.vault.markets" — compile-time
    ///         folded by solc, so namespacing costs ZERO runtime gas.
    bytes32 internal constant VAULT_NAMESPACE =
        0xea0a15d0e6b7f4a3f2f1f9e7d4b0c3a2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6;

    /// @notice Namespace constant for "meridian.vault.oracles".
    bytes32 internal constant ORACLE_NAMESPACE =
        0x1c2b3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c;

    /// @notice Accessor for the vault namespace region.
    /// @return $ The namespaced VaultStorage region.
    function vaultStorage() internal pure returns (VaultStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VAULT_NAMESPACE
        }
    }

    /// @notice Accessor for the oracle namespace region.
    /// @return $ The namespaced OracleStorage region.
    function oracleStorage() internal pure returns (OracleStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ORACLE_NAMESPACE
        }
    }
}
