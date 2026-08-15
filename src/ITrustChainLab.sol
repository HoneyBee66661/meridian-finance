// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITrustChainLab
/// @notice I-prefix interface — full failure surface (Ch 2 lock).
interface ITrustChainLab {
    /// @dev Role failures revert via OZ AccessControl
    ///      (AccessControlUnauthorizedAccount, IAccessControl); only the
    ///      state guard remains lab-specific.
    error NotPaused();
}
