// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMathLab} from "./TickMathLab.sol";
import {IConcentratedLiquidityLab} from "./IConcentratedLiquidityLab.sol";

/// @title Ch 19 concentrated-liquidity pool lab
/// @notice A simplified-but-correct Uniswap v3-flavored concentrated pool:
///         liquidity is placed in [tickLower, tickUpper) ranges, the price is a
///         Q64.96 sqrt ratio that moves along the 1.0001^tick curve, swaps walk
///         the tick bitmap crossing initialized ticks, and fees are accounted
///         with the global/outside/inside decomposition of v3's `Tick.sol`.
/// @dev LAB ONLY, NOT protocol. Deliberate simplifications vs v3-core: no
///      tickSpacing (1), no observations oracle, no protocol fee, no price
///      limit (slippage guard is amountOutMin instead), and the position is a
///      per-(owner, lower, upper) mapping rather than the ERC-721
///      NonfungiblePositionManager (that NFT surface is a periphery concern,
///      discussed in the chapter). The swap loop is faithful: `computeSwapStep`
///      per tick, fee growth per step credited to the pre-cross liquidity, and
///      `state.tick = zeroForOne ? tickNext - 1 : tickNext` on crossing (v3
///      convention). Rounding directions match v3: input deltas round UP, output
///      deltas round DOWN (Ch 4 policy).
contract ConcentratedLiquidityLab is IConcentratedLiquidityLab {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev Q96 = 2^96, the fixed-point scale of sqrtPriceX96 (Ch 4 tie-in).
    uint256 private constant Q96 = 0x1000000000000000000000000;
    /// @dev Q128 = 2^128, the scale of fee-growth accumulators.
    uint256 private constant Q128 = 0x100000000000000000000000000000000;

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0;
        uint256 feeGrowthOutside1;
        bool initialized;
    }

    struct PositionInfo {
        uint128 liquidity;
        uint256 feeGrowthInside0Last;
        uint256 feeGrowthInside1Last;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @dev Per-tick swap step (v3 `StepComputations`): the result of consuming
    ///      input within one tick range.
    struct StepComputation {
        uint160 sqrtPriceNext;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    /// @dev The mutable loop state of a swap (v3 `SwapState`), kept in a memory
    ///      struct so the tick-walk compiles without stack-too-deep.
    struct SwapState {
        uint256 grossRemaining;
        uint256 amountOutAccum;
        uint160 sqrtPrice;
        int24 tick;
        uint128 activeLiquidity;
    }

    // OZ _asset pattern (Ch 16 finding #1): private IERC20 + explicit getters.
    IERC20 internal immutable _token0;
    IERC20 internal immutable _token1;
    /// @dev Fee in hundredths of a bip (3000 = 0.3%), Uniswap v3 convention.
    uint24 public immutable fee;

    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public liquidity;
    uint256 public feeGrowthGlobal0;
    uint256 public feeGrowthGlobal1;

    /// @dev tick → per-tick liquidity/fee state (the "tick table").
    mapping(int24 => TickInfo) internal _tickInfo;
    /// @dev packed word → bitmap of initialized ticks (Ch 19 TickBitmap).
    mapping(int16 => uint256) internal _tickBitmap;
    /// @dev keccak(owner, tickLower, tickUpper) → position state.
    mapping(bytes32 => PositionInfo) internal _positions;

    constructor(IERC20 token0_, IERC20 token1_, uint24 fee_) {
        _token0 = token0_;
        _token1 = token1_;
        fee = fee_;
    }

    function token0() external view returns (address) {
        return address(_token0);
    }

    function token1() external view returns (address) {
        return address(_token1);
    }

    // ── initialize / mint / burn / collect ───────────────────────────────────

    /// @inheritdoc IConcentratedLiquidityLab
    function initialize(uint160 sqrtPriceX96_) external {
        if (sqrtPriceX96 != 0) revert NotAuthorized(msg.sender); // set-once guard
        if (sqrtPriceX96_ < TickMathLab.MIN_SQRT_RATIO || sqrtPriceX96_ >= TickMathLab.MAX_SQRT_RATIO) {
            revert InvalidSqrtRatio(sqrtPriceX96_);
        }
        sqrtPriceX96 = sqrtPriceX96_;
        tick = TickMathLab.getTickAtSqrtRatio(sqrtPriceX96_);
        emit Initialize(sqrtPriceX96_, tick);
    }

    /// @inheritdoc IConcentratedLiquidityLab
    function mint(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        external
        returns (uint128 liquidityAmount)
    {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        if (tickLower < TickMathLab.MIN_TICK || tickUpper > TickMathLab.MAX_TICK) {
            revert InvalidTickRange(tickLower, tickUpper);
        }
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        liquidityAmount = getLiquidityForAmounts(
            sqrtPriceX96, TickMathLab.getSqrtRatioAtTick(tickLower), TickMathLab.getSqrtRatioAtTick(tickUpper),
            amount0, amount1
        );
        if (liquidityAmount == 0) revert ZeroAmount();

        _updatePosition(msg.sender, tickLower, tickUpper, int128(liquidityAmount));

        (uint256 need0, uint256 need1) = getAmountsForLiquidity(
            sqrtPriceX96, TickMathLab.getSqrtRatioAtTick(tickLower), TickMathLab.getSqrtRatioAtTick(tickUpper),
            liquidityAmount
        );
        if (need0 > 0) _token0.safeTransferFrom(msg.sender, address(this), need0);
        if (need1 > 0) _token1.safeTransferFrom(msg.sender, address(this), need1);

        emit Mint(msg.sender, tickLower, tickUpper, liquidityAmount, need0, need1);
    }

    /// @inheritdoc IConcentratedLiquidityLab
    function burn(int24 tickLower, int24 tickUpper, uint128 liquidityToRemove) external {
        if (liquidityToRemove == 0) revert ZeroAmount();
        bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
        if (_positions[key].liquidity < liquidityToRemove) {
            revert InsufficientLiquidity(_positions[key].liquidity, liquidityToRemove);
        }

        _updatePosition(msg.sender, tickLower, tickUpper, -int128(liquidityToRemove));

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            sqrtPriceX96, TickMathLab.getSqrtRatioAtTick(tickLower), TickMathLab.getSqrtRatioAtTick(tickUpper),
            liquidityToRemove
        );
        _positions[key].tokensOwed0 += uint128(amount0);
        _positions[key].tokensOwed1 += uint128(amount1);

        emit Burn(msg.sender, tickLower, tickUpper, liquidityToRemove, amount0, amount1);
    }

    /// @inheritdoc IConcentratedLiquidityLab
    function collect(int24 tickLower, int24 tickUpper, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        PositionInfo storage position = _positions[_positionKey(msg.sender, tickLower, tickUpper)];
        amount0 = position.tokensOwed0;
        amount1 = position.tokensOwed1;
        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;
        if (amount0 > 0) _token0.safeTransfer(to, amount0);
        if (amount1 > 0) _token1.safeTransfer(to, amount1);
        emit Collect(msg.sender, tickLower, tickUpper, amount0, amount1);
    }

    // ── swap ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IConcentratedLiquidityLab
    function swap(uint256 amountIn, bool zeroForOne, uint256 amountOutMin, address to)
        external
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (liquidity == 0) revert NoLiquidity();

        SwapState memory state = SwapState({
            grossRemaining: amountIn,
            amountOutAccum: 0,
            sqrtPrice: sqrtPriceX96,
            tick: tick,
            activeLiquidity: liquidity
        });
        uint256 iterations;

        while (state.grossRemaining > 0) {
            // Ch 1 bounded-loop rule: the walk cannot run away even if the
            // test setup leaves a pathological gap.
            if (++iterations > 1024) revert MaxTickWalk();

            (int24 nextTick, bool initialized) = _nextInitializedTickWithinOneWord(state.tick, zeroForOne);
            if (nextTick < TickMathLab.MIN_TICK) nextTick = TickMathLab.MIN_TICK;
            else if (nextTick > TickMathLab.MAX_TICK) nextTick = TickMathLab.MAX_TICK;

            uint160 sqrtPriceNextTarget = nextTick == TickMathLab.MIN_TICK
                ? TickMathLab.MIN_SQRT_RATIO
                : nextTick == TickMathLab.MAX_TICK ? TickMathLab.MAX_SQRT_RATIO : TickMathLab.getSqrtRatioAtTick(nextTick);

            if (state.sqrtPrice == sqrtPriceNextTarget) break; // already at a boundary

            // Swap-math per tick (v3 SwapMath.computeSwapStep, exact-input only).
            StepComputation memory step = _computeSwapStep(
                state.sqrtPrice, sqrtPriceNextTarget, state.activeLiquidity, state.grossRemaining, zeroForOne
            );

            state.amountOutAccum += step.amountOut;
            if (step.sqrtPriceNext == sqrtPriceNextTarget) {
                // amountIn + feeAmount <= grossRemaining guaranteed by the
                // full-step condition (the fee-inclusive gross of a full step fits).
                state.grossRemaining -= step.amountIn + step.feeAmount;
            } else {
                state.grossRemaining = 0; // partial step exhausts the input
            }
            state.sqrtPrice = step.sqrtPriceNext;

            // Fees accrue to the liquidity active during THIS step (v3 order:
            // fee growth is credited before any tick crossing in the step).
            if (step.feeAmount > 0) {
                if (zeroForOne) {
                    feeGrowthGlobal0 += Math.mulDiv(step.feeAmount, Q128, state.activeLiquidity);
                } else {
                    feeGrowthGlobal1 += Math.mulDiv(step.feeAmount, Q128, state.activeLiquidity);
                }
            }

            if (step.sqrtPriceNext == sqrtPriceNextTarget) {
                if (initialized) {
                    int128 liquidityNet = _crossTick(nextTick);
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.activeLiquidity = uint128(int128(int256(uint256(state.activeLiquidity)) + liquidityNet));
                }
                // v3 crossing convention: moving left, the current tick is one
                // below the crossed tick.
                state.tick = zeroForOne ? nextTick - 1 : nextTick;
                // A real pool always has liquidity at the current price (ranges
                // tile the curve), so crossing into empty space is a lab
                // artifact: stop the walk and refund the unconsumed input.
                if (state.activeLiquidity == 0) break;
                if (nextTick == TickMathLab.MIN_TICK || nextTick == TickMathLab.MAX_TICK) break; // boundary reached
            } else {
                state.tick = TickMathLab.getTickAtSqrtRatio(state.sqrtPrice);
                break;
            }
        }

        if (state.amountOutAccum < amountOutMin) revert SlippageExceeded(amountOutMin, state.amountOutAccum);

        // CEI: state is fully updated before the token transfers.
        sqrtPriceX96 = state.sqrtPrice;
        tick = state.tick;
        liquidity = state.activeLiquidity;

        uint256 grossConsumed = amountIn - state.grossRemaining;
        if (zeroForOne) {
            _token0.safeTransferFrom(msg.sender, address(this), grossConsumed);
            _token1.safeTransfer(to, state.amountOutAccum);
        } else {
            _token1.safeTransferFrom(msg.sender, address(this), grossConsumed);
            _token0.safeTransfer(to, state.amountOutAccum);
        }

        emit Swap(
            msg.sender,
            zeroForOne ? grossConsumed : 0,
            zeroForOne ? 0 : grossConsumed,
            zeroForOne ? 0 : state.amountOutAccum,
            zeroForOne ? state.amountOutAccum : 0,
            state.sqrtPrice,
            state.tick
        );
        return state.amountOutAccum;
    }

    // ── liquidity <-> amounts (v3 SqrtPriceMath / periphery LiquidityAmounts) ─

    /// @inheritdoc IConcentratedLiquidityLab
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96_,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity_
    ) public pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtPriceX96_ <= sqrtRatioAX96) {
            // Price below the range: 100% token0.
            amount0 = _getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity_);
        } else if (sqrtPriceX96_ < sqrtRatioBX96) {
            // Price inside the range: a slice of each token.
            amount0 = _getAmount0ForLiquidity(sqrtPriceX96_, sqrtRatioBX96, liquidity_);
            amount1 = _getAmount1ForLiquidity(sqrtRatioAX96, sqrtPriceX96_, liquidity_);
        } else {
            // Price above the range: 100% token1.
            amount1 = _getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity_);
        }
    }

    /// @inheritdoc IConcentratedLiquidityLab
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96_,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) public pure returns (uint128 liquidity_) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtPriceX96_ <= sqrtRatioAX96) {
            liquidity_ = _getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtPriceX96_ < sqrtRatioBX96) {
            uint128 liquidity0 = _getLiquidityForAmount0(sqrtPriceX96_, sqrtRatioBX96, amount0);
            uint128 liquidity1 = _getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96_, amount1);
            liquidity_ = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity_ = _getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    /// @inheritdoc IConcentratedLiquidityLab
    function getFeeGrowthInside(int24 tickLower, int24 tickUpper, int24 tickCurrent)
        external
        view
        returns (uint256 feeGrowthInside0, uint256 feeGrowthInside1)
    {
        return _getFeeGrowthInside(tickLower, tickUpper, tickCurrent, feeGrowthGlobal0, feeGrowthGlobal1);
    }

    /// @inheritdoc IConcentratedLiquidityLab
    function getPosition(address owner, int24 tickLower, int24 tickUpper)
        external
        view
        returns (
            uint128 positionLiquidity,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        )
    {
        PositionInfo storage p = _positions[_positionKey(owner, tickLower, tickUpper)];
        return (p.liquidity, p.feeGrowthInside0Last, p.feeGrowthInside1Last, p.tokensOwed0, p.tokensOwed1);
    }

    /// @inheritdoc IConcentratedLiquidityLab
    function getTickInfo(int24 t)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0,
            uint256 feeGrowthOutside1,
            bool initialized
        )
    {
        TickInfo storage info = _tickInfo[t];
        return (info.liquidityGross, info.liquidityNet, info.feeGrowthOutside0, info.feeGrowthOutside1, info.initialized);
    }

    // ── position / tick plumbing ─────────────────────────────────────────────

    /// @dev v3 Position.get: positions keyed by (owner, lower, upper).
    function _positionKey(address owner, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    /// @dev v3 _updatePosition + _modifyPosition: update the tick table, accrue
    ///      owed fees from the inside/outside decomposition, and adjust the
    ///      pool's active liquidity if the current tick is inside the range.
    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta) internal {
        PositionInfo storage position = _positions[_positionKey(owner, tickLower, tickUpper)];

        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            flippedLower = _updateTick(tickLower, liquidityDelta, false);
            flippedUpper = _updateTick(tickUpper, liquidityDelta, true);
            if (flippedLower) _flipTick(tickLower);
            if (flippedUpper) _flipTick(tickUpper);
        }

        (uint256 inside0, uint256 inside1) = _getFeeGrowthInside(tickLower, tickUpper, tick, feeGrowthGlobal0, feeGrowthGlobal1);

        // Position.update: accrue liquidity · (inside − insideLast) to owed fees.
        uint128 tokensOwed0 = uint128(Math.mulDiv(inside0 - position.feeGrowthInside0Last, position.liquidity, Q128));
        uint128 tokensOwed1 = uint128(Math.mulDiv(inside1 - position.feeGrowthInside1Last, position.liquidity, Q128));
        position.feeGrowthInside0Last = inside0;
        position.feeGrowthInside1Last = inside1;
        if (tokensOwed0 > 0) position.tokensOwed0 += tokensOwed0;
        if (tokensOwed1 > 0) position.tokensOwed1 += tokensOwed1;

        if (liquidityDelta != 0) {
            position.liquidity = uint128(int128(int256(uint256(position.liquidity)) + liquidityDelta));
            // _modifyPosition: active liquidity changes only when the price is
            // currently inside the range [lower, upper).
            if (tick >= tickLower && tick < tickUpper) {
                liquidity = uint128(int128(int256(uint256(liquidity)) + liquidityDelta));
            }
        }
    }

    /// @dev v3 Tick.update: set liquidityNet/Gross, and on first initialization
    ///      assume all prior growth was BELOW the tick if it is at-or-below the
    ///      current tick.
    function _updateTick(int24 t, int128 liquidityDelta, bool upper) internal returns (bool flipped) {
        TickInfo storage info = _tickInfo[t];
        uint128 grossBefore = info.liquidityGross;
        uint128 grossAfter = uint128(int128(int256(uint256(grossBefore)) + liquidityDelta));
        flipped = (grossAfter == 0) != (grossBefore == 0);
        if (grossBefore == 0) {
            if (t <= tick) {
                info.feeGrowthOutside0 = feeGrowthGlobal0;
                info.feeGrowthOutside1 = feeGrowthGlobal1;
            }
            info.initialized = true;
        }
        info.liquidityGross = grossAfter;
        // Crossing left-to-right: lower ticks add, upper ticks remove liquidity.
        info.liquidityNet = upper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;
    }

    /// @dev v3 Tick.cross: flip the outside accumulators and return liquidityNet.
    function _crossTick(int24 t) internal returns (int128 liquidityNet) {
        TickInfo storage info = _tickInfo[t];
        info.feeGrowthOutside0 = feeGrowthGlobal0 - info.feeGrowthOutside0;
        info.feeGrowthOutside1 = feeGrowthGlobal1 - info.feeGrowthOutside1;
        liquidityNet = info.liquidityNet;
    }

    /// @dev v3 TickBitmap.position: word = tick >> 8, bit = tick mod 256 (with
    ///      negative ticks mapping into [0, 256) via two's complement).
    function _position(int24 t) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(t >> 8);
        bitPos = uint8(uint256(int256(t % 256)));
    }

    function _flipTick(int24 t) internal {
        (int16 wordPos, uint8 bitPos) = _position(t);
        _tickBitmap[wordPos] ^= uint256(1) << bitPos;
    }

    /// @dev v3 TickBitmap.nextInitializedTickWithinOneWord, tickSpacing = 1.
    function _nextInitializedTickWithinOneWord(int24 t, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        if (lte) {
            (int16 wordPos, uint8 bitPos) = _position(t);
            uint256 mask = (uint256(1) << bitPos) - 1 + (uint256(1) << bitPos);
            uint256 masked = _tickBitmap[wordPos] & mask;
            initialized = masked != 0;
            next = initialized
                ? t - int24(int256(uint256(bitPos - _mostSignificantBit(masked))))
                : t - int24(int256(uint256(bitPos)));
        } else {
            (int16 wordPos, uint8 bitPos) = _position(t + 1);
            uint256 mask = ~((uint256(1) << bitPos) - 1);
            uint256 masked = _tickBitmap[wordPos] & mask;
            initialized = masked != 0;
            next = initialized
                ? t + 1 + int24(int256(uint256(_leastSignificantBit(masked) - bitPos)))
                : t + 1 + int24(int256(uint256(type(uint8).max - bitPos)));
        }
    }

    /// @dev BitMath.mostSignificantBit.
    function _mostSignificantBit(uint256 x) internal pure returns (uint8 msb) {
        if (x >= 1 << 128) {
            x >>= 128;
            msb += 128;
        }
        if (x >= 1 << 64) {
            x >>= 64;
            msb += 64;
        }
        if (x >= 1 << 32) {
            x >>= 32;
            msb += 32;
        }
        if (x >= 1 << 16) {
            x >>= 16;
            msb += 16;
        }
        if (x >= 1 << 8) {
            x >>= 8;
            msb += 8;
        }
        if (x >= 1 << 4) {
            x >>= 4;
            msb += 4;
        }
        if (x >= 1 << 2) {
            x >>= 2;
            msb += 2;
        }
        if (x >= 1 << 1) {
            msb += 1;
        }
    }

    /// @dev BitMath.leastSignificantBit.
    function _leastSignificantBit(uint256 x) internal pure returns (uint8 lsb) {
        if (x & type(uint128).max == 0) {
            x >>= 128;
            lsb += 128;
        }
        if (x & type(uint64).max == 0) {
            x >>= 64;
            lsb += 64;
        }
        if (x & type(uint32).max == 0) {
            x >>= 32;
            lsb += 32;
        }
        if (x & type(uint16).max == 0) {
            x >>= 16;
            lsb += 16;
        }
        if (x & type(uint8).max == 0) {
            x >>= 8;
            lsb += 8;
        }
        if (x & 0xF == 0) {
            x >>= 4;
            lsb += 4;
        }
        if (x & 0x3 == 0) {
            x >>= 2;
            lsb += 2;
        }
        if (x & 0x1 == 0) {
            lsb += 1;
        }
    }

    // ── SqrtPriceMath / LiquidityAmounts ports ───────────────────────────────

    /// @dev v3 LiquidityAmounts.getAmount0ForLiquidity:
    ///      amount0 = L·2^96·(sqrtB − sqrtA)/(sqrtA·sqrtB).
    function _getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity_)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return Math.mulDiv(uint256(liquidity_) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @dev v3 LiquidityAmounts.getAmount1ForLiquidity:
    ///      amount1 = L·(sqrtB − sqrtA)/2^96.
    function _getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity_)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return Math.mulDiv(liquidity_, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    /// @dev v3 LiquidityAmounts.getLiquidityForAmount0:
    ///      L = amount0·(sqrtA·sqrtB/2^96)/(sqrtB − sqrtA).
    function _getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity_)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = Math.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return uint128(Math.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @dev v3 LiquidityAmounts.getLiquidityForAmount1:
    ///      L = amount1·2^96/(sqrtB − sqrtA).
    function _getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity_)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return uint128(Math.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @dev v3 SwapMath.computeSwapStep (exact-input only): the price moved by
    ///      the remaining gross input within one tick range, and the step's net
    ///      input / output / fee. Full step: the price reaches the target tick;
    ///      the fee is the fee-inclusive gross of the net input. Partial step:
    ///      the input exhausts inside the range; the fee is the gross minus the
    ///      net consumed (v3's "take the remainder as fee").
    function _computeSwapStep(
        uint160 sqrtPriceCurrent,
        uint160 sqrtPriceTarget,
        uint128 liquidity_,
        uint256 grossRemaining,
        bool zeroForOne
    ) internal view returns (StepComputation memory step) {
        uint256 amountRemainingLessFee = Math.mulDiv(grossRemaining, 1e6 - fee, 1e6);
        step.amountIn = zeroForOne
            ? _getAmount0Delta(sqrtPriceCurrent, sqrtPriceTarget, liquidity_, true)
            : _getAmount1Delta(sqrtPriceCurrent, sqrtPriceTarget, liquidity_, true);

        if (amountRemainingLessFee >= step.amountIn) {
            step.sqrtPriceNext = sqrtPriceTarget;
            step.feeAmount = Math.mulDiv(step.amountIn, fee, 1e6 - fee, Math.Rounding.Ceil);
        } else {
            step.sqrtPriceNext = _getNextSqrtPriceFromInput(sqrtPriceCurrent, liquidity_, amountRemainingLessFee, zeroForOne);
            step.amountIn = zeroForOne
                ? _getAmount0Delta(step.sqrtPriceNext, sqrtPriceCurrent, liquidity_, true)
                : _getAmount1Delta(sqrtPriceCurrent, step.sqrtPriceNext, liquidity_, true);
            step.feeAmount = grossRemaining - amountRemainingLessFee;
        }

        step.amountOut = zeroForOne
            ? _getAmount1Delta(step.sqrtPriceNext, sqrtPriceCurrent, liquidity_, false)
            : _getAmount0Delta(step.sqrtPriceNext, sqrtPriceCurrent, liquidity_, false);
    }

    /// @dev v3 SqrtPriceMath.getAmount0Delta with explicit rounding direction.
    function _getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity_, bool roundUp)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 numerator1 = uint256(liquidity_) << 96;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;
        return roundUp
            ? _divRoundingUp(Math.mulDiv(numerator1, numerator2, sqrtRatioBX96, Math.Rounding.Ceil), sqrtRatioAX96)
            : Math.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @dev v3 SqrtPriceMath.getAmount1Delta with explicit rounding direction.
    function _getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity_, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return roundUp
            ? Math.mulDiv(liquidity_, sqrtRatioBX96 - sqrtRatioAX96, Q96, Math.Rounding.Ceil)
            : Math.mulDiv(liquidity_, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    /// @dev v3 SqrtPriceMath.getNextSqrtPriceFromInput.
    function _getNextSqrtPriceFromInput(uint160 sqrtPX96, uint128 liquidity_, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160)
    {
        return zeroForOne
            ? _getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity_, amountIn, true)
            : _getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity_, amountIn, true);
    }

    /// @dev v3 SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp.
    function _getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity_, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity_) << 96;
        if (add) {
            uint256 product = amount * sqrtPX96;
            if (product / amount == sqrtPX96) {
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1) {
                    return uint160(Math.mulDiv(numerator1, sqrtPX96, denominator, Math.Rounding.Ceil));
                }
            }
            return uint160(_divRoundingUp(numerator1, (numerator1 / sqrtPX96) + amount));
        } else {
            uint256 product = amount * sqrtPX96;
            if (product / amount == sqrtPX96 && numerator1 > product) {
                uint256 denominator = numerator1 - product;
                return uint160(Math.mulDiv(numerator1, sqrtPX96, denominator, Math.Rounding.Ceil));
            }
            revert NoLiquidity();
        }
    }

    /// @dev v3 SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown.
    function _getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity_, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (add) {
            uint256 quotient = Math.mulDiv(amount, Q96, liquidity_);
            return uint160(uint256(sqrtPX96) + quotient);
        } else {
            uint256 quotient = Math.mulDiv(amount, Q96, liquidity_, Math.Rounding.Ceil);
            if (sqrtPX96 <= quotient) revert NoLiquidity();
            return uint160(uint256(sqrtPX96) - quotient);
        }
    }

    // ── fee-growth inside (v3 Tick.getFeeGrowthInside) ───────────────────────

    /// @dev Decompose feeGrowthGlobal into below/above/inside for [tickLower,
    ///      tickUpper): the outside accumulators store "all growth on the far
    ///      side of the tick" relative to the current tick, so the inside slice
    ///      is global − below − above.
    function _getFeeGrowthInside(int24 tickLower, int24 tickUpper, int24 tickCurrent, uint256 fg0, uint256 fg1)
        internal
        view
        returns (uint256 inside0, uint256 inside1)
    {
        TickInfo storage lower = _tickInfo[tickLower];
        TickInfo storage upper = _tickInfo[tickUpper];

        uint256 below0 = tickCurrent >= tickLower ? lower.feeGrowthOutside0 : fg0 - lower.feeGrowthOutside0;
        uint256 below1 = tickCurrent >= tickLower ? lower.feeGrowthOutside1 : fg1 - lower.feeGrowthOutside1;
        uint256 above0 = tickCurrent < tickUpper ? upper.feeGrowthOutside0 : fg0 - upper.feeGrowthOutside0;
        uint256 above1 = tickCurrent < tickUpper ? upper.feeGrowthOutside1 : fg1 - upper.feeGrowthOutside1;

        return (fg0 - below0 - above0, fg1 - below1 - above1);
    }

    function _divRoundingUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
