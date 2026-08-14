// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Mini4626} from "../src/Mini4626.sol";
import {MiniToken} from "../src/MiniToken.sol";

/// @notice Ch 12 invariant handler — wraps Mini4626's surface with bounded
///         arguments and records ghost variables (the test's independent
///         ledger). TEST-ONLY, NOT protocol.
/// @dev Rules locked in Ch 12:
///      - arguments are `bound` to realistic domains, never `vm.assume`
///        (rejection inside a sequence is not bounding);
///      - sequences never revert, so `[invariant] fail_on_revert = true`
///        holds: every vault revert edge is pre-checked here;
///      - ghosts are single-writer: written here, read only by invariants;
///      - `donate` exists but is deliberately EXCLUDED from the target
///        selector set in the green suite (InvariantProbe.t.sol); the
///        chapter's ZzDonationBreaks experiment targets it and observes
///        invariant_noFreeAssets flip red — the attack detector working.
contract Mini4626Handler is Test {
    Mini4626 public vault;
    MiniToken public token;

    /// @dev Net assets deposited (deposits − redemptions). Ghost, single-writer.
    uint256 public ghost_totalDeposited;
    /// @dev Assets donated (free value). Ghost, single-writer.
    uint256 public ghost_donated;

    constructor(Mini4626 _vault, MiniToken _token) {
        vault = _vault;
        token = _token;
    }

    /// @notice Handler deposit: bound the amount, fund self (lab mint), skip
    ///         the ZeroShares edge, record the ghost.
    function deposit(uint256 assetsRaw) external {
        uint256 assets = bound(assetsRaw, 1, type(uint96).max);
        if (vault.convertToShares(assets) == 0) return; // ZeroShares edge
        token.mint(address(this), assets);
        token.approve(address(vault), assets);
        vault.deposit(assets);
        ghost_totalDeposited += assets;
    }

    /// @notice Handler redeem: bound to the held balance, skip the zero-assets
    ///         edge, record the ghost.
    function redeem(uint256 sharesRaw) external {
        uint256 bal = vault.balanceOf(address(this));
        if (bal == 0) return;
        uint256 shares = bound(sharesRaw, 1, bal);
        uint256 assetsOut = vault.convertToAssets(shares);
        if (assetsOut == 0) return; // worthless-shares edge
        vault.redeem(shares);
        ghost_totalDeposited -= assetsOut;
    }

    /// @notice Handler donate: the adversarial call. NOT in the green suite's
    ///         target selector set (see file header).
    function donate(uint256 assetsRaw) external {
        uint256 assets = bound(assetsRaw, 1, type(uint96).max);
        token.mint(address(this), assets);
        token.approve(address(vault), assets);
        vault.donate(assets);
        ghost_donated += assets;
    }
}
