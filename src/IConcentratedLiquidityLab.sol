// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Ch 19 concentrated-liquidity lab interface
/// @notice The surface of a simplified-but-correct Uniswap v3-flavored pool:
///         positions over [tickLower, tickUpper) ranges, tick-walking swaps,
///         fee-growth accounting (global / outside / inside), and the
///         liquidity<->amount math. LAB ONLY, NOT protocol.
/// @dev Error catalog lives HERE per the Ch 2/14 convention (OZ v5 I-prefix
///      pattern). `SlippageExceeded` mirrors v3's post-swap minimum check;
///      `MaxTickWalk` enforces the Ch 1 bounded-loop rule on the swap walk.
interface IConcentratedLiquidityLab {
    error ZeroAmount();
    error NoLiquidity();
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error InvalidSqrtRatio(uint160 sqrtPriceX96);
    error InsufficientLiquidity(uint128 have, uint128 need);
    error SlippageExceeded(uint256 expected, uint256 actual);
    error NotAuthorized(address caller);
    error MaxTickWalk();

    /// @notice Emitted once when the pool price is first set.
    event Initialize(uint160 sqrtPriceX96, int24 tick);
    /// @notice Emitted when a position is minted (amounts are the tokens pulled).
    event Mint(
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice Emitted after a swap settles; in/out fields are the gross input
    ///         and gross output for the input token per the zeroForOne flag.
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        uint160 sqrtPriceX96,
        int24 tick
    );
    /// @notice Emitted when liquidity is removed; the principal amounts are
    ///         credited to the position's tokensOwed (fees are credited
    ///         separately by the fee-growth accounting).
    event Burn(
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice Emitted when tokensOwed are paid out.
    event Collect(
        address indexed owner, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1
    );

    // ── state-changing ───────────────────────────────────────────────────────

    /// @notice Set the initial price. Reverts if already initialized.
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Mint a position over [tickLower, tickUpper) by depositing up to
    ///         `amount0`/`amount1`; liquidity is derived from the binding
    ///         constraint at the current price and only the exact amounts for
    ///         that liquidity are pulled.
    function mint(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        returns (uint128 liquidity);

    /// @notice Exact-input swap. `zeroForOne` = selling token0. Walks the tick
    ///         bitmap, crossing initialized ticks and their liquidity, and
    ///         reverts SlippageExceeded if the output falls short.
    function swap(uint256 amountIn, bool zeroForOne, uint256 amountOutMin, address to)
        external
        returns (uint256 amountOut);

    /// @notice Remove `liquidity` from a position; the principal value is added
    ///         to tokensOwed (collectable via collect).
    function burn(int24 tickLower, int24 tickUpper, uint128 liquidity) external;

    /// @notice Pay out the caller's tokensOwed for a position.
    function collect(int24 tickLower, int24 tickUpper, address to)
        external
        returns (uint256 amount0, uint256 amount1);

    // ── views ────────────────────────────────────────────────────────────────

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function sqrtPriceX96() external view returns (uint160);
    function tick() external view returns (int24);
    function liquidity() external view returns (uint128);
    function feeGrowthGlobal0() external view returns (uint256);
    function feeGrowthGlobal1() external view returns (uint256);

    /// @notice token0/token1 needed to hold `liquidity` over [sqrtRatioAX96,
    ///         sqrtRatioBX96) at price `sqrtPriceX96` (piecewise by price).
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96_,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity_
    ) external pure returns (uint256 amount0, uint256 amount1);

    /// @notice Max liquidity backing the given amounts over the range at price.
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96_,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (uint128 liquidity_);

    /// @notice Fee growth per unit liquidity accumulated inside the range
    ///         [tickLower, tickUpper), from the global/outside decomposition.
    function getFeeGrowthInside(int24 tickLower, int24 tickUpper, int24 tickCurrent)
        external
        view
        returns (uint256 feeGrowthInside0, uint256 feeGrowthInside1);

    /// @notice Position state keyed by (owner, tickLower, tickUpper).
    function getPosition(address owner, int24 tickLower, int24 tickUpper)
        external
        view
        returns (
            uint128 positionLiquidity,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        );

    /// @notice Per-tick state (the pool's tick table).
    function getTickInfo(int24 t)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0,
            uint256 feeGrowthOutside1,
            bool initialized
        );
}
