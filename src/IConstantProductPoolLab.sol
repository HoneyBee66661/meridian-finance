// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Ch 18 lab interface — the constant-product pool surface shared by the
///         safe (floor-out) and unsafe (ceil-out) pool twins. LAB ONLY, NOT
///         protocol.
/// @dev The error catalog lives HERE, per the Ch 2/14 convention (OZ v5
///      I-prefix pattern: errors on the interface). `Reentrancy` is the
///      Ch 1/24 lock-modifier error; `SlippageExceeded` carries the trader's
///      guard (minimum out) vs the computed out; `NotAuthorized` guards the
///      one privileged surface (swap-fee key) so the lab has a non-privileged
///      negative test per the Ch 10 convention.
interface IConstantProductPoolLab {
    error ZeroAmount();
    error InsufficientLiquidity();
    error InsufficientShares(uint256 have, uint256 need);
    error SlippageExceeded(uint256 expected, uint256 actual);
    error NotAuthorized(address caller);
    error FeeOutOfBounds(uint256 fee);
    error Reentrancy();

    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Mint(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to, uint256 liquidity);
    event Sync(uint256 reserve0, uint256 reserve1);
    event SwapFeeSet(uint256 fee);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function MINIMUM_LIQUIDITY() external view returns (uint256);
    function swapFee() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1);

    /// @notice Spot price of token0 in token1, scaled by 1e18: reserve1/reserve0.
    function spotPrice() external view returns (uint256 price);

    /// @notice Amount of the OUT token received for `amountIn` of the IN token.
    /// @param zeroForOne true: in = token0, out = token1; false: the reverse.
    function getAmountOut(uint256 amountIn, bool zeroForOne) external view returns (uint256 amountOut);

    /// @notice Add `amount0`/`amount1` and mint LP shares (Uniswap-v2 shape:
    ///         first mint = sqrt(x·y) − MINIMUM_LIQUIDITY, later = min ratio).
    function addLiquidity(uint256 amount0, uint256 amount1) external returns (uint256 liquidity);

    /// @notice Burn `liquidity` shares and withdraw a pro-rata slice of reserves.
    function removeLiquidity(uint256 liquidity, address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap `amountIn` of one token for the other; `amountOutMin` is the
    ///         trader's slippage guard. Reverts `SlippageExceeded` if exceeded.
    function swap(uint256 amountIn, uint256 amountOutMin, bool zeroForOne, address to)
        external
        returns (uint256 amountOut);

    /// @notice Reset reserves to actual token balances (absorbs donations).
    function sync() external;

    /// @notice Set the fee in bps (3 = 0.3%). Owner-only: a fee key is an admin
    ///         key (Kelp DAO/Drift class, Ch 25).
    function setSwapFee(uint256 fee) external;
}
