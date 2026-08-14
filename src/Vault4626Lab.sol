// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVault4626Lab} from "./IVault4626Lab.sol";

/// @title Ch 16 ERC4626 lab vaults
/// @notice Two ERC4626-shaped vaults that differ in exactly ONE way: whether the
///         conversion math carries the virtual offset. LAB ONLY, NOT protocol.
/// @dev The abstract base implements the full surface with EIP-4626's rounding
///      directions; the two concrete vaults override only the conversion
///      internals:
///        - Naive4626Lab   — pre-v4.9 OpenZeppelin shape: raw floor/floor with
///          NO virtual offset and NO dead shares. The first-depositor
///          inflation/donation attack (t11s 2022) works against it — the Ch 12
///          Mini4626 cousin.
///        - Virtual4626Lab — OZ v4.9+ virtual-offset math: virtualShares=1,
///          virtualAssets=1 at offset 0, so the attack becomes non-profitable
///          (derivation in Ch 16).
///      The share token is a minimal balance ledger, not a full ERC20 — the
///      chapter's focus is the CONVERSION math, not share-token plumbing.
abstract contract Abstract4626Lab is IVault4626Lab {
    using SafeERC20 for IERC20;

    IERC20 private immutable _asset;

    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balanceOf;

    constructor(IERC20 asset_) {
        _asset = asset_;
    }

    /// @dev EIP-4626 asset() returns the token ADDRESS (OZ pattern: private
    ///      _asset + explicit getter).
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /// @dev totalAssets is the vault's asset BALANCE, so a plain transfer INTO
    ///      the vault is a donation — no vault function is involved (t11s).
    function totalAssets() public view virtual returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balanceOf[account];
    }

    // ── conversions (public: raw math, floor) ──────────────────────────────
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    // ── previews (round exactly like the entry point they preview) ─────────
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    // ── max* (defaults; the sMER spec keeps these, Ch 16) ──────────────────
    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return _balanceOf[owner];
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    // ── entry points ───────────────────────────────────────────────────────
    /// @notice Pull `assets` in and mint `shares` (floor — the vault keeps dust).
    /// @dev Deliberately does NOT revert on zero shares: the naive pre-hardened
    ///      behavior the attack exploits. Mini4626 (Ch 12) added a ZeroShares
    ///      revert; this lab keeps the faithful shape so the capture is visible.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 max = maxDeposit(receiver);
        if (assets > max) revert ExceededMaxDeposit(receiver, assets, max);
        shares = previewDeposit(assets);
        _transferIn(msg.sender, assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mint exactly `shares` and pull the required `assets` (ceil).
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        assets = previewMint(shares);
        _transferIn(msg.sender, assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Give `receiver` exactly `assets` and burn the required shares (ceil).
    /// @dev Owner-only in the lab (no share-allowance split; EIP-4626's full
    ///      caller/owner allowance is production plumbing, not conversion math).
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        uint256 max = maxWithdraw(owner);
        if (assets > max) revert ExceededMaxWithdraw(owner, assets, max);
        shares = previewWithdraw(assets);
        _burnFrom(owner, shares);
        _transferOut(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Burn `shares` and pay `receiver` the assets (floor).
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        uint256 bal = _balanceOf[owner];
        if (bal < shares) revert InsufficientShares(bal, shares);
        assets = previewRedeem(shares);
        _burnFrom(owner, shares);
        _transferOut(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Attack primitive (LAB ONLY): pull `assets` without minting.
    /// @dev In production the attacker needs no vault function — a plain asset
    ///      transfer inflates totalAssets() the same way. Kept so tests can
    ///      name the step and reuse the approval.
    function donate(uint256 assets) external {
        if (assets == 0) revert ZeroAssets();
        _transferIn(msg.sender, assets);
        emit Donated(msg.sender, assets);
    }

    // ── internals ──────────────────────────────────────────────────────────
    function _mint(address to, uint256 shares) internal {
        _totalSupply += shares;
        _balanceOf[to] += shares;
    }

    function _burnFrom(address owner, uint256 shares) internal {
        if (msg.sender != owner) revert UnauthorizedCaller(msg.sender, owner);
        _balanceOf[owner] -= shares;
        _totalSupply -= shares;
    }

    function _transferIn(address from, uint256 assets) internal {
        _asset.safeTransferFrom(from, address(this), assets);
    }

    function _transferOut(address to, uint256 assets) internal {
        _asset.safeTransfer(to, assets);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        virtual
        returns (uint256);
    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        virtual
        returns (uint256);
}

/// @notice The vulnerable vault: raw floor/floor, NO virtual offset.
/// @dev Pre-v4.9 OZ shape. Genesis guard: empty vault converts 1:1. A drained
///      vault (supply > 0, assets == 0) converts to 0 shares — worthless.
contract Naive4626Lab is Abstract4626Lab {
    using Math for uint256;

    constructor(IERC20 asset_) Abstract4626Lab(asset_) {}

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = _totalSupply;
        if (supply == 0) return assets; // genesis: 1:1
        uint256 tracked = totalAssets();
        if (tracked == 0) return 0; // drained: shares are worthless
        return assets.mulDiv(supply, tracked, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        uint256 supply = _totalSupply;
        if (supply == 0) return shares; // genesis: 1:1
        return shares.mulDiv(totalAssets(), supply, rounding);
    }
}

/// @notice The fixed vault: OZ v4.9+ virtual offset (offset 0).
/// @dev virtualShares = 10^offset = 1, virtualAssets = 1. Denominators are
///      always >= 1, so no div-by-zero guard is needed — the offset IS the
///      guard. Ch 16 derives why the donation attack becomes non-profitable.
contract Virtual4626Lab is Abstract4626Lab {
    using Math for uint256;

    constructor(IERC20 asset_) Abstract4626Lab(asset_) {}

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        return assets.mulDiv(_totalSupply + 1, totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override
        returns (uint256)
    {
        return shares.mulDiv(totalAssets() + 1, _totalSupply + 1, rounding);
    }
}
