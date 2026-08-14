// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";

/// @title Meridian Governance Token interface (gMER)
/// @notice Protocol-facing surface of `MeridianGovernanceToken` — the ERC-5805 /
///         ERC-6372 checkpointed-voting wrapper around MER. Holds gMER = votes;
///         gMER is minted 1:1 against MER deposited into the wrapper and burned
///         1:1 on withdrawal. Voting power is ERC-5805 checkpointed per block
///         (ERC-6372 `mode=blocknumber` clock), so `getPastVotes` is the read
///         Ch 25's `MeridianGovernor` will snapshot against.
/// @dev Error catalog: the OZ v5 interface errors (IERC20Errors per the
///      ERC-6093 draft, ERC-2612 errors, ERC-5805/IVotes errors, InvalidAccountNonce)
///      plus exactly two protocol errors declared here — `InvalidConstructorAddress`
///      and `ERC20ExceededSafeSupply` (the latter mirrors `ERC20Votes`' cap error:
///      checkpoint values live in a uint208, so supply past 2^208 - 1 cannot be
///      represented). Canon locked in Ch 15.
interface IMeridianGovernanceToken is IERC20, IERC20Permit, IERC5805 {
    /// @notice Emitted when `account` wraps `assets` MER into gMER.
    event Deposited(address indexed account, uint256 assets);

    /// @notice Emitted when `account` unwraps `assets` gMER back into MER.
    event Withdrawn(address indexed account, uint256 assets);

    /// @notice The wrapped token (MER). Constructor-pinned; gMER deliberately
    ///         wraps a hookless asset only (see `depositFor` NatSpec).
    function mer() external view returns (IERC20);

    /// @notice Deposits `assets` MER and mints `assets` gMER to the sender.
    /// @dev Pulls MER via transferFrom (allowance required), then mints 1:1.
    ///      Emits `Deposited`.
    /// @param assets Amount of MER to wrap.
    /// @return The amount of gMER minted (== assets).
    function deposit(uint256 assets) external returns (uint256);

    /// @notice Deposits `assets` MER from the sender and mints `assets` gMER to
    ///         `account` (deposit-for: the sender pays, `account` gets the votes).
    /// @param account Recipient of the minted gMER.
    /// @param assets Amount of MER to wrap.
    /// @return The amount of gMER minted (== assets).
    function depositFor(address account, uint256 assets) external returns (uint256);

    /// @notice Burns `assets` gMER from the sender and transfers `assets` MER back.
    /// @dev Burn-then-transfer: strict check-effects-interactions. Emits `Withdrawn`.
    /// @param assets Amount of gMER to unwrap.
    /// @return The amount of MER returned (== assets).
    function withdraw(uint256 assets) external returns (uint256);

    /// @notice Reverts when a constructor address argument is the zero address.
    /// @param account The offending zero address.
    error InvalidConstructorAddress(address account);

    /// @notice Reverts when a mint would push total gMER supply past 2^208 - 1,
    ///         the maximum representable checkpoint value (mirrors OZ ERC20Votes).
    /// @param increasedSupply Supply after the rejected mint.
    /// @param cap 2^208 - 1.
    error ERC20ExceededSafeSupply(uint256 increasedSupply, uint256 cap);
}
