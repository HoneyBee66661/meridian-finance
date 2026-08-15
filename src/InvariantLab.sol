// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IInvariantLab} from "./IInvariantLab.sol";

/// @title InvariantLab
/// @notice Pedagogical ERC-4626-like vault with selectable rounding.
/// @dev NOT part of the protocol. The `useCeil` switch demonstrates the
///      conversionsNeverGain failure; the invariant test catches it.
contract InvariantLab is IInvariantLab {
    uint256 public totalAssetsStored;
    uint256 public totalSharesStored;
    bool public useCeil;

    function deposit(uint256 assets) external returns (uint256 shares) {
        shares = _convertToShares(assets);
        if (shares == 0) revert ZeroShares();
        totalAssetsStored += assets;
        totalSharesStored += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        assets = _convertToAssets(shares);
        if (assets == 0) revert ZeroAssets();
        totalAssetsStored -= assets;
        totalSharesStored -= shares;
    }

    function roundTrip(uint256 assets) external view returns (uint256) {
        return _convertToAssets(_convertToShares(assets));
    }

    function setUseCeil(bool v) external {
        useCeil = v;
    }

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        if (totalSharesStored == 0) return assets;
        uint256 s = Math.mulDiv(assets, totalSharesStored, totalAssetsStored);
        return useCeil ? s + 1 : s; // ceil variant: user gains 1 wei per conversion
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        if (totalSharesStored == 0) return shares;
        uint256 a = Math.mulDiv(shares, totalAssetsStored, totalSharesStored);
        return useCeil ? a + 1 : a; // ceil variant
    }

    function totalAssets() external view returns (uint256) {
        return totalAssetsStored;
    }

    function totalShares() external view returns (uint256) {
        return totalSharesStored;
    }
}
