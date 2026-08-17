// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice LAB ONLY (Ch 13 static-analysis lab) — deliberately flaggable patterns.
/// @dev Expected detector hits, all DOCUMENTED findings (NOT protocol code):
///      - Slither `missing-zero-check` (Low) on `setOwner`; `tx-origin` (Medium) on
///        `sweepByOrigin`; `unchecked-transfer` (Medium) on `withdraw`/`deposit`.
///      - Aderyn `centralization-risk` (`setOwner`), `unsafe-erc20-operation`
///        (`withdraw`/`deposit`), `zero-address-check` (`setOwner`).
///      Each finding has a fixed twin (setOwnerChecked / withdrawChecked) so the
///      detector's hit/no-hit boundary is observable. The file is filtered out of
///      the protocol SAST gate via slither.config.json filter_paths — standing lab
///      convention; the targeted lab run command is in docs/ci-cd-playbook.md.
contract StaticProbe {
    error NotAuthorized(address caller);
    error ZeroAddress();
    error InsufficientBalance(uint256 have, uint256 want);
    error TransferFailed();

    IERC20 public immutable token;
    address public owner;
    mapping(address => uint256) public balances;

    event OwnerSet(address indexed previous, address indexed next);
    event Deposited(address indexed who, uint256 amount);
    event Withdrawn(address indexed who, uint256 amount);

    constructor(IERC20 token_) {
        token = token_;
        owner = msg.sender;
    }

    /// @notice Single-owner switch. FINDING: accepts address(0) — Slither
    ///         `missing-zero-check` (Low), Aderyn `zero-address-check`. The checked
    ///         twin is `setOwnerChecked`.
    function setOwner(address newOwner) external {
        if (msg.sender != owner) revert NotAuthorized(msg.sender);
        owner = newOwner;
        emit OwnerSet(msg.sender, newOwner);
    }

    /// @notice The fixed twin: zero-address rejected up front.
    function setOwnerChecked(address newOwner) external {
        if (msg.sender != owner) revert NotAuthorized(msg.sender);
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerSet(msg.sender, newOwner);
    }

    /// @notice Deposit. FINDING: `transferFrom` return unchecked — Slither
    ///         `unchecked-transfer` (Medium), Aderyn `unsafe-erc20-operation`.
    ///         CEI order is correct (state before external call); only the return
    ///         value is ignored.
    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw. FINDING: `transfer` return unchecked (same detectors).
    ///         The fixed twin is `withdrawChecked`.
    function withdraw(uint256 amount) external {
        if (balances[msg.sender] < amount) {
            revert InsufficientBalance(balances[msg.sender], amount);
        }
        balances[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice The fixed twin: canonical returndata capture (Ch 9) — rds == 0 is
    ///         success (USDT convention), rds != 32 reverts, else decode the bool.
    function withdrawChecked(uint256 amount) external {
        if (balances[msg.sender] < amount) {
            revert InsufficientBalance(balances[msg.sender], amount);
        }
        balances[msg.sender] -= amount;
        _safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Sweep. FINDING: `tx.origin` authorization — Slither `tx-origin`
    ///         (Medium). Ch 1 locked msg.sender-only authorization for protocol
    ///         code; this is the anti-pattern in situ. Note the test-harness
    ///         consequence: forge pins tx.origin to the test contract, so the
    ///         "legitimate owner" path is untestable — part of why the pattern
    ///         is banned.
    function sweepByOrigin(address to) external {
        if (tx.origin != owner) revert NotAuthorized(tx.origin);
        uint256 bal = token.balanceOf(address(this));
        if (bal != 0) token.transfer(to, bal);
    }

    function _safeTransfer(address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) {
            revert TransferFailed();
        }
    }
}
