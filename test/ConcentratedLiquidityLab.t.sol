// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MiniToken} from "../src/MiniToken.sol";
import {TickMathLab} from "../src/TickMathLab.sol";
import {IConcentratedLiquidityLab} from "../src/IConcentratedLiquidityLab.sol";
import {ConcentratedLiquidityLab} from "../src/ConcentratedLiquidityLab.sol";

/// @notice Ch 19 concentrated-liquidity tests — the amount formulas
///         (piecewise by price: below/inside/above a range), the pool's
///         mint/swap/burn lifecycle over tick ranges, the fee-growth
///         accounting (global/outside/inside decomposition), and gas probes.
/// @dev Methodology per locked conventions: `bound` over `vm.assume`;
///      parameter-exact vm.expectRevert; warm-up calls before gasleft() deltas;
///      gas probes log-only. Seed price is 2,000 (tick ≈ 76,010); token0 is the
///      "ETH-like" side, token1 the "USDC-like" side. Fee pools use fee = 3000
///      (0.3%); a fee = 0 pool isolates the pure swap math.
contract ConcentratedLiquidityLabTest is Test {
    using Math for uint256;

    uint256 internal constant Q96 = 79228162514264337593543950336; // 2^96
    uint256 internal constant Q128 = 340282366920938463463374607431768211456; // 2^128

    /// @dev Seed price 2,000 → sqrtPriceX96 = floor(sqrt(2000)·2^96) =
    ///      3,543,191,142,285,914,205,922,034,323,214.
    uint160 internal constant SEED_SQRT_PRICE = uint160(3543191142285914205922034323214);

    // Ranges around tick 76,010. ±110 ticks ≈ ±1.1% in price.
    int24 internal constant LOWER = 75_900;
    int24 internal constant UPPER = 76_120;
    // A range strictly above the current price (~2,214–2,459).
    int24 internal constant ABOVE_LOWER = 77_000;
    int24 internal constant ABOVE_UPPER = 78_000;
    // A range strictly below the current price (~1,637–1,808).
    int24 internal constant BELOW_LOWER = 74_000;
    int24 internal constant BELOW_UPPER = 75_000;

    MiniToken internal tokenA;
    MiniToken internal tokenB;
    ConcentratedLiquidityLab internal pool;
    ConcentratedLiquidityLab internal pool0; // zero-fee twin

    address internal alice;

    function setUp() public {
        tokenA = new MiniToken();
        tokenB = new MiniToken();
        pool = new ConcentratedLiquidityLab(IERC20(address(tokenA)), IERC20(address(tokenB)), 3000);
        pool0 = new ConcentratedLiquidityLab(IERC20(address(tokenA)), IERC20(address(tokenB)), 0);
        alice = makeAddr("alice");

        tokenA.mint(address(this), 1e36);
        tokenB.mint(address(this), 1e36);
        tokenA.mint(alice, 1e36);
        tokenB.mint(alice, 1e36);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        tokenA.approve(address(pool0), type(uint256).max);
        tokenB.approve(address(pool0), type(uint256).max);

        pool.initialize(SEED_SQRT_PRICE);
        pool0.initialize(SEED_SQRT_PRICE);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _seedPosition(
        IConcentratedLiquidityLab p,
        uint128 liquiditySeed,
        int24 lower,
        int24 upper
    ) internal returns (uint128 liquidity) {
        uint160 sqrtP = p.sqrtPriceX96();
        (uint256 a0, uint256 a1) = p.getAmountsForLiquidity(
            sqrtP,
            TickMathLab.getSqrtRatioAtTick(lower),
            TickMathLab.getSqrtRatioAtTick(upper),
            liquiditySeed
        );
        liquidity = p.mint(lower, upper, a0, a1);
    }

    // ── amount formulas: piecewise by price ─────────────────────────────────

    /// @dev Price below the range → the position is 100% token0; token1 = 0.
    function test_amounts_belowRange_isAllToken0() public pure {
        uint160 p = TickMathLab.getSqrtRatioAtTick(75_800); // < LOWER
        (uint256 a0, uint256 a1) = _amountsFor(p, LOWER, UPPER, 1e18);
        assertGt(a0, 0);
        assertEq(a1, 0);
    }

    /// @dev Price inside the range → a slice of each token.
    function test_amounts_inRange_isBothTokens() public pure {
        uint160 p = TickMathLab.getSqrtRatioAtTick(76_010);
        (uint256 a0, uint256 a1) = _amountsFor(p, LOWER, UPPER, 1e18);
        assertGt(a0, 0);
        assertGt(a1, 0);
    }

    /// @dev Price above the range → the position is 100% token1; token0 = 0.
    function test_amounts_aboveRange_isAllToken1() public pure {
        uint160 p = TickMathLab.getSqrtRatioAtTick(76_130); // > UPPER
        (uint256 a0, uint256 a1) = _amountsFor(p, LOWER, UPPER, 1e18);
        assertEq(a0, 0);
        assertGt(a1, 0);
    }

    /// @dev In-range amounts equal the chapter's derivation
    ///      amount0 = L·2^96·(sqrtHi − sqrtP)/(sqrtP·sqrtHi) and
    ///      amount1 = L·(sqrtP − sqrtLo)/2^96, recomputed independently here.
    function test_amounts_inRange_matchesDerivation() public pure {
        uint160 sqrtLo = TickMathLab.getSqrtRatioAtTick(LOWER);
        uint160 sqrtHi = TickMathLab.getSqrtRatioAtTick(UPPER);
        uint160 sqrtP = TickMathLab.getSqrtRatioAtTick(76_010);
        uint128 L = 1e18;

        uint256 expected0 = Math.mulDiv(uint256(L) << 96, sqrtHi - sqrtP, sqrtHi) / sqrtP;
        uint256 expected1 = Math.mulDiv(L, sqrtP - sqrtLo, Q96);

        (uint256 a0, uint256 a1) = _amountsFor(sqrtP, LOWER, UPPER, L);
        assertEq(a0, expected0);
        assertEq(a1, expected1);
    }

    /// @dev Round-trip monotone: liquidity derived from the amounts for L never
    ///      exceeds L (both directions floor — the conversionsNeverGain shape,
    ///      Ch 12/16 family), and is never zero.
    function testFuzz_amounts_liquidity_neverGains(
        uint128 liquiditySeed,
        uint160 sqrtPrice,
        uint160 sqrtA,
        uint160 sqrtB
    ) public {
        sqrtPrice = uint160(
            bound(
                sqrtPrice,
                uint256(TickMathLab.MIN_SQRT_RATIO) + 1_000,
                uint256(TickMathLab.MAX_SQRT_RATIO) - 1_000
            )
        );
        sqrtA = uint160(bound(sqrtA, TickMathLab.MIN_SQRT_RATIO, uint256(sqrtPrice) - 1));
        sqrtB =
            uint160(bound(sqrtB, uint256(sqrtPrice) + 1, uint256(TickMathLab.MAX_SQRT_RATIO) - 1));
        liquiditySeed = uint128(bound(liquiditySeed, 1e18, 1e22));

        (uint256 a0, uint256 a1) =
            pool0.getAmountsForLiquidity(sqrtPrice, sqrtA, sqrtB, liquiditySeed);
        uint128 recovered = pool0.getLiquidityForAmounts(sqrtPrice, sqrtA, sqrtB, a0, a1);
        assertLe(recovered, liquiditySeed);
    }

    // ── pool lifecycle ──────────────────────────────────────────────────────

    /// @dev Minting an in-range position pulls exactly the amount formula's
    ///      tokens and activates its liquidity.
    function test_pool_mint_inRange_activatesLiquidity() public {
        uint128 L = _seedPosition(pool, 1e20, LOWER, UPPER);
        assertGt(L, 0);
        assertEq(pool.liquidity(), L);
        (uint128 p0, uint256 p1,,,) = pool.getPosition(address(this), LOWER, UPPER);
        assertEq(p0, L);
        assertEq(p1, 0); // no fees yet
    }

    /// @dev Minting an ABOVE-range position holds only token0 and does NOT
    ///      change active liquidity (it joins only when price enters the range).
    function test_pool_mint_aboveRange_holdsOnlyToken0_notActive() public {
        _seedPosition(pool, 1e20, ABOVE_LOWER, ABOVE_UPPER);
        assertEq(pool.liquidity(), 0);
        assertEq(tokenB.balanceOf(address(pool)), 0); // price below range → token0 only
        assertGt(tokenA.balanceOf(address(pool)), 0);
    }

    /// @dev Minting a BELOW-range position holds only token1.
    function test_pool_mint_belowRange_holdsOnlyToken1() public {
        _seedPosition(pool, 1e20, BELOW_LOWER, BELOW_UPPER);
        assertEq(pool.liquidity(), 0);
        assertEq(tokenA.balanceOf(address(pool)), 0); // price above range → token1 only
        assertGt(tokenB.balanceOf(address(pool)), 0);
    }

    /// @dev Burn + collect with no swaps returns the deposited principal
    ///      exactly (same price → same amounts): the balance returns to its
    ///      pre-deposit level.
    function test_pool_burnCollect_noSwaps_returnsPrincipal() public {
        uint256 balA0 = tokenA.balanceOf(address(this));
        uint256 balA1 = tokenB.balanceOf(address(this));
        uint128 L = _seedPosition(pool, 1e20, LOWER, UPPER);
        assertGt(L, 0);
        pool.burn(LOWER, UPPER, L);
        pool.collect(LOWER, UPPER, address(this));
        assertEq(tokenA.balanceOf(address(this)), balA0);
        assertEq(tokenB.balanceOf(address(this)), balA1);
        (uint128 p0,,,,) = pool.getPosition(address(this), LOWER, UPPER);
        assertEq(p0, 0);
    }

    // ── swap math ───────────────────────────────────────────────────────────

    /// @dev A zero-fee swap's output equals L·(sqrtBefore − sqrtAfter)/Q96:
    ///      within one tick range the curve is the v2 constant-product curve
    ///      with the range's L as the reserve scale.
    function test_swap_zeroFee_outputMatchesLiquidityMath() public {
        _seedPosition(pool0, 1e20, LOWER, UPPER);
        uint160 before = pool0.sqrtPriceX96();
        uint256 out = pool0.swap(1e16, true, 0, address(this));
        uint160 afterPrice = pool0.sqrtPriceX96();
        uint256 expected = Math.mulDiv(uint256(pool0.liquidity()), before - afterPrice, Q96);
        assertEq(out, expected);
        assertLt(afterPrice, before); // price fell
        assertGt(pool0.liquidity(), 0);
    }

    /// @dev The fee is taken on the input: with fee 0.3%, the price moves less
    ///      and the output is smaller than in the fee-free pool.
    function test_swap_fee_takenOnInput() public {
        _seedPosition(pool, 1e20, LOWER, UPPER);
        _seedPosition(pool0, 1e20, LOWER, UPPER);
        uint256 outFee = pool.swap(1e16, true, 0, address(this));
        uint256 outFree = pool0.swap(1e16, true, 0, address(this));
        assertLt(outFee, outFree);
        // The fee pool kept 0.3% out of the price math → higher resulting price.
        assertGt(pool.sqrtPriceX96(), pool0.sqrtPriceX96());
    }

    /// @dev A large swap crosses the range boundary: the position exits and
    ///      active liquidity drops to zero (the price left every range).
    function test_swap_crossesTick_liquidityChanges() public {
        _seedPosition(pool0, 1e20, LOWER, UPPER);
        (uint128 posLiquidity,,,,) = pool0.getPosition(address(this), LOWER, UPPER);
        assertEq(pool0.liquidity(), posLiquidity);
        pool0.swap(5e18, true, 0, address(this)); // ~4,000× the range's token0 depth
        assertLt(pool0.tick(), LOWER);
        assertEq(pool0.liquidity(), 0);
        assertEq(pool0.sqrtPriceX96(), TickMathLab.getSqrtRatioAtTick(LOWER));
    }

    /// @dev A swap whose output is below the trader's minimum reverts with the
    ///      parameter-exact guard. Expected out is computed independently from
    ///      the next-price formula (no overflow for these magnitudes).
    function test_pool_reverts_slippage() public {
        _seedPosition(pool0, 1e20, LOWER, UPPER);
        uint160 before = pool0.sqrtPriceX96();
        uint256 amountIn = 1e16;
        uint256 numerator1 = uint256(pool0.liquidity()) << 96;
        uint256 product = amountIn * before;
        uint160 afterPrice =
            uint160(Math.mulDiv(numerator1, before, numerator1 + product, Math.Rounding.Ceil));
        uint256 expectedOut = Math.mulDiv(pool0.liquidity(), before - afterPrice, Q96);

        vm.expectRevert(
            abi.encodeWithSelector(
                IConcentratedLiquidityLab.SlippageExceeded.selector, expectedOut + 1, expectedOut
            )
        );
        pool0.swap(amountIn, true, expectedOut + 1, address(this));
    }

    // ── fee-growth accounting ───────────────────────────────────────────────

    /// @dev In-range positions earn fees exactly equal to L · feeGrowthInside /
    ///      2^128 (the Ch 19 position-accounting identity). The swap does not
    ///      touch positions; the accrual happens on the next position update
    ///      (the "poke" mint).
    function test_fees_owedMatchesLiquidityTimesFeeGrowth() public {
        uint128 L = _seedPosition(pool, 1e20, LOWER, UPPER);
        pool.swap(1e16, true, 0, address(this)); // fees accrue in token0
        (uint256 inside0,) = pool.getFeeGrowthInside(LOWER, UPPER, pool.tick());
        assertGt(inside0, 0);

        pool.mint(LOWER, UPPER, 1e6, 1e6); // poke: accrues the position's fees
        (,,, uint256 owed0,) = pool.getPosition(address(this), LOWER, UPPER);
        uint256 expected = Math.mulDiv(uint256(L), inside0, Q128);
        assertEq(owed0, expected);
        assertGt(owed0, 0);
    }

    /// @dev Two owners in the same range earn fees in exact proportion to their
    ///      liquidity (same feeGrowthInside, owed ∝ L).
    function test_fees_twoOwners_proportionalToLiquidity() public {
        _seedPosition(pool, 1e20, LOWER, UPPER);
        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        _seedPosition(pool, 2e20, LOWER, UPPER);
        vm.stopPrank();

        pool.swap(1e16, true, 0, address(this));

        pool.mint(LOWER, UPPER, 1e6, 1e6); // poke test contract
        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.mint(LOWER, UPPER, 1e6, 1e6); // poke alice
        vm.stopPrank();

        (,,, uint256 mine,) = pool.getPosition(address(this), LOWER, UPPER);
        (,,, uint256 theirs,) = pool.getPosition(alice, LOWER, UPPER);
        assertGt(mine, 0);
        // 2× liquidity → 2× fees, within 2 wei (independent flooring on the two
        // liquidity seeds and the per-owner fee accrual).
        assertLe(theirs > 2 * mine ? theirs - 2 * mine : 2 * mine - theirs, 2);
    }

    /// @dev A position whose range the price never entered earns zero fees.
    function test_fees_outOfRange_earnsNothing() public {
        _seedPosition(pool, 1e20, LOWER, UPPER); // in-range
        _seedPosition(pool, 1e20, ABOVE_LOWER, ABOVE_UPPER); // above range
        pool.swap(1e16, true, 0, address(this));
        uint256 b0 = tokenA.balanceOf(address(this));
        uint256 b1 = tokenB.balanceOf(address(this));
        pool.collect(ABOVE_LOWER, ABOVE_UPPER, address(this));
        assertEq(tokenA.balanceOf(address(this)) - b0, 0);
        assertEq(tokenB.balanceOf(address(this)) - b1, 0);
    }

    // ── swap round trip (zero fee) ──────────────────────────────────────────

    /// @dev Zero-fee swap in, then swap the output back: the price returns to
    ///      near the start. The residual drift is pure rounding and scales with
    ///      Q96/liquidity per output wei, so the honest bound is RELATIVE to the
    ///      size of the move (here: < 0.1% of the move).
    function testFuzz_swap_zeroFee_roundTrip(uint128 liquiditySeed, uint256 amountIn) public {
        liquiditySeed = uint128(bound(liquiditySeed, 1e19, 1e22));
        // 1e6 floor keeps the output measurable across the liquidity range (a
        // 1-wei input is swallowed by the price rounding and outputs 0 wei).
        amountIn = bound(amountIn, 1e6, 1e16);
        _seedPosition(pool0, liquiditySeed, 75_000, 77_000); // wide enough for the move
        uint160 start = pool0.sqrtPriceX96();
        uint256 out = pool0.swap(amountIn, true, 0, address(this));
        assertGt(out, 0);
        uint160 mid = pool0.sqrtPriceX96();
        assertLt(mid, start);
        uint256 back = pool0.swap(out, false, 0, address(this));
        assertGt(back, 0);
        uint160 end = pool0.sqrtPriceX96();
        uint256 move = start - mid;
        uint256 drift = end >= start ? end - start : start - end;
        assertLt(drift, move / 1_000); // rounding-only residual, no fee drift
    }

    // ── revert surface ──────────────────────────────────────────────────────

    function test_pool_reverts_invalidRange() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IConcentratedLiquidityLab.InvalidTickRange.selector, UPPER, LOWER
            )
        );
        pool.mint(UPPER, LOWER, 1e18, 1e18);
    }

    function test_pool_reverts_zeroAmounts() public {
        vm.expectRevert(IConcentratedLiquidityLab.ZeroAmount.selector);
        pool.mint(LOWER, UPPER, 0, 0);
    }

    function test_pool_reverts_zeroSwapInput() public {
        vm.expectRevert(IConcentratedLiquidityLab.ZeroAmount.selector);
        pool.swap(0, true, 0, address(this));
    }

    function test_pool_reverts_swapNoLiquidity() public {
        vm.expectRevert(IConcentratedLiquidityLab.NoLiquidity.selector);
        pool.swap(1e18, true, 0, address(this));
    }

    function test_pool_reverts_burnMoreThanHeld() public {
        _seedPosition(pool, 1e20, LOWER, UPPER);
        vm.prank(alice); // alice holds no position
        vm.expectRevert(
            abi.encodeWithSelector(IConcentratedLiquidityLab.InsufficientLiquidity.selector, 0, 1)
        );
        pool.burn(LOWER, UPPER, 1);
    }

    // ── gas probes (log-only, warm-up first) ─────────────────────────────────

    function test_gas_swap() public {
        _seedPosition(pool, 1e20, LOWER, UPPER);
        pool.swap(1e15, true, 0, address(this)); // warm-up
        uint256 best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 10; ++i) {
                pool.swap(1e13, true, 0, address(this));
            }
            uint256 avg = (start - gasleft()) / 10;
            if (avg < best) best = avg;
        }
        console2.log("swap gas (10x loop, warm, min-of-3):", best);
    }

    function test_gas_mint() public {
        _seedPosition(pool, 1e20, LOWER, UPPER); // warm-up
        uint256 start = gasleft();
        for (uint256 i; i < 5; ++i) {
            _seedPosition(pool, 1e18, LOWER, UPPER);
        }
        console2.log("mint gas (5x loop, warm):", (start - gasleft()) / 5);
    }

    // ── pure helper mirroring getAmountsForLiquidity for the piecewise tests ──

    function _amountsFor(uint160 p, int24 lower, int24 upper, uint128 L)
        internal
        pure
        returns (uint256 a0, uint256 a1)
    {
        return _amountsFor(
            p, TickMathLab.getSqrtRatioAtTick(lower), TickMathLab.getSqrtRatioAtTick(upper), L
        );
    }

    function _amountsFor(uint160 p, uint160 sqrtLo, uint160 sqrtHi, uint128 L)
        internal
        pure
        returns (uint256 a0, uint256 a1)
    {
        if (p <= sqrtLo) {
            a0 = Math.mulDiv(uint256(L) << 96, sqrtHi - sqrtLo, sqrtHi) / sqrtLo;
        } else if (p < sqrtHi) {
            a0 = Math.mulDiv(uint256(L) << 96, sqrtHi - p, sqrtHi) / p;
            a1 = Math.mulDiv(L, p - sqrtLo, Q96);
        } else {
            a1 = Math.mulDiv(L, sqrtHi - sqrtLo, Q96);
        }
    }
}
