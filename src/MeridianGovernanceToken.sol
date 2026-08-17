// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Votes} from "@openzeppelin/contracts/governance/utils/Votes.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IMeridianGovernanceToken} from "./IMeridianGovernanceToken.sol";

/// @title Meridian Governance Token (gMER)
/// @notice ERC-5805/ERC-6372 checkpointed-voting wrapper around MER. Deposit MER,
///         receive gMER 1:1; gMER balance is voting power, tracked per block so
///         governance can query *historical* power (`getPastVotes`) — the
///         anti-flash-vote property (Ch 15, Beanstalk Apr 2022 grounding).
/// @dev Design decisions locked in Ch 15:
///      - Inherits audited OZ v5 (5.7.0) pieces only: ERC20 + ERC20Permit + Votes
///        (Votes implements IERC5805 + IERC6372). No hand-rolled checkpointing.
///      - WRAPPER, not an ERC20Votes MER: MER's inheritance graph and storage
///        layout are locked since Ch 14; retrofitting Votes would be an upgrade.
///        The wrapper keeps MER liquid (cheap plain transfers) and puts the
///        checkpoint overhead only on governance participants. Production
///        precedent: Aave's stkAAVE wrapper carries Aave governance power.
///      - ZERO privileged surface: gMER has no roles, no mint key, no rescue
///        function. Supply is exactly the deposited MER (invariant
///        totalSupply() == mer.balanceOf(this), pinned in the invariant suite).
///        Deliberately no rescue: accidental direct MER donations are inert and
///        stuck — a rescue function would be a new admin key (2026 trust-surface
///        grounding, Ch 13/25).
///      - ERC-6372 clock: block numbers (`mode=blocknumber&from=default`), the
///        OZ default. Timestamp mode exists for L2s whose block numbers are not
///        time-consistent (Ch 31 deployment discussion).
///      - `depositFor` pulls-then-mints (interaction before effect — the one
///        deliberate exception to strict CEI): safe ONLY because the underlying
///        is constructor-pinned MER, which Ch 14 locked hookless, so transferFrom
///        cannot reenter; pull-first also keeps the wrapper invariant true at
///        every intermediate state. `withdraw` is strict CEI (burn then transfer).
///      - Votes + ERC20Permit share one EIP-712 domain AND one Nonces counter:
///        a permit and a delegateBySig signed with the same nonce invalidate
///        each other (pinned in the lab — see the shared-nonce test).
contract MeridianGovernanceToken is ERC20, ERC20Permit, Votes, IMeridianGovernanceToken {
    using SafeERC20 for IERC20;

    /// @notice The wrapped token (MER). Immutable: wrapper identity is fixed at
    ///         construction (immutables-over-storage, Ch 1/2 conventions).
    IERC20 public immutable override mer;

    /// @param mer_ The MER token address (must be non-zero).
    /// @param name_ ERC-20 name; also the EIP-712 domain name (shared by permit
    ///        and delegateBySig — both hash under `Meridian Governance`).
    /// @param symbol_ ERC-20 symbol (canonical: "gMER").
    constructor(address mer_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (mer_ == address(0)) revert InvalidConstructorAddress(mer_);
        mer = IERC20(mer_);
    }

    /// @inheritdoc IMeridianGovernanceToken
    function deposit(uint256 assets) external returns (uint256) {
        return depositFor(msg.sender, assets);
    }

    /// @inheritdoc IMeridianGovernanceToken
    function depositFor(address account, uint256 assets) public returns (uint256) {
        // Pull first, mint second. The external call precedes the state change —
        // a deliberate, documented exception to strict CEI: the underlying is
        // constructor-pinned MER with no transfer hooks (Ch 14), so this call
        // cannot reenter; and pulling before minting means the wrapper invariant
        // (totalSupply == mer.balanceOf(this)) holds at every intermediate state.
        mer.safeTransferFrom(msg.sender, address(this), assets);
        _mint(account, assets);
        emit Deposited(account, assets);
        return assets;
    }

    /// @inheritdoc IMeridianGovernanceToken
    function withdraw(uint256 assets) external returns (uint256) {
        // Strict CEI: burn the votes first, then release the underlying.
        _burn(msg.sender, assets);
        mer.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, assets);
        return assets;
    }

    /// @notice Returns the current permit/delegation nonce for `owner`.
    /// @dev Explicit override for the C3 diamond. NOTE the override list differs
    ///      from MER's (Ch 14, `override(ERC20Permit, IERC20Permit)`): `Votes`
    ///      adds a SECOND path to `Nonces` (Votes is Context, EIP712, Nonces,
    ///      IERC5805), so the most-derived contract must now name `Nonces`
    ///      explicitly as well (error 4327 otherwise — pinned in-run; the Ch 14
    ///      "Nonces must NOT be listed" rule was specific to MER's graph, where
    ///      AccessControl did not inherit Nonces).
    function nonces(address owner)
        public
        view
        override(ERC20Permit, IERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @dev Votes wiring, copied from OZ ERC20Votes v5.7 (audited base): every
    ///      ERC-20 balance change (mint/burn/transfer) is mirrored into the
    ///      checkpointed vote ledger via `_transferVotingUnits`. The 2^208 - 1
    ///      supply cap keeps checkpoint values inside `Trace208` (the storage
    ///      type Votes uses); without it a large mint would overflow silently.
    /// @param from Sender (address(0) for mints).
    /// @param to Recipient (address(0) for burns).
    /// @param value Amount moved.
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        if (from == address(0)) {
            uint256 supply = totalSupply();
            uint256 cap = _maxSupply();
            if (supply > cap) {
                revert ERC20ExceededSafeSupply(supply, cap);
            }
        }
        _transferVotingUnits(from, to, value);
    }

    /// @dev Maximum gMER supply: 2^208 - 1, the max representable checkpoint
    ///      value (mirrors OZ ERC20Votes._maxSupply).
    function _maxSupply() internal view virtual returns (uint256) {
        return type(uint208).max;
    }

    /// @dev Voting units = gMER balance, 1:1 (mirrors OZ ERC20Votes).
    function _getVotingUnits(address account) internal view virtual override returns (uint256) {
        return balanceOf(account);
    }

    /// @notice Number of checkpoints recorded for `account` (inspection helper;
    ///         the invariant suite uses it to pin same-block coalescing).
    function numCheckpoints(address account) public view virtual returns (uint32) {
        return _numCheckpoints(account);
    }

    /// @notice The `pos`-th checkpoint for `account` (inspection helper).
    function checkpoints(address account, uint32 pos)
        public
        view
        virtual
        returns (Checkpoints.Checkpoint208 memory)
    {
        return _checkpoints(account, pos);
    }
}
