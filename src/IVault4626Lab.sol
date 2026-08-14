// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Ch 16 lab interface — the ERC4626-shaped surface shared by the two
///         lab vaults (Naive4626Lab, Virtual4626Lab). LAB ONLY, NOT protocol.
/// @dev Mirrors EIP-4626's four entry points + preview/max/convert surface.
///      `donate` is the lab's attack primitive (pulls assets without minting);
///      in production the attacker never calls a vault function — a plain
///      asset transfer into the vault is the donation, because totalAssets()
///      reads the asset balance. The error catalog lives HERE, per the
///      Ch 2/14 convention (OZ v5 I-prefix pattern: errors on the interface).
interface IVault4626Lab {
    error ZeroAssets();
    error ZeroShares();
    error InsufficientShares(uint256 have, uint256 need);
    error UnauthorizedCaller(address caller, address owner);
    error ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Donated(address indexed donor, uint256 assets);

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    function maxDeposit(address receiver) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Lab attack primitive: pull `assets` in WITHOUT minting shares.
    /// @dev LAB ONLY. Not part of EIP-4626. See file-level @dev.
    function donate(uint256 assets) external;
}
