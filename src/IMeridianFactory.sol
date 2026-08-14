// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMeridianFactory
/// @notice Deployment layer for Meridian markets (v0 — Ch 5).
/// @dev Minimal-proxy (EIP-1167) factory with CREATE2 (EIP-1014)
///      deterministic addresses. Salts are namespaced by msg.sender
///      so one caller can never burn another caller's salt.
interface IMeridianFactory {
    // ── Custom errors (locked convention: no require strings) ────────────
    /// @dev Thrown when a non-owner calls an owner-only function.
    error Unauthorized();
    /// @dev Thrown when the implementation address is the zero address.
    error InvalidImplementation();
    /// @dev Thrown when deployment targets an address that already has code.
    error TargetExists(address target);
    /// @dev Thrown when verification finds a codehash mismatch.
    error CodeHashMismatch(address market, bytes32 actual, bytes32 expected);

    // ── Events ────────────────────────────────────────────────────────────
    /// @dev Emitted for every market proxy deployment.
    event MarketDeployed(
        address indexed market,
        address indexed implementation,
        bytes32 indexed salt
    );

    /// @dev Deploys a minimal-proxy market with a msg.sender-namespaced salt.
    function deployMarket(bytes32 salt, address implementation)
        external
        returns (address market);

    /// @dev Pure EIP-1014 predictor. Hash is over initcode, never runtime code.
    function predictMarket(bytes32 salt, address implementation)
        external
        view
        returns (address market);

    /// @dev True iff `market` is a minimal proxy of `implementation`.
    function verifyMarket(address market, address implementation)
        external
        view
        returns (bool ok);
}
