// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {InvariantLab} from "../src/InvariantLab.sol";

/// @title InvariantLabHandler
/// @notice Bounded handler for the InvariantLab invariant suite (Ch 12 lock).
/// @dev - ghosts are single-writer: written here, read only by invariants;
///      - every call pre-checks the revert edges (ZeroShares/ZeroAssets) so
///        `fail_on_revert = true` (foundry.toml) never trips on a handler call;
///      - previews mirror the contract's floor math via Math.mulDiv.
contract InvariantLabHandler is Test {
    InvariantLab internal lab;
    uint256 public ghost_deposited;
    uint256 public ghost_redeemed;

    constructor(InvariantLab lab_) {
        lab = lab_;
    }

    /// @notice Deposit: bound the amount, skip the ZeroShares edge, record ghost.
    function deposit(uint256 assets) external {
        assets = bound(assets, 1, 1e30);
        if (_previewDeposit(assets) == 0) return; // would revert ZeroShares
        ghost_deposited += assets;
        lab.deposit(assets);
    }

    /// @notice Redeem: bound to the share supply, skip the zero-assets edge, record ghost.
    function redeem(uint256 shares) external {
        uint256 supply = lab.totalShares();
        if (supply == 0) return;
        shares = bound(shares, 1, supply);
        if (_previewRedeem(shares) == 0) return; // would revert ZeroAssets
        ghost_redeemed += lab.redeem(shares);
    }

    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        if (lab.totalShares() == 0) return assets;
        return Math.mulDiv(assets, lab.totalShares(), lab.totalAssets());
    }

    function _previewRedeem(uint256 shares) internal view returns (uint256) {
        if (lab.totalShares() == 0) return shares;
        return Math.mulDiv(shares, lab.totalAssets(), lab.totalShares());
    }
}
