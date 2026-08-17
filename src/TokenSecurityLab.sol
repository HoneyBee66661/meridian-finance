// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITokenSecurityLab} from "./ITokenSecurityLab.sol";

// ═══════════════════════════════════════════════════════════════════════════
// (a) Approval races — the token baseline, the relative-helper fix, and the
//     integrator-side two-step that Ch 14 already demoed against MER.
// ═══════════════════════════════════════════════════════════════════════════

/// @title Lab ERC20 with an unrestricted mint (LAB ONLY, NOT protocol).
/// @notice The plain-EIP-20 baseline for the approval-race and fee-on-transfer
///         demos. `approve` is the standard ABSOLUTE setter — deliberately
///         race-prone exactly as EIP-20 ships it.
contract LabToken is ERC20 {
    constructor() ERC20("Lab Token", "LAB") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

/// @title Lab ERC20 with OZ-v4-style relative allowance helpers (LAB ONLY).
/// @notice Demonstrates the `increaseAllowance`/`decreaseAllowance` mitigation
///         that OpenZeppelin v4 shipped and v5 REMOVED (Ch 14 finding #1). The
///         helper is race-free because it is a single atomic read-modify-write:
///         `decreaseAllowance(d)` lands at exactly `allowance - d`, so a
///         front-run cannot capture the old value AND the new value — there is
///         only one transaction to front-run, and a spender who already drained
///         the old allowance makes the decrease revert instead of minting a
///         fresh one on top.
contract LabTokenWithHelpers is ERC20 {
    constructor() ERC20("Lab Token Helpers", "LABH") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    /// @notice Atomically raises the allowance by `delta`.
    function increaseAllowance(address spender, uint256 delta) external returns (bool) {
        _approve(msg.sender, spender, allowance(msg.sender, spender) + delta);
        return true;
    }

    /// @notice Atomically lowers the allowance by `delta`.
    /// @dev Reverts `InsufficientBalance(current, delta)` when the spender
    ///      already spent the old allowance (current < delta) — the property
    ///      that bounds the race (Ch 17, lab test).
    function decreaseAllowance(address spender, uint256 delta) external returns (bool) {
        uint256 current = allowance(msg.sender, spender);
        if (current < delta) revert ITokenSecurityLab.InsufficientBalance(current, delta);
        _approve(msg.sender, spender, current - delta);
        return true;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// (b) Fee-on-transfer tokens — the token, the naive (broken) integrator, and
//     the delta-measuring (fixed) integrator.
// ═══════════════════════════════════════════════════════════════════════════

/// @title Lab fee-on-transfer token (LAB ONLY, NOT protocol).
/// @notice Charges a fixed-percentage transfer fee that is BURNED. The sender
///         pays `value`, the recipient receives `value - fee`. This is the
///         classic class of token where the credited balance delta does NOT
///         equal the requested transfer amount. Mint and burn paths are
///         fee-free (the fee only applies to real transfers).
contract FeeOnTransferToken is ERC20 {
    /// @dev 1% — charged on every transfer.
    uint256 public constant FEE_BPS = 100;

    constructor() ERC20("Fee On Transfer", "FEE") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, to, value - fee);
            super._update(from, address(0), fee); // burn the fee
        } else {
            super._update(from, to, value);
        }
    }
}

/// @title Naive fee integrator — credits the REQUESTED amount (LAB, broken).
/// @notice The bug: `deposit` records `amount` as received even though a
///         fee-on-transfer token only delivered `amount - fee`. Liabilities
///         grow faster than the real balance, so a single full deposit makes
///         the integrator insolvent — the redeemer can never be paid in full.
///         This is the class of bug the 2021 token-tax wave produced across
///         yield aggregators and lending markets.
contract NaiveFeeIntegrator is ITokenSecurityLab {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    mapping(address => uint256) public credits;

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        credits[msg.sender] += amount; // BUG: credited != received
    }

    function redeem(uint256 amount) external {
        if (credits[msg.sender] < amount) revert InsufficientBalance(credits[msg.sender], amount);
        credits[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount); // reverts once the balance runs out
    }
}

/// @title Delta fee integrator — credits the MEASURED delta (LAB, fixed).
/// @notice The fix: measure `balanceOf(this)` before and after the pull and
///         credit exactly the received delta, so `Σ credits == real balance`
///         stays true and every credit is backed. The two `balanceOf` reads
///         are the price of correctness (~2 external calls per deposit) —
///         measured in the Ch 17 lab gas probe.
contract DeltaFeeIntegrator is ITokenSecurityLab {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    mapping(address => uint256) public credits;

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        credits[msg.sender] += received; // fixed: received, not requested
    }

    function redeem(uint256 amount) external {
        if (credits[msg.sender] < amount) revert InsufficientBalance(credits[msg.sender], amount);
        credits[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// (c) Rebasing tokens — the elastic-supply token, the raw-unit vault (broken),
//     and the share-of-balance vault (fixed, Ch 16's 4626 answer).
// ═══════════════════════════════════════════════════════════════════════════

/// @title Lab rebasing token (LAB ONLY, NOT protocol).
/// @notice Elastic-supply token in the AMPL/gons tradition. Balances are
///         stored in raw "gons"; `balanceOf(a) = gons[a] * _rate / BASE`.
///         A rebase changes ONLY `_rate`, so every holder's balance scales
///         together and the per-account cost is O(1) — no per-account loop.
///         Positive rebase (rate up) grows balances; negative shrinks them.
/// @dev Implements the full IERC20 surface so integrators can pull it with
///      SafeERC20. The gons math: `_gonsFor(value) = value * BASE / _rate`,
///      so `balanceOf` round-trips `value` while `_rate == BASE`.
contract RebasingToken is IERC20, ITokenSecurityLab {
    using Math for uint256;

    uint256 public constant BASE = 1e18;

    uint8 public constant decimals = 18;

    string private constant _NAME = "Rebasing Token";
    string private constant _SYMBOL = "REB";

    uint256 internal _totalGons;
    uint256 internal _rate = BASE; // fragments per gon, scaled by BASE
    mapping(address => uint256) internal _gons;
    mapping(address => mapping(address => uint256)) internal _allowances;

    // Transfer/Approval events are inherited from IERC20 (single declaration).

    function name() external pure returns (string memory) {
        return _NAME;
    }

    function symbol() external pure returns (string memory) {
        return _SYMBOL;
    }

    function totalSupply() external view returns (uint256) {
        return _totalGons.mulDiv(_rate, BASE);
    }

    function balanceOf(address account) public view returns (uint256) {
        return _gons[account].mulDiv(_rate, BASE);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (_allowances[from][msg.sender] != type(uint256).max) {
            if (_allowances[from][msg.sender] < value) {
                revert InsufficientBalance(_allowances[from][msg.sender], value);
            }
            _allowances[from][msg.sender] -= value;
        }
        _transfer(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) external {
        uint256 gons = _gonsFor(value);
        _totalGons += gons;
        _gons[to] += gons;
        emit Transfer(address(0), to, value);
    }

    /// @notice Rebase the supply by `bps` basis points. Positive grows every
    ///         balance; negative shrinks it. LAB ONLY — real rebasers are
    ///         driven by an oracle/policy contract, never user-callable.
    function rebase(int256 bps) external {
        if (bps <= -10_000 || bps >= 10_000) revert RebaseOutOfBounds(bps);
        uint256 factor = bps >= 0 ? 10_000 + uint256(bps) : 10_000 - uint256(-bps);
        _rate = _rate.mulDiv(factor, 10_000);
    }

    function _transfer(address from, address to, uint256 value) internal {
        uint256 gons = _gonsFor(value);
        if (_gons[from] < gons) revert InsufficientBalance(balanceOf(from), value);
        _gons[from] -= gons;
        _gons[to] += gons;
        emit Transfer(from, to, value);
    }

    /// @dev Gons needed to represent `value` fragments at the current rate.
    function _gonsFor(uint256 value) internal view returns (uint256) {
        return value.mulDiv(BASE, _rate);
    }
}

/// @title Naive rebase vault — raw-unit accounting (LAB, broken).
/// @notice Records deposits in token units and pays 1:1. A rebase moves the
///         vault's real balance but not the recorded liabilities, so a
///         POSITIVE rebase creates unbacked surplus (free value that no
///         share claims) and a NEGATIVE rebase makes the vault insolvent —
///         the last redeemer cannot be paid. Ch 16's `totalAssets()`-reads-
///         the-balance pattern is deliberately ABSENT: this vault tracks an
///         internal ledger and never looks at its balance.
contract NaiveRebaseVault is ITokenSecurityLab {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    mapping(address => uint256) public shares; // 1:1 with tracked units
    uint256 public totalTracked;

    constructor(RebasingToken token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += amount; // raw-unit credit — breaks on rebase
        totalTracked += amount;
    }

    function redeem(uint256 amount) external {
        if (shares[msg.sender] < amount) revert InsufficientBalance(shares[msg.sender], amount);
        shares[msg.sender] -= amount;
        totalTracked -= amount;
        token.safeTransfer(msg.sender, amount); // pays real balance 1:1
    }

    /// @notice The divergence between the real balance and the recorded
    ///         liabilities. Positive after a positive rebase (free value),
    ///         negative after a negative rebase (insolvency).
    function surplus() external view returns (int256) {
        return int256(token.balanceOf(address(this))) - int256(totalTracked);
    }
}

/// @title Fractional rebase vault — share-of-balance accounting (LAB, fixed).
/// @notice Ch 16's 4626-style answer: `totalAssets()` reads the live balance,
///         shares are minted proportionally, and redemption pays the
///         depositor's share of the CURRENT balance. Because a rebase scales
///         every holder's balance together, the fractional split is invariant
///         under rebase — no free value, no insolvency.
contract FractionalRebaseVault is ITokenSecurityLab {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public immutable token;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    constructor(RebasingToken token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    function totalAssets() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        if (amount == 0) revert ZeroAmount();
        uint256 supply = totalShares;
        uint256 assets = totalAssets();
        minted = supply == 0 ? amount : amount.mulDiv(supply, assets);
        token.safeTransferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += minted;
        totalShares += minted;
    }

    function redeem(uint256 shareAmount) external returns (uint256 paid) {
        if (shares[msg.sender] < shareAmount) {
            revert InsufficientBalance(shares[msg.sender], shareAmount);
        }
        paid = shareAmount.mulDiv(totalAssets(), totalShares);
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        token.safeTransfer(msg.sender, paid);
    }
}
