// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IErrorProbe
/// @notice Interface for `ErrorProbe`. Demonstrates the I-prefix convention:
///         the whole external surface — functions, events, AND errors —
///         declared in one place (cf. OZ v5 IERC20Errors).
interface IErrorProbe {
    /// @notice Raised when a probed value exceeds the bound.
    /// @param bound The configured maximum.
    /// @param received The rejected value.
    error AboveBound(uint256 bound, uint256 received);

    /// @notice Emitted when a probed value is accepted.
    /// @param caller The account that probed.
    /// @param value The accepted value.
    event ProbeAccepted(address indexed caller, uint256 value);

    /// @notice Returns the configured bound.
    function bound() external view returns (uint256);

    /// @notice Accepts `value` if within the bound; reverts with `AboveBound`.
    function probe(uint256 value) external;

    /// @notice Same as `probe` but reverts with a require string. Exists ONLY
    ///         for measurement — violates the locked convention; don't copy.
    function probeLegacy(uint256 value) external;
}

/// @title ErrorProbe
/// @notice Pedagogical measurement contract for Chapter 2. NOT part of the
///         Meridian protocol. Compares custom-error vs require-string reverts.
/// @dev Shows: immutables over storage, CEI, typed custom errors, past-tense
///      indexed events.
contract ErrorProbe is IErrorProbe {
    /// @dev Immutable: fixed at construction, so it lives in code (PUSH32,
    ///      ~3 gas per read) instead of storage (2,100 cold SLOAD).
    uint256 public immutable bound;

    /// @notice Sets the probe bound once.
    /// @param bound_ The maximum value `probe` accepts.
    constructor(uint256 bound_) {
        bound = bound_;
    }

    /// @inheritdoc IErrorProbe
    function probe(uint256 value) external {
        // Check: validation first, with a typed error carrying both values.
        if (value > bound) revert AboveBound(bound, value);
        // Effects/interactions: the only state change is the log (CEI).
        emit ProbeAccepted(msg.sender, value);
    }

    /// @inheritdoc IErrorProbe
    function probeLegacy(uint256 value) external {
        // Deliberate anti-pattern for measurement: string in bytecode,
        // opaque revert payload. Never use this style in protocol code.
        require(value <= bound, "ErrorProbe: value above bound");
        emit ProbeAccepted(msg.sender, value);
    }
}
