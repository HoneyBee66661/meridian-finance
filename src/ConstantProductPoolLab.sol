// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IConstantProductPoolLab} from "./IConstantProductPoolLab.sol";

/// @title Ch 18 constant-product pool lab
/// @notice A Uniswap-v2-shaped x·y=k pool whose two concrete twins differ in
///         exactly ONE line: the amount-out rounding direction.
/// @dev LAB ONLY, NOT protocol. The base implements the full surface faithful
///      to Uniswap V2 `Pair.sol`: fee on the INPUT (0.3% bps), reserves as
///      measured token balances (`_update` from `balanceOf`), MINIMUM_LIQUIDITY
///      dead shares, and a `lock` reentrancy modifier. The two twins:
///        - ConstantProductPool — amount-out FLOORED. The pool keeps the dust;
///          the with-fee invariant k' = (x + in)(y − out) drifts UP with fees.
///        - CeilOutPool — amount-out CEILED (the Balancer-V2-style rounding
///          direction: the trader, not the pool, gets the rounding edge). Even
///          with the fee removed, rounding up leaks k over repeated swaps —
///          the flaw class Ch 26 treats in full.
///      The owner is the deployer; the only privileged surface is the swap-fee
///      key (a fee key is an admin key, Kelp DAO/Drift class, Ch 25).
abstract contract AbstractConstantProductPool is IConstantProductPoolLab {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev Uniswap V2 minimum liquidity: dead shares minted to address(0) so
    ///      totalSupply never reaches zero and the first-depositor ratio cannot
    ///      be attacked by a later full withdrawal.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    /// @dev Fee basis denominator: 3/1000 = 0.3% (Uniswap V2's fee).
    uint256 public constant FEE_BASE = 1_000;

    // OZ _asset pattern (Ch 16 finding #1): a public IERC20 state var cannot
    // satisfy the interface's `token0() returns (address)` — explicit getters.
    IERC20 internal immutable _token0;
    IERC20 internal immutable _token1;
    address public immutable owner;

    /// @notice Swap fee in bps (3 = 0.3%), charged on the INPUT.
    uint256 public swapFee;

    uint256 internal _reserve0;
    uint256 internal _reserve1;
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balanceOf;
    bool internal _locked;

    /// @dev token0/token1 are the constructor args in order (a lab simplification;
    ///      the real V2 factory sorts them by address).
    constructor(IERC20 token0_, IERC20 token1_) {
        _token0 = token0_;
        _token1 = token1_;
        owner = msg.sender;
    }

    function token0() external view returns (address) {
        return address(_token0);
    }

    function token1() external view returns (address) {
        return address(_token1);
    }

    /// @dev Reentrancy guard, Uniswap-V2-style. State is updated before the
    ///      token transfers in swap(), so the lock is belt-and-suspenders —
    ///      but it is the canonical answer to the Ch 24 reentrancy class.
    modifier lock() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ── views ───────────────────────────────────────────────────────────────

    function getReserves() external view returns (uint256 reserve0, uint256 reserve1) {
        return (_reserve0, _reserve1);
    }

    /// @dev Spot price of token0 in token1, scaled 1e18. From the invariant
    ///      y = k/x, dy/dx = −k/x² = −y/x; the magnitude |dy/dx| = y/x.
    function spotPrice() external view returns (uint256 price) {
        return _reserve1 * 1e18 / _reserve0;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    /// @dev The Uniswap V2 getAmountOut formula, restated as the invariant
    ///      solves it: out = y − k/(x + in·(1−f)). Fee applied to the INPUT —
    ///      the trader's effective input is in·997/1000, so the pool records
    ///      the full `in` as reserve growth and the fee drifts k upward.
    function getAmountOut(uint256 amountIn, bool zeroForOne)
        public
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        amountOut = _amountOut(amountIn, reserveIn, reserveOut);
    }

    // ── state-changing ──────────────────────────────────────────────────────

    /// @notice Swap `amountIn` for the other token. CEI: reserves update BEFORE
    ///         the token transfers; `amountOutMin` is the trader's slippage guard.
    function swap(uint256 amountIn, uint256 amountOutMin, bool zeroForOne, address to)
        external
        lock
        returns (uint256 amountOut)
    {
        amountOut = getAmountOut(amountIn, zeroForOne);
        if (amountOut < amountOutMin) revert SlippageExceeded(amountOutMin, amountOut);

        if (zeroForOne) {
            _reserve0 += amountIn;
            _reserve1 -= amountOut;
        } else {
            _reserve1 += amountIn;
            _reserve0 -= amountOut;
        }

        if (zeroForOne) {
            _token0.safeTransferFrom(msg.sender, address(this), amountIn);
            _token1.safeTransfer(to, amountOut);
        } else {
            _token1.safeTransferFrom(msg.sender, address(this), amountIn);
            _token0.safeTransfer(to, amountOut);
        }

        emit Swap(
            msg.sender,
            zeroForOne ? amountIn : 0,
            zeroForOne ? 0 : amountIn,
            zeroForOne ? 0 : amountOut,
            zeroForOne ? amountOut : 0,
            to
        );
    }

    /// @notice Deposit `amount0`/`amount1` and mint LP shares.
    /// @dev First mint: liquidity = sqrt(x·y) − MINIMUM_LIQUIDITY, with 1000 dead
    ///      shares burned to address(0). Later mints: the SMALLER ratio
    ///      min(Δ0·TS/reserve0, Δ1·TS/reserve1) — the depositor who brings an
    ///      imbalanced pair gets the binding ratio and the excess is a donation.
    function addLiquidity(uint256 amount0, uint256 amount1)
        external
        lock
        returns (uint256 liquidity)
    {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        _token0.safeTransferFrom(msg.sender, address(this), amount0);
        _token1.safeTransferFrom(msg.sender, address(this), amount1);

        uint256 balance0 = _token0.balanceOf(address(this));
        uint256 balance1 = _token1.balanceOf(address(this));
        uint256 d0 = balance0 - _reserve0;
        uint256 d1 = balance1 - _reserve1;

        uint256 total = _totalSupply;
        if (total == 0) {
            liquidity = Math.sqrt(d0 * d1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // dead shares, locked forever
        } else {
            liquidity = Math.min(d0 * total / _reserve0, d1 * total / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidity();

        _mint(msg.sender, liquidity);
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Burn `liquidity` shares and withdraw a pro-rata slice of reserves.
    /// @dev Both amounts FLOOR (the pool keeps the dust), and the transfer
    ///      happens after the burn (CEI).
    function removeLiquidity(uint256 liquidity, address to)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) revert ZeroAmount();
        uint256 have = _balanceOf[msg.sender];
        if (have < liquidity) revert InsufficientShares(have, liquidity);

        uint256 total = _totalSupply;
        uint256 balance0 = _token0.balanceOf(address(this));
        uint256 balance1 = _token1.balanceOf(address(this));
        amount0 = liquidity * balance0 / total;
        amount1 = liquidity * balance1 / total;

        _burn(msg.sender, liquidity);
        _token0.safeTransfer(to, amount0);
        _token1.safeTransfer(to, amount1);

        _update(_token0.balanceOf(address(this)), _token1.balanceOf(address(this)));
        emit Burn(msg.sender, amount0, amount1, to, liquidity);
    }

    /// @notice Permissionless (as in V2): re-read reserves from balances so a
    ///         direct transfer (a donation) becomes part of the invariant.
    function sync() external {
        _update(_token0.balanceOf(address(this)), _token1.balanceOf(address(this)));
    }

    /// @notice Set the swap fee in bps. Owner-only — the fee key is a trust root.
    function setSwapFee(uint256 fee) external {
        if (msg.sender != owner) revert NotAuthorized(msg.sender);
        if (fee >= FEE_BASE) revert FeeOutOfBounds(fee);
        swapFee = fee;
        emit SwapFeeSet(fee);
    }

    // ── internals ───────────────────────────────────────────────────────────

    /// @dev The one line that separates the safe pool from the flawed one.
    ///      Safe: floor — the pool keeps the rounding edge. Flawed: ceil — the
    ///      trader gains a wei the pool must fund, draining k over time.
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        view
        virtual
        returns (uint256);

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        _totalSupply -= amount;
        _balanceOf[from] -= amount;
    }

    function _update(uint256 balance0, uint256 balance1) internal {
        if (balance0 == 0 || balance1 == 0) revert InsufficientLiquidity();
        _reserve0 = balance0;
        _reserve1 = balance1;
        emit Sync(balance0, balance1);
    }
}

/// @notice The safe pool: amount-out FLOORED, 0.3% input fee.
/// @dev With-fee invariant: k' = (x + in)(y − out) ≥ k, strictly > when
///      fee > 0. The pool favors itself on every rounding edge.
contract ConstantProductPool is AbstractConstantProductPool {
    constructor(IERC20 token0_, IERC20 token1_) AbstractConstantProductPool(token0_, token1_) {
        swapFee = 3; // 0.3%, Uniswap V2's fee
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        view
        override
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * (FEE_BASE - swapFee);
        uint256 denominator = reserveIn * FEE_BASE + amountInWithFee;
        // Math.mulDiv default rounding is Floor — the safe direction.
        return Math.mulDiv(amountInWithFee, reserveOut, denominator);
    }
}

/// @notice The flawed twin: amount-out CEILED, ZERO fee.
/// @dev Removing the fee isolates the rounding-direction flaw so the leak is
///      attributable to the ceil alone (Balancer V2 ComposableStablePool,
///      Nov 2025, ~$128M — the rounding-direction class, full treatment Ch 26).
///      With zero fee, the exact out is y − k/(x + in); rounding it UP pays the
///      trader a wei the pool must fund, so k' = (x + in)(y − out) < k whenever
///      the exact out is fractional.
contract CeilOutPool is AbstractConstantProductPool {
    constructor(IERC20 token0_, IERC20 token1_) AbstractConstantProductPool(token0_, token1_) {
        swapFee = 0; // fee removed: the leak is pure rounding
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        view
        override
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * (FEE_BASE - swapFee);
        uint256 denominator = reserveIn * FEE_BASE + amountInWithFee;
        // Rounding.Ceil — the trader gets the rounding edge. THE FLAW.
        return Math.mulDiv(amountInWithFee, reserveOut, denominator, Math.Rounding.Ceil);
    }
}
