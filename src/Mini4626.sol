// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniToken} from "./MiniToken.sol";

/// @notice Ch 12 lab vault — a deliberately VULNERABLE ERC4626-flavored vault.
///         LAB ONLY, NOT protocol.
/// @dev Deliberate vulnerabilities (the Ch 16 attack class, on purpose):
///      - floor/floor conversions with NO virtual offset and NO dead shares;
///      - `donate` lets anyone inflate the share price without minting shares
///        (the t11s "Inflation Attack" primitive: deposit, donate, the next
///        depositor mints dust at the inflated price, attacker redeems the
///        captured value);
///      - `totalAssets_` is tracked, so a donation is "free value" the vault
///        cannot explain. The invariant that flags this condition is
///        `totalAssets_ == ghost_totalDeposited` (invariant_noFreeAssets).
///      Ch 16's sMER (StakedMeridian.sol) is the FIXED production version.
///      Naive `assets * supply` multiplication (no full-precision mulDiv) is
///      intentional and safe under the handler's bounded domains (Ch 4/20 do
///      mulDiv properly for production).
contract Mini4626 {
    MiniToken public immutable asset;

    /// @dev Tracked assets held (deposits + "free" donations).
    uint256 public totalAssets_;
    /// @dev Share supply.
    uint256 public totalSupply_;
    /// @dev Share balances.
    mapping(address => uint256) public balanceOf;

    error ZeroAssets();
    error ZeroShares();
    error InsufficientShares(uint256 have, uint256 need);

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Redeem(address indexed caller, address indexed owner, uint256 shares, uint256 assets);
    event Donated(address indexed donor, uint256 assets);

    constructor(MiniToken _asset) {
        asset = _asset;
    }

    /// @notice Mint shares against `assets` of the underlying token.
    /// @dev Floor rounding can mint ZERO shares when the share price is
    ///      inflated — the attack's capture edge (ZeroShares revert).
    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();
        asset.transferFrom(msg.sender, address(this), assets);
        totalAssets_ += assets;
        balanceOf[msg.sender] += shares;
        totalSupply_ += shares;
        emit Deposit(msg.sender, msg.sender, assets, shares);
    }

    /// @notice Burn `shares` and return the pro-rata assets.
    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        if (shares == 0) revert ZeroShares();
        uint256 bal = balanceOf[msg.sender];
        if (bal < shares) revert InsufficientShares(bal, shares);
        assetsOut = convertToAssets(shares);
        balanceOf[msg.sender] = bal - shares;
        totalSupply_ -= shares;
        totalAssets_ -= assetsOut;
        asset.transfer(msg.sender, assetsOut);
        emit Redeem(msg.sender, msg.sender, shares, assetsOut);
    }

    /// @notice Pull `assets` in WITHOUT minting shares — the attack primitive.
    /// @dev Inflates the share price (totalAssets_ up, totalSupply_ unchanged).
    ///      invariant_noFreeAssets (totalAssets_ == ghost_totalDeposited) is
    ///      exactly the detector for this function.
    function donate(uint256 assets) external {
        if (assets == 0) revert ZeroAssets();
        asset.transferFrom(msg.sender, address(this), assets);
        totalAssets_ += assets;
        emit Donated(msg.sender, assets);
    }

    /// @notice Floor conversion: assets -> shares at the current price.
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply_;
        if (supply == 0) return assets; // genesis: 1:1
        uint256 tracked = totalAssets_;
        if (tracked == 0) return 0; // drained vault: shares are worthless
        return assets * supply / tracked;
    }

    /// @notice Floor conversion: shares -> assets at the current price.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply_;
        if (supply == 0) return shares; // genesis: 1:1
        return shares * totalAssets_ / supply;
    }
}
