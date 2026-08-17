// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMeridianToken} from "./IMeridianToken.sol";

/// @title Meridian Token (MER)
/// @notice The Meridian protocol token. A plain, standards-grade ERC20 — no
///         transfer fee, no rebase, no transfer hooks — with ERC-2612 permit for
///         gasless approvals, public burn, and exactly one privileged operation:
///         role-gated minting. Fee capture happens OFF this token: lending-spread
///         revenue accrues to sMER stakers via ERC4626 share appreciation (Ch 23),
///         so MER never needs a transfer tax (which would poison downstream
///         accounting — see Ch 17).
/// @dev Design decisions locked in Ch 14:
///      - Inherits OpenZeppelin v5 (5.7.0) ERC20 + ERC20Burnable + ERC20Permit +
///        AccessControl — the audited base, not a hand-rolled token. OZ ships an
///        external audit for every v5 minor release (audits/ in the lib).
///      - No supply cap: MINTER_ROLE is the supply control surface. The role is
///        held by governance (Ch 25 timelock), making supply policy a governance
///        decision rather than a constructor constant.
///      - Burning is permissionless for own tokens (`burn`) and allowance-gated
///        for others (`burnFrom`, exactly like transferFrom). No BURNER_ROLE:
///        burning one's own tokens is a user right, and the allowance surface
///        already gates third-party burns.
///      - EIP-712 domain: name "Meridian Token", version "1", chainId +
///        verifyingContract — the chainId term is what blocks cross-chain permit
///        replay (a signature made for chain A cannot be replayed on chain B).
///      - Errors come from the OZ interface catalog (IERC20Errors per ERC-6093
///        draft, ERC-2612 errors, IAccessControl) — the token error catalog is
///        now canon (Ch 2's PROVISIONAL resolved for tokens; vault errors remain
///        provisional until Ch 20).
contract MeridianToken is ERC20, ERC20Burnable, ERC20Permit, AccessControl, IMeridianToken {
    /// @notice Role allowed to mint new MER. Granting/revoking is itself gated by
    ///         DEFAULT_ADMIN_ROLE (AccessControl), which governance will hold.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @param defaultAdmin Address receiving DEFAULT_ADMIN_ROLE (can grant/revoke
    ///        MINTER_ROLE). Held by the Meridian timelock once governance ships.
    /// @param minter Initial MINTER_ROLE holder.
    /// @param initialRecipient Receives the initial supply; the mint emits the
    ///        spec-required Transfer(address(0), recipient, value) creation event.
    /// @param initialSupply Initial MER supply in wei (18 decimals).
    constructor(
        address defaultAdmin,
        address minter,
        address initialRecipient,
        uint256 initialSupply
    ) ERC20("Meridian Token", "MER") ERC20Permit("Meridian Token") {
        if (defaultAdmin == address(0)) {
            revert InvalidConstructorAddress(defaultAdmin);
        }
        if (minter == address(0)) revert InvalidConstructorAddress(minter);
        if (initialRecipient == address(0)) revert InvalidConstructorAddress(initialRecipient);

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, minter);
        _mint(initialRecipient, initialSupply);
    }

    /// @inheritdoc IMeridianToken
    function mint(address to, uint256 value) external onlyRole(MINTER_ROLE) {
        _mint(to, value);
    }

    /// @notice Returns the current permit nonce for `owner`.
    /// @dev Explicit override to resolve the IERC20Permit diamond: IERC20Permit
    ///      is inherited twice — via ERC20Permit and via IMeridianToken — and
    ///      `nonces` is also defined by the `Nonces` contract, so C3
    ///      linearization requires MeridianToken to state the override itself.
    ///      The list names the immediate bases (ERC20Permit + the second
    ///      IERC20Permit path); `Nonces` is already covered by ERC20Permit's
    ///      own override and must NOT be listed (compiler errors 4327/2353
    ///      otherwise; pinned as a Ch 14 finding).
    function nonces(address owner)
        public
        view
        override(ERC20Permit, IERC20Permit)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
