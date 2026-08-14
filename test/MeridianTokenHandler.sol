// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MeridianToken} from "../src/MeridianToken.sol";

/// @notice Ch 14 invariant handler — wraps MeridianToken's state-changing ops
///         (mint / transfer / burn) with bounded arguments. TEST-ONLY.
/// @dev Ch 12 rules held: arguments `bound` to realistic domains; sequences
///      never revert (every revert edge pre-checked, so `[invariant]
///      fail_on_revert = true` holds); the handler is the sole active holder —
///      the invariant sums the COMPLETE holder set (handler + 3 users), which
///      is what makes the conservation check meaningful. Note: permit/approve
///      are deliberately excluded (allowance accounting is pinned by fuzz in
///      MeridianToken.t.sol; sequence exploration adds nothing there).
contract MeridianTokenHandler is Test {
    MeridianToken public token;
    address public user0;
    address public user1;
    address public user2;

    constructor(MeridianToken _token, address _user0, address _user1, address _user2) {
        token = _token;
        user0 = _user0;
        user1 = _user1;
        user2 = _user2;
    }

    /// @notice Handler mint: bounded amount, minted to self (handler holds
    ///         MINTER_ROLE, granted in the invariant test's setUp).
    function mintToSelf(uint256 amountRaw) external {
        uint256 amount = bound(amountRaw, 0, 1e27);
        token.mint(address(this), amount);
    }

    /// @notice Handler transfer: bounded to the handler's own balance, to one
    ///         of the three tracked users. Never reverts.
    function transferToUser(uint256 userSeed, uint256 amountRaw) external {
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) return;
        uint256 amount = bound(amountRaw, 0, bal);
        address to = userSeed % 3 == 0 ? user0 : userSeed % 3 == 1 ? user1 : user2;
        token.transfer(to, amount);
    }

    /// @notice Handler burn: bounded to the handler's own balance. Never reverts.
    function burnSelf(uint256 amountRaw) external {
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) return;
        uint256 amount = bound(amountRaw, 0, bal);
        token.burn(amount);
    }
}
