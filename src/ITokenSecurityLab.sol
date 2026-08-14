// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Ch 17 Token Security Patterns — shared lab error catalog
/// @notice LAB ONLY, NOT protocol. Error catalog for the Ch 17 lab contracts,
///         declared on the interface per the Ch 2/14 canon (I-prefix interfaces
///         carry the error catalog; the lab contracts inherit the interface so
///         errors resolve the way OZ v5's `IERC20Errors`-on-`ERC20` pattern
///         does).
interface ITokenSecurityLab {
    /// @notice An amount argument was zero where the operation requires > 0.
    error ZeroAmount();

    /// @notice The operation needed more than was available.
    /// @param have The balance/allowance actually available.
    /// @param need The amount required.
    error InsufficientBalance(uint256 have, uint256 need);

    /// @notice A constructor/argument address was the zero address.
    error ZeroAddress();

    /// @notice A token hook did not return the EIP-777 magic value, or a
    ///         recipient contract reverted inside its hook.
    /// @param recipient The contract whose hook rejected the transfer.
    error HookNotAccepted(address recipient);

    /// @notice A rebase factor would take the rate to (or past) zero.
    /// @param bps The attempted rebase, in basis points.
    error RebaseOutOfBounds(int256 bps);
}
