// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MiniToken} from "../src/MiniToken.sol";
import {IConstantProductPoolLab} from "../src/IConstantProductPoolLab.sol";
import {ConstantProductPool, CeilOutPool} from "../src/ConstantProductPoolLab.sol";

/// @notice Ch 18 lab tests — constant-product math: the swap equation solved
///         from x·y=k, fee-on-input invariant drift, slippage/price-impact
///         probes, minimum-liquidity dead shares, LP-share ratio math, and the
///         rounding-DIRECTION flaw class (safe floor-out vs unsafe ceil-out).
/// @dev Methodology per locked conventions: parameter-exact vm.expectRevert
///      (abi.encodeWithSelector for parameterized errors); non-privileged
///      negative test for the owner-gated fee key; `bound` over vm.assume;
///      warm-up calls before gasleft() deltas; gas probes log-only (no
///      assertions in fuzz/invariant code). The seed pool is 100e18 / 200_000e18
///      (token0/token1 by constructor order — lab convention; the real V2
///      factory sorts by address). All pin values are computed in the test
///      derivation or hardcoded from the same arithmetic.
contract ConstantProductPoolLabTest is Test {
    using Math for uint256;

    MiniToken internal tokenA;
    MiniToken internal tokenB;
    ConstantProductPool internal safePool;
    CeilOutPool internal ceilPool;

    address internal alice;
    address internal bob;

    uint256 internal constant SEED0 = 100e18; // 100 ETH-ish
    uint256 internal constant SEED1 = 200_000e18; // 200,000 USDC-ish

    // Pinned from the derivation out = floor(y·in·997/(x·1000 + in·997)) at
    // x=100e18, y=200_000e18, in=1e18 (verified against Math.mulDiv in-test).
    uint256 internal constant PINNED_WITH_FEE_OUT = 1_974_316_068_794_122_597_700;
    uint256 internal constant PINNED_NO_FEE_OUT = 1_980_198_019_801_980_198_019;
    uint256 internal constant PINNED_SPOT = 2_000_000_000_000_000_000_000;

    function setUp() public {
        tokenA = new MiniToken();
        tokenB = new MiniToken();
        // Constructor order fixes token0/token1 (lab convention).
        safePool = new ConstantProductPool(IERC20(address(tokenA)), IERC20(address(tokenB)));
        ceilPool = new CeilOutPool(IERC20(address(tokenA)), IERC20(address(tokenB)));
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        tokenA.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);
        tokenA.approve(address(safePool), type(uint256).max);
        tokenB.approve(address(safePool), type(uint256).max);
        tokenA.approve(address(ceilPool), type(uint256).max);
        tokenB.approve(address(ceilPool), type(uint256).max);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _seed(IConstantProductPoolLab pool, uint256 a0, uint256 a1)
        internal
        returns (uint256 liquidity)
    {
        liquidity = pool.addLiquidity(a0, a1);
    }

    /// @dev The recorded invariant k = reserve0 · reserve1 (post-fee state).
    function _k(IConstantProductPoolLab pool) internal view returns (uint256) {
        (uint256 r0, uint256 r1) = pool.getReserves();
        return r0 * r1;
    }

    // ── swap math correctness ───────────────────────────────────────────────

    /// @dev getAmountOut equals the invariant solved algebraically:
    ///      out = floor(y·in·997/(x·1000 + in·997)) — the single-floor form of
    ///      out = y − k/(x + in·(1−f)). This IS the Uniswap V2 formula.
    function test_swapMath_getAmountOut_matchesInvariantDerivation() public {
        _seed(safePool, SEED0, SEED1);
        (uint256 x, uint256 y) = safePool.getReserves();
        uint256 amountIn = 1e18;
        uint256 amountInWithFee = amountIn * 997; // in·(1−f), f = 3/1000
        uint256 expected = Math.mulDiv(y, amountInWithFee, x * 1000 + amountInWithFee);
        assertEq(safePool.getAmountOut(amountIn, true), expected);
    }

    /// @dev Pinned concrete number: 1 ETH into a 100 ETH / 200,000 USDC pool
    ///      with the 0.3% fee pays 1,974.3160687941225977 USDC.
    function test_swapMath_pinnedExample_1EthInto100EthPool() public {
        _seed(safePool, SEED0, SEED1);
        assertEq(safePool.getAmountOut(1e18, true), PINNED_WITH_FEE_OUT);
    }

    /// @dev A live swap moves reserves exactly as the formula says and pays out
    ///      the full computed amount (no silent dust on the trader's side).
    function test_swap_executesAndUpdatesReserves() public {
        _seed(safePool, SEED0, SEED1);
        uint256 out = safePool.getAmountOut(1e18, true);
        uint256 traderB = tokenB.balanceOf(address(this));
        safePool.swap(1e18, 0, true, address(this));
        (uint256 r0, uint256 r1) = safePool.getReserves();
        assertEq(r0, SEED0 + 1e18);
        assertEq(r1, SEED1 - out);
        assertEq(tokenB.balanceOf(address(this)), traderB + out);
    }

    // ── invariant preservation with fee ─────────────────────────────────────

    /// @dev The with-fee invariant drifts UP: the pool records the FULL `in` as
    ///      reserve growth while the formula only consumed in·997/1000, so the
    ///      fee (3/1000 of in) accumulates into k. Strict increase, pinned.
    function test_invariant_withFee_driftsUp() public {
        _seed(safePool, SEED0, SEED1);
        uint256 k0 = _k(safePool);
        safePool.swap(1e18, 0, true, address(this));
        assertGt(_k(safePool), k0);
    }

    /// @dev Fuzz: for any swap bounded to ≤1% of the pool, k' ≥ k (strictly >
    ///      with the 0.3% fee). Each fuzz iteration seeds a fresh pool.
    function testFuzz_swap_withFee_invariantNonDecreasing(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1e18);
        _seed(safePool, SEED0, SEED1);
        uint256 k0 = _k(safePool);
        safePool.swap(amountIn, 0, true, address(this));
        assertGe(_k(safePool), k0);
    }

    // ── price impact / slippage ─────────────────────────────────────────────

    function test_spotPrice_matchesReserveRatio() public {
        _seed(safePool, SEED0, SEED1);
        assertEq(safePool.spotPrice(), PINNED_SPOT);
    }

    /// @dev Execution price (out/in) sits BELOW spot (reserve ratio): the
    ///      marginal price rises as the swap pushes reserves, so the average
    ///      price over the swap is below the pre-swap spot.
    function test_priceImpact_executionPriceBelowSpot() public {
        _seed(safePool, SEED0, SEED1);
        uint256 execPrice = safePool.getAmountOut(1e18, true); // per 1e18 in
        assertLt(execPrice, safePool.spotPrice());
    }

    /// @dev Slippage grows with size: a 10x swap has strictly worse execution
    ///      price than a 1x swap. Non-linearity is the point of x·y=k.
    function test_priceImpact_increasesWithSize() public {
        _seed(safePool, SEED0, SEED1);
        uint256 outSmall = safePool.getAmountOut(1e18, true);
        uint256 outLarge = safePool.getAmountOut(10e18, true);
        uint256 execSmall = outSmall;
        uint256 execLarge = outLarge * 1e18 / 10e18;
        assertLt(execLarge, execSmall);
        assertLt(execSmall, safePool.spotPrice());
        uint256 slipSmall = (safePool.spotPrice() - execSmall) * 10_000 / safePool.spotPrice();
        uint256 slipLarge = (safePool.spotPrice() - execLarge) * 10_000 / safePool.spotPrice();
        assertGt(slipLarge, slipSmall);
    }

    /// @dev The full slippage on a 1 ETH swap decomposes into price impact plus
    ///      fee: no-fee out 1,980.198 vs with-fee out 1,974.316. Spot 2,000 →
    ///      total 1.28% (impact 0.99% + fee 0.29%). All three bps pinned.
    function test_slippage_numericExample_feePlusImpact() public {
        _seed(safePool, SEED0, SEED1);
        uint256 outWithFee = safePool.getAmountOut(1e18, true);
        safePool.setSwapFee(0); // isolate the impact component
        uint256 outNoFee = safePool.getAmountOut(1e18, true);
        uint256 spot = safePool.spotPrice();

        assertEq(outWithFee, PINNED_WITH_FEE_OUT);
        assertEq(outNoFee, PINNED_NO_FEE_OUT);
        assertEq(spot, PINNED_SPOT);

        uint256 slippageBps = (spot - outWithFee) * 10_000 / spot;
        uint256 impactBps = (spot - outNoFee) * 10_000 / spot;
        uint256 feeBps = (outNoFee - outWithFee) * 10_000 / spot;
        assertEq(slippageBps, 128); // 1.28%
        assertEq(impactBps, 99); // 0.99%
        assertEq(feeBps, 29); // 0.29%
    }

    // ── minimum liquidity (dead shares) ─────────────────────────────────────

    /// @dev First mint: liquidity = sqrt(x·y) − MINIMUM_LIQUIDITY, with 1,000
    ///      dead shares burned to address(0). totalSupply == sqrt(x·y).
    function test_minimumLiquidity_firstMint_locksDeadShares() public {
        uint256 liquidity = _seed(safePool, SEED0, SEED1);
        uint256 expectedTotal = Math.sqrt(SEED0 * SEED1); // 4,472,135,954,999,579,392,818
        assertEq(safePool.totalSupply(), expectedTotal);
        assertEq(safePool.balanceOf(address(0)), 1_000);
        assertEq(safePool.balanceOf(address(this)), liquidity);
        assertEq(liquidity, expectedTotal - 1_000);
    }

    /// @dev Even after the LP withdraws everything burnable, totalSupply stays
    ///      at the 1,000 dead shares and the backing value stays locked: the
    ///      pool can never be drained to zero shares (the first-depositor
    ///      inflation defense).
    function test_minimumLiquidity_supplyNeverZero_afterFullWithdrawal() public {
        uint256 liquidity = _seed(safePool, SEED0, SEED1);
        safePool.removeLiquidity(liquidity, address(this));
        assertEq(safePool.totalSupply(), 1_000);
        (uint256 r0, uint256 r1) = safePool.getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    // ── rounding direction (the Balancer V2 flaw class) ─────────────────────

    /// @dev The two twins agree on everything except the ONE rounding line:
    ///      floor-out vs ceil-out on an exact-out that is fractional (the no-fee
    ///      out of 1,980.198... — always fractional because 101 ∤ 200,000·10^18).
    ///      The ceil pays the trader 1 extra wei the pool must fund.
    function test_rounding_safePool_floorsOut_poolKeepsDust() public {
        safePool.setSwapFee(0);
        _seed(safePool, SEED0, SEED1);
        _seed(ceilPool, SEED0, SEED1);
        uint256 floor = safePool.getAmountOut(1e18, true);
        uint256 ceil = ceilPool.getAmountOut(1e18, true);
        assertEq(floor, PINNED_NO_FEE_OUT);
        assertEq(ceil, PINNED_NO_FEE_OUT + 1);
    }

    /// @dev The direction in k: with the fee removed from BOTH pools, one swap
    ///      of 1 ETH leaves the safe pool's k ≥ k0 (the pool keeps the rounding
    ///      edge) and the ceil pool's k < k0 (the trader gained a wei the pool
    ///      paid for). Same trade, opposite invariant outcome.
    function test_rounding_safePool_vs_ceilPool_kDirection() public {
        safePool.setSwapFee(0);
        _seed(safePool, SEED0, SEED1);
        _seed(ceilPool, SEED0, SEED1);
        uint256 kSafe = _k(safePool);
        uint256 kCeil = _k(ceilPool);
        assertEq(kSafe, kCeil);
        safePool.swap(1e18, 0, true, address(this));
        ceilPool.swap(1e18, 0, true, address(this));
        assertGe(_k(safePool), kSafe); // floor: pool favors itself
        assertLt(_k(ceilPool), kCeil); // ceil: trader gained, pool leaked
    }

    /// @dev The leak compounds: after 500 tiny swaps (1e6 wei each), the ceil
    ///      pool's token1 balance is strictly below the safe pool's after the
    ///      identical sequence — rounding-up-out is not a rounding nicety, it
    ///      is a slow drain (the Balancer-style direction, Ch 26).
    function test_rounding_unsafePool_repeatedSwaps_drainValue() public {
        safePool.setSwapFee(0);
        _seed(safePool, SEED0, SEED1);
        _seed(ceilPool, SEED0, SEED1);
        for (uint256 i; i < 500; ++i) {
            safePool.swap(1e6, 0, true, address(this));
            ceilPool.swap(1e6, 0, true, address(this));
        }
        assertLt(tokenB.balanceOf(address(ceilPool)), tokenB.balanceOf(address(safePool)));
    }

    /// @dev Fuzz mirror: the safe pool (fee 0) NEVER loses k (floor ≥ exact),
    ///      while the ceil pool NEVER gains k (ceil ≥ exact) — the two
    ///      directions are strict inequalities in opposite senses.
    function testFuzz_rounding_safePool_noFee_kNonDecreasing(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1e18);
        safePool.setSwapFee(0);
        _seed(safePool, SEED0, SEED1);
        uint256 k0 = _k(safePool);
        safePool.swap(amountIn, 0, true, address(this));
        assertGe(_k(safePool), k0);
    }

    function testFuzz_rounding_ceilPool_noFee_kNonIncreasing(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1e18);
        _seed(ceilPool, SEED0, SEED1);
        uint256 k0 = _k(ceilPool);
        ceilPool.swap(amountIn, 0, true, address(this));
        assertLe(_k(ceilPool), k0);
    }

    // ── LP share math ───────────────────────────────────────────────────────

    /// @dev Proportional second deposit mints min-ratio shares: exactly TS/10
    ///      of the pre-existing supply (floor — the pool keeps the dust).
    function test_addLiquidity_secondDeposit_proportional_minRatio() public {
        _seed(safePool, SEED0, SEED1);
        uint256 total = safePool.totalSupply();
        uint256 liquidity = safePool.addLiquidity(10e18, 20_000e18);
        assertEq(liquidity, total / 10);
    }

    /// @dev Imbalanced deposit: the binding ratio is the SMALLER of the two
    ///      (token1's 2.5%), so the excess token1 stays in the pool as a
    ///      donation that boosts k. The pool keeps its price; the depositor
    ///      just gets fewer shares.
    function test_addLiquidity_imbalanced_excessIsDonation() public {
        _seed(safePool, SEED0, SEED1);
        uint256 total = safePool.totalSupply();
        uint256 liquidity = safePool.addLiquidity(10e18, 5_000e18);
        assertEq(liquidity, total / 40); // 5,000/200,000 = 2.5%, not 10%
        (uint256 r0, uint256 r1) = safePool.getReserves();
        assertEq(r0, 110e18);
        assertEq(r1, 205_000e18); // all 5,000 deposited token1 is counted
    }

    /// @dev removeLiquidity FLOORS both payouts: a proportional round trip of
    ///      10 ETH / 20,000 USDC comes back 1 wei and 33 wei short — the dust
    ///      stays in the pool (pinned exact numbers).
    function test_removeLiquidity_roundsDown_poolKeepsDust() public {
        _seed(safePool, SEED0, SEED1);
        uint256 liquidity = safePool.addLiquidity(10e18, 20_000e18);
        (uint256 a0, uint256 a1) = safePool.removeLiquidity(liquidity, address(this));
        assertEq(a0, 10e18 - 1);
        assertEq(a1, 20_000e18 - 33);
        (uint256 r0, uint256 r1) = safePool.getReserves();
        assertEq(r0, 100e18 + 1); // first LP's backing + the 1 wei dust
        assertEq(r1, 200_000e18 + 33);
    }

    // ── revert surface ──────────────────────────────────────────────────────

    /// @dev Slippage guard: trader asks for 1 more wei than the formula yields
    ///      → parameter-exact SlippageExceeded(min, out).
    function test_swap_reverts_slippageBelowMin() public {
        _seed(safePool, SEED0, SEED1);
        uint256 out = safePool.getAmountOut(1e18, true);
        vm.expectRevert(abi.encodeWithSelector(IConstantProductPoolLab.SlippageExceeded.selector, out + 1, out));
        safePool.swap(1e18, out + 1, true, address(this));
    }

    function test_swap_reverts_zeroInput() public {
        _seed(safePool, SEED0, SEED1);
        vm.expectRevert(IConstantProductPoolLab.ZeroAmount.selector);
        safePool.swap(0, 0, true, address(this));
    }

    function test_addLiquidity_reverts_zeroAmount() public {
        vm.expectRevert(IConstantProductPoolLab.ZeroAmount.selector);
        safePool.addLiquidity(1e18, 0);
    }

    /// @dev A token ratio so small both ratios floor to zero → no shares.
    function test_addLiquidity_reverts_insufficientLiquidity() public {
        _seed(safePool, SEED0, SEED1);
        vm.expectRevert(IConstantProductPoolLab.InsufficientLiquidity.selector);
        safePool.addLiquidity(1, 1);
    }

    function test_removeLiquidity_reverts_insufficientShares() public {
        _seed(safePool, SEED0, SEED1);
        // alice has 0 shares — the test contract seeded the pool, so it holds
        // shares and would NOT revert (the prank makes the negative honest).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IConstantProductPoolLab.InsufficientShares.selector, 0, 1));
        safePool.removeLiquidity(1, address(this));
    }

    // ── privileged surface (swap-fee key) ───────────────────────────────────

    function test_setSwapFee_owner_updatesAndAffectsOut() public {
        _seed(safePool, SEED0, SEED1);
        uint256 outWithFee = safePool.getAmountOut(1e18, true);
        safePool.setSwapFee(0);
        assertEq(safePool.swapFee(), 0);
        assertGt(safePool.getAmountOut(1e18, true), outWithFee);
    }

    /// @dev Non-privileged negative (Ch 10 convention): a non-owner cannot
    ///      touch the fee key — a fee key is an admin key (Kelp DAO/Drift class).
    function test_setSwapFee_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IConstantProductPoolLab.NotAuthorized.selector, alice));
        safePool.setSwapFee(0);
    }

    function test_setSwapFee_outOfBounds_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IConstantProductPoolLab.FeeOutOfBounds.selector, 1_000));
        safePool.setSwapFee(1_000);
    }

    // ── sync / donation ─────────────────────────────────────────────────────

    /// @dev A direct token transfer is invisible to the invariant until sync
    ///      re-reads balances — the donation then drifts k upward. sync is
    ///      permissionless in V2 for exactly this reason.
    function test_sync_absorbsDonation_intoReserves() public {
        _seed(safePool, SEED0, SEED1);
        uint256 k0 = _k(safePool);
        tokenA.transfer(address(safePool), 1e18);
        (uint256 r0,) = safePool.getReserves();
        assertEq(r0, SEED0); // not yet in reserves
        safePool.sync();
        (r0,) = safePool.getReserves();
        assertEq(r0, SEED0 + 1e18);
        assertGt(_k(safePool), k0);
    }

    // ── gas probes (log-only) ───────────────────────────────────────────────

    /// @dev Loop-amplified min-delta for a warm swap (3 runs × 10 swaps).
    ///      Log-only: gas assertions belong in .gas-snapshot, not gasleft().
    function test_gas_swap() public {
        _seed(safePool, SEED0, SEED1);
        safePool.swap(1e18, 0, true, address(this)); // warm-up (cold account access)
        uint256 best = type(uint256).max;
        for (uint256 run; run < 3; ++run) {
            uint256 start = gasleft();
            for (uint256 i; i < 10; ++i) {
                safePool.swap(1e6, 0, true, address(this));
            }
            uint256 avg = (start - gasleft()) / 10;
            if (avg < best) best = avg;
        }
        console2.log("swap gas (10x loop, warm, min-of-3):", best);
    }

    function test_gas_getAmountOut() public {
        _seed(safePool, SEED0, SEED1);
        safePool.getAmountOut(1e18, true); // warm
        uint256 start = gasleft();
        for (uint256 i; i < 100; ++i) {
            safePool.getAmountOut(1e18, true);
        }
        console2.log("getAmountOut gas (100 calls):", (start - gasleft()) / 100);
    }
}
