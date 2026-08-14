// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Meridian Token interface (MER)
/// @notice Protocol-facing surface of `MeridianToken`. The error catalog is NOT
///         re-declared here: the token's errors are the OpenZeppelin v5 interface
///         errors — `IERC20Errors` (ERC-6093 draft: ERC20InsufficientBalance,
///         ERC20InvalidSender, ERC20InvalidReceiver, ERC20InsufficientAllowance,
///         ERC20InvalidApprover, ERC20InvalidSpender), the ERC-2612 errors
///         (ERC2612ExpiredSignature, ERC2612InvalidSigner, InvalidAccountNonce),
///         and `IAccessControl`'s AccessControlUnauthorizedAccount /
///         AccessControlBadConfirmation. Locked canon in Ch 14.
/// @dev Mirrors the inheritance surface of MeridianToken (ERC20 + ERC20Permit +
///      AccessControl) plus the protocol-specific mint entry point.
interface IMeridianToken is IERC20, IERC20Permit, IAccessControl {
    /// @notice Role allowed to mint new MER (supply control surface).
    function MINTER_ROLE() external view returns (bytes32);

    /// @notice Mints `value` MER to `to`, emitting Transfer(address(0), to, value).
    /// @dev Reverts with ERC20InvalidReceiver(address(0)) if `to` is zero.
    function mint(address to, uint256 value) external;

    /// @notice Reverts when a constructor address argument is the zero address.
    /// @param account The offending zero address.
    error InvalidConstructorAddress(address account);
}
