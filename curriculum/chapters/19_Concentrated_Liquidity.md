# Concentrated Liquidity

Ch 18's constant-product pool spread its liquidity across the *entire* price range: `x·y = k` holds from zero to infinity, so most LP capital sits at prices nobody trades at. Uniswap V3's **concentrated liquidity** lets each LP choose the price band their capital works in, making the pool's curve *piecewise*: inside your range your liquidity is `L`; outside it you earn no *new* swap fees until price returns — fees already accrued are retained. The win is capital efficiency (a band `[P/c, P·c]` with `c = 1.10` earns ~21× the fees per unit capital of a full-range position); the cost is a much harder problem — the pool must track, tick by tick, which liquidity is active, how much of each token each position holds, and how fees are sliced per position. This chapter derives that machinery — the tick↔price↔`sqrtPriceX96` conversions, Q64.96 fixed-point, the amount formulas, and fee-growth accounting — and pins it in a lab mirroring `UniswapV3Pool.sol`'s swap path.

## Learning Objectives

1. Convert between price `P`, tick `i` (`P = 1.0001^i`), and Q64.96 `sqrtPriceX96 = sqrt(P)·2^96`, and explain why the *square root* is stored.
2. Explain `tickSpacing` and why usable ticks are discretized per fee tier.
3. Derive `L = sqrt(x·y)` and the piecewise amount formulas for a position `[tick_lo, tick_hi]` when price is below, inside, or above the range.
4. Compute a range's capital efficiency vs the full range (`c = 1.10 → ~21×`, `c = 1.01 → ~200×` for the symmetric band `[P/c, P·c]`).
5. Explain `feeGrowthGlobal` / `feeGrowthOutside` / `feeGrowthInside` and the per-position `L·(inside − insideLast)/2^128` owed-fee identity.
6. Explain why V3 positions are non-fungible and why the standard periphery (`NonfungiblePositionManager`) represents them as ERC-721 NFTs rather than ERC-20 shares.
7. State why the industry moved on from V2 (capital efficiency + the costs) and what post-V3 designs (hooks, dynamic fees) iterate on.
8. Place concentrated pools in Meridian: Ch 22's TWAP oracle reads V3-style accumulators; Ch 20 prices collateral off the same machinery.

## Prerequisites

- **Chapter 18** (AMMs: Constant Product) — the `x·y=k` curve, `L = sqrt(x·y)`, slippage; V3 is a piecewise generalization of exactly this.
- **Chapter 16** (ERC4626 Vaults) — rounding discipline and the `conversionsNeverGain` family; every amount formula here must floor or ceil in the pool's favor.
- **Chapter 4** (Integer Arithmetic & Units) — fixed-point and the rounding policy; Q64.96 is the same idea at 96 fractional bits.
- Supporting: **Ch 2** (custom errors in interfaces), **Ch 8** (gas measurement), **Ch 10** (parameter-exact `vm.expectRevert`), **Ch 12** (`bound` over `vm.assume`). Locked conventions remain in force.

## Theory

### The V2 problem: liquidity everywhere, used nowhere

A V2 pair holds the entire pool's capital against the *whole* curve. If ETH trades near $2,000, the reserves committed to $0.001 and $100,000 exist only so the curve is continuous — dead weight: the bulk of V2 fees accrue within a few percent of the current price. Concentrated liquidity moves that idle capital into the band where trades actually happen.

### The V3 idea: choose your band, earn per-unit liquidity

An LP mints a position over `[P_lo, P_hi]` with **liquidity** `L`. Inside the band the pool behaves like a V2 pool with reserves scaled by `L`; outside it, that LP's capital is not part of the active curve. State is piecewise: price in `[P_lo, P_hi)` → active, holds both tokens; below `P_lo` → 100% token0; above `P_hi` → 100% token1. Fees accrue **per unit of liquidity**: for the same active liquidity and the same volume traded through the band, the fee share is proportional to `L`, so the same `L` in a narrow band earns the same fee *rate* while locking up far less capital.

### Prices are discretized into ticks

Continuous prices are unmanageable on-chain. V3 discretizes: tick `i` ↔ price `1.0001^i`, a fixed 1-bp multiplicative step everywhere. **`tickSpacing`** restricts usable ticks to multiples of `i` — 1 (0.01% pools), 10 (0.05%), 60 (0.3%), 200 (1%) — so higher fee tiers have coarser grids, fewer initialized ticks, and cheaper swaps (the swap loop pays per tick crossed) at the cost of wider minimum bands.

### Liquidity concentration

Capital efficiency is the ratio of capital a *full-range* position needs for `L` to what a banded position needs for the same `L`. For a symmetric band `[P/c, P·c]` this is `√c/(√c − 1)`: ~21.5× at `c = 1.10`, ~200× at `c = 1.01`, ~2,000× at `c = 1.001` (the '±10%'/'±1%' labels are approximate — the band is `[P/c, P·c]`, which is −9.1%/+10% for `c = 1.10`); the whitepaper's $2,000–$3,000 example at $2,500 is ~10×. The cost side: a banded LP is *short the tails* — price exiting the band stops new fee earnings and leaves the position holding one token outright. Concentration turns V2's set-and-forget LP-ing into a strategy that demands active management when the chosen band no longer matches market conditions.

### Why positions are non-fungible: ERC-721 via the periphery

Two V2 positions are interchangeable (fungible shares); two V3 positions are **not** — each has its own band and `L`. Fungible ERC-20 shares cannot represent a heterogeneous set of bands, so V3 wraps each position in an ERC-721 NFT via the `NonfungiblePositionManager` periphery contract. The pool itself stores positions in a `mapping(keccak(owner, tickLower, tickUpper))`; the NFT adds ownership, transferability, metadata, and a market (positions can be sold, listed, or posted as collateral). The lab keeps the pool-side mapping; the NFT surface is covered in "Reading Production Source Code".

## Mathematical Foundations

### Q64.96: the fixed-point that made the math exact

Prices span `[2^-128, 2^128)` — too wide for a `uint128` price, and products of prices would overflow. But the pool's arithmetic works cleanly on **square roots** stored as fixed point: `sqrtPriceX96 = sqrt(P)·2^96` is Q64.96 (64 integer bits, 96 fractional bits — Ch 4's fixed-point at 96-bit precision). The pool never stores `P`; recovering it is one squaring: `P = (sqrtPriceX96 / 2^96)^2`. Since `P ∈ [2^-128, 2^128]`, `sqrt(P) ∈ [2^-64, 2^64)`, so `sqrtPriceX96 ∈ [2^32, 2^160)` — it fits a `uint160`. The endpoints are the `MIN_SQRT_RATIO = 4295128739` and `MAX_SQRT_RATIO` constants that bracket every V3 pool.

### Tick ↔ price ↔ sqrtPriceX96

```
P(i)  = 1.0001^i
i     = log_1.0001(P) = ln(P) / ln(1.0001)
√P(i) = 1.0001^(i/2)
```

The max tick solves `1.0001^i = 2^128` → `i ≈ 887,272`; hence `MIN_TICK = −887,272`, `MAX_TICK = 887,272`. Two conversions matter, both in the chapter's `TickMathLab` (a faithful pure-Solidity port of v3-core `TickMath.sol`):

- **`getSqrtRatioAtTick(tick)`** — computes `1.0001^(tick/2)` in Q128 by binary decomposition: multiply the precomputed constants `1.0001^(2^k)` for each set bit of `|tick|`, then scale Q128→Q96 **rounding up** so the returned ratio preserves the boundary inequality `getSqrtRatioAtTick(t) ≤ p < getSqrtRatioAtTick(t+1)` that `getTickAtSqrtRatio` expects.
- **`getTickAtSqrtRatio(sqrtPriceX96)`** — computes `log2(√P·2^96)` with 14 fractional bits, converts `log2 → log_1.0001`, and snaps to the greatest tick whose ratio does not exceed the input.

The lab pins the round-trip identities:

```
getTickAtSqrtRatio(getSqrtRatioAtTick(tick)) == tick            // exact
getSqrtRatioAtTick(t) <= sqrtPriceX96 < getSqrtRatioAtTick(t+1) // for t = getTickAtSqrtRatio(p)
```

### The liquidity invariant

V2's invariant in `L` form: `L = sqrt(x·y)`. Per token at price `P`:

```
x = L / √P        y = L · √P
```

Check: `x·y = L²` and `y/x = P`. Same constant-product curve, but `L` — the geometric-mean reserve — is now the *unit of account* for liquidity, and the pool moves `L` between positions as price crosses their bands.

### Amounts for a position [P_lo, P_hi] at price P

A position with `L` over `[P_lo, P_hi]` behaves like a full-range position of the same `L` with the tails removed. **Convention:** `P` is token1 per token0, so a price below the band leaves the position token0-heavy (100% token0 at `P ≤ P_lo`) and a price above it token1-heavy (100% token1 at `P ≥ P_hi`); inverting the convention flips the pieces. Amounts are piecewise (the lab's `getAmountsForLiquidity`):

- **Below** (`P ≤ P_lo`): holds only token0, equal to what a full-range `L` burns between `P_lo` and `P_hi`:

```
amount0 = L·(1/√P_lo − 1/√P_hi)        amount1 = 0
```

- **Inside** (`P_lo < P < P_hi`): the token0 that remains to be spent as price rises to `P_hi`, plus the token1 already earned rising from `P_lo` to `P`:

```
amount0 = L·(√P_hi − √P)/(√P·√P_hi)  =  L·(1/√P − 1/√P_hi)
amount1 = L·(√P − √P_lo)
```

- **Above** (`P ≥ P_hi`): all converted to token1:

```
amount0 = 0                            amount1 = L·(√P_hi − √P_lo)
```

Derivation of the in-range case: at price `P`, full-range `L` holds `x_full = L/√P` of token0; if price rises to `P_hi` it would hold `L/√P_hi`. The difference `L/√P − L/√P_hi = L·(1/√P − 1/√P_hi)` is the token0 converted as price climbs the band — exactly what the position deposits now. Symmetrically, the token1 held is what was converted rising from `P_lo` to `P`. In Q64.96 these become exact `mulDiv` expressions, e.g. `amount0 = L·2^96·(√B − √A)/(√A·√B)`, which the lab computes as `mulDiv(L<<96, B−A, B)/A`. Rounding follows Ch 4: amounts the pool *receives* round up, amounts it *pays* round down — the Balancer ~$128M direction is the counterexample (Security Analysis #1).

### Fee-growth accounting

Fees accrue per unit of *active* liquidity, tracked three ways:

- **`feeGrowthGlobal`** — total fees per unit of *active* liquidity since inception, one accumulator per token, in Q128 fixed point: `feeGrowthGlobalX128 ≈ cumulative fees / L × 2^128` (accumulator units, not token units).
- **`feeGrowthOutside(tick)`** — growth "on the far side" of a tick. A tick first initialized at-or-below the current tick is seeded with the current global (all growth so far is below it). On every crossing the value **flips**: `feeGrowthOutside = feeGrowthGlobal − feeGrowthOutside`.
- **`feeGrowthInside(lower, upper)`** — growth inside a band: `inside = global − below − above`, where `below = current ≥ lower ? lower.outside : global − lower.outside` and `above = current < upper ? upper.outside : global − upper.outside`. The production implementation relies on `uint256` modular arithmetic for these accumulators; the conceptual formula is shown over integers for readability.

A position's owed fees accrue lazily on the next position update:

```
tokensOwed += L·(feeGrowthInside − feeGrowthInsideLast) / 2^128
feeGrowthInsideLast = feeGrowthInside
```

The `2^128` scale cancels — `L × (fees/L × 2^128) / 2^128` lands in raw token units. Two consequences. Fees are **per unit of liquidity**: doubling `L` doubles the fee stream — a concentrated band holds more fee-earning power per dollar. And adding *more* liquidity to a band dilutes everyone's per-unit growth (the same swap fees spread over a bigger `L`). So "fees compound into positions as more liquidity" is a statement about *rate*, not auto-compounding: V3 fees do not reinvest themselves — the LP must re-mint to turn fees into liquidity. The lab pins both the accrual identity and the dilution.

## Engineering Perspective

For Meridian, concentrated AMMs matter at three integration points, all *read-only consumers* of pool state:

1. **Oracles (Ch 22).** The `OracleRegistry` TWAP fallback reads a V3 pool's built-in oracle: `observe()` returns cumulative tick-seconds, so the average tick over `[t₁, t₂]` is `(tickCum₂ − tickCum₁)/(t₂ − t₁)` and the average price is `1.0001^averageTick`. Unlike V2 (Ch 18), which sums the spot *price*, V3 accumulates the *tick* — a log price — and the accumulator lives inside the pool contract. Ch 20's collateral pricing reads the same accumulator: average tick → average price, converted only then to whatever representation the collateral module needs. LTV prices collateral off the TWAP, never a live `slot0` spot read (Ch 34's Mango class).
2. **Collateral valuation (Ch 20).** If Meridian ever accepts LP positions as collateral, a position's value is the sum of its two token amounts at the oracle price — this chapter's amount formulas — and the NFT wrapper makes it *transferable* collateral.
3. **Treasury liquidity (Ch 25).** V2's IL (Ch 18) was a function of one price ratio. Concentrated LP-ing adds the band, so the treasury decision becomes *which* band, how wide, and who rebalances it. The `docs/concentrated-liquidity-playbook.md` weekly document captures this framework.

**Why AMMs moved on.** The capital-efficiency numbers motivate it (~21×, ~200×), but the *costs* are why V3 is not free lunch: (1) **active management** — a banded position is a strategy, not a holding: it can sit passively while the band matches the market, but price drifting out of range turns fees off until the LP moves the band, paying gas per move; (2) **concentrated IL** — the same `1 − 2√r/(1+r)` applies, but out-of-range positions are 100% one token, so exposure is binary; (3) **MEV complexity** — concentrated pools add MEV surface: JIT liquidity (liquidity added and removed around a specific swap) and fragmentation across fee tiers; (4) post-V3 designs iterate on these: V4's **hooks** enable dynamic fees and custom AMM logic, and the singleton pool cuts deploy cost. The math this chapter builds is the substrate every one of those designs still uses.

2026 grounding keeps the stakes honest. **Balancer V2's ComposableStablePool (~$128M, Nov 2025)** was a rounding-direction failure in pool swap math — the anchor for Security Analysis #1, full treatment in Ch 26. **Kelp DAO / Drift (~$285–292M, Apr 2026)** enter where a concentrated pool has a *privileged* surface: the protocol-fee key and the factory's governance controls are separate privileged surfaces — distinct from pool core state — that belong in the Ch 25 timelock. On L2s (post-Fusaka, PeerDAS/EIP-7594 live, BPO scaling; Glamsterdam is roadmap-only), cheap DA makes small, tight bands viable on L1-style economics — shifting the `α` at which concentration pays (Ch 30/31).

## Mermaid Diagram

```mermaid
sequenceDiagram
    participant LP as LP (Alice)
    participant P as ConcentratedLiquidityLab pool
    participant T0 as token0 (ETH-like)
    participant T1 as token1 (USDC-like)

    Note over P: price = 2,000 → tick ≈ 76,010, sqrtPriceX96 = √2000·2^96
    LP->>P: mint(lower=75900, upper=76120, amounts)
    P->>P: L = getLiquidityForAmounts(price, lo, hi, amounts)
    P->>P: _updatePosition: tick in [lo,hi) → active liquidity += L
    T0-->>P: transferFrom(amount0 = L·(√hi−√P)/(√P·√hi))
    T1-->>P: transferFrom(amount1 = L·(√P−√lo))

    Note over P: pool.liquidity() = Σ L of in-range positions
    Trader->>P: swap(1 ETH token0, zeroForOne, minOut)
    P->>P: step = computeSwapStep(price, nextTick, L, gross, zeroForOne)
    P->>P: if price reaches an initialized tick: cross → feeGrowthOutside flips, L += liquidityNet
    P->>P: feeGrowthGlobal0 += stepFee·2^128 / L
    T1-->>Trader: transfer(amountOut, FLOORED)
    Note over P: inside = global − below − above; position owed += L·(inside − last)/2^128

    LP->>P: burn(lower, upper, L) → collect()
    P->>P: tokensOwed0 += principal + fees
    T0-->>LP: transfer(tokensOwed0); T1-->>LP: transfer(tokensOwed1)
```

## Code Walkthrough

The lab mirrors V3-core in three files, all under `meridian/src/`, LAB ONLY:

**`TickMathLab.sol`** — `getSqrtRatioAtTick` / `getTickAtSqrtRatio` plus the MIN/MAX constants. A faithful port of v3-core `TickMath.sol` with assembly replaced by Solidity shifts so the algorithm reads as math. One constant is a classic trap — bit `0x80` is `0xfe5dee046a99a2a811c461f1969c3053`, not the `0xfe5dee058a6d8…` of older ports — which is why the tests pin round-trip identities rather than trusting a hand-typed table.

**`IConcentratedLiquidityLab.sol`** — the error catalog per Ch 2/14 convention: `ZeroAmount`, `NoLiquidity`, `InvalidTickRange`, `InvalidSqrtRatio`, `InsufficientLiquidity`, `SlippageExceeded`, `NotAuthorized`, `MaxTickWalk` (the Ch 1 bounded-loop guard on the swap walk), plus the `Mint`/`Swap`/`Burn`/`Collect` events.

**`ConcentratedLiquidityLab.sol`** — the simplified-but-correct pool. Deliberate simplifications (documented in the header): `tickSpacing = 1`, no observations oracle, no protocol fee, no price limit (the slippage guard is `amountOutMin`), positions keyed by `keccak(owner, lower, upper)` rather than an NFT. What is *not* simplified is the swap path:

- `mint` derives `L` from the user's amounts via `getLiquidityForAmounts` (the binding constraint), pulls exactly what the piecewise formulas say, and `_updatePosition` adds `L` to active `liquidity` only when the current tick is inside `[lower, upper)` — the V3 `_modifyPosition` rule.
- `swap` is the real tick-walking loop. Per iteration: (1) find the next initialized tick via the bitmap (`_nextInitializedTickWithinOneWord`, a faithful `TickBitmap` port); (2) clamp to MIN/MAX; (3) call `_computeSwapStep` (a port of `SwapMath.computeSwapStep` for exact input), which crosses the whole step to the target tick or stops mid-range when input is exhausted; (4) credit the step's fee to `feeGrowthGlobal` against the *pre-cross* liquidity — the step's fees belong to the liquidity that was active during that step, and only after accounting for it does the pool cross and change active liquidity; (5) if it landed exactly on an initialized tick, cross it — flip `feeGrowthOutside` and apply `liquidityNet` (negated when moving left, the V3 `state.tick = tickNext − 1` convention).
- `burn` removes liquidity (accruing fees through the same `_updatePosition`), credits principal to `tokensOwed`, and `collect` pays out — CEI, transfers last.

Rounding directions are V3's throughout: input deltas and the next-price step round **up** (`getNextSqrtPriceFromAmount0RoundingUp`), output deltas round **down**.

## Production Example

**The Ch 22 TWAP oracle reading a V3 pool** is this chapter's production shape, and it is *simpler* than the V2 version: the accumulator lives inside the pool, so `OracleRegistry` calls `pool.observe([Δt₀, Δt₁])` and computes `price = 1.0001^((tickCum₂ − tickCum₁)/(t₂ − t₁))`. No reserve math, no pair address to derive. The vault (Ch 20) prices collateral through this same surface, never a raw spot read — a flash-loan-sized swap moves `slot0` instantly, but the window average only moves if the attacker sustains the distortion across the observation window — longer windows make that progressively more expensive (Ch 34's Mango class).

A second thread is the **position NFT as collateral**. `NonfungiblePositionManager` gives each banded position `ownerOf(tokenId)`, `tokenURI` metadata, and `positions(tokenId)` returning exactly this chapter's fields — `liquidity`, `tickLower`, `tickUpper`, `feeGrowthInsideLast`, `tokensOwed`. A lending protocol that accepts a position NFT as collateral can price it with the amount formulas and liquidate via `decreaseLiquidity` + `collect` — the vault integration Meridian would build if it ever lists LP collateral (Ch 20 listing gate). The 2026 grounding note: the NFT's `owner` is the collateral debtor, but the *pool's* privilege (protocol-fee key, factory-governance controls) is a separate admin surface for the Ch 25 timelock.

## Foundry Lab

Materialized and compile-verified in this run (forge 1.7.1, solc 0.8.24, cancun, optimizer 200):

- **New artifacts:** `src/TickMathLab.sol`, `src/IConcentratedLiquidityLab.sol`, `src/ConcentratedLiquidityLab.sol`, `test/TickMathLab.t.sol` (14 tests), `test/ConcentratedLiquidityLab.t.sol` (24 tests). All Ch 1–18 suites untouched and green.
- **Full repo suite: 314 passed / 0 failed / 6 skipped (320 total) across 27 suites** (Ch 18 baseline 276/0/6 across 25; +38 tests, +2 suites). The 6 skips remain the Ch 11 fork tests (RPC-gated).
- **Gas probes (loop-amplified min-deltas, warm-up first, log-only):** `swap` **≈ 24,322** · `mint` **≈ 31,779**; the conversion costs are pinned in `TickMathLab.t.sol`, both under ~3k warm.
- **Real findings, all kept:** (1) The swap loop hit **stack-too-deep** with per-step locals — the canonical fix is V3's own: `StepComputation` and `SwapState` memory structs. (2) A swap crossing into a zero-liquidity gap must **terminate and refund** the unconsumed input rather than divide by zero — a deliberate lab behavior. Production V3 also has inactive regions (not every tick is initialized); its walk continues to the next initialized tick or stops at the price limit. `MaxTickWalk` and the `activeLiquidity == 0` break are the lab's bounded-loop guards. (3) The fuzz round-trip showed a **1-wei input is swallowed by price rounding** (output floors to 0), so the fuzz bounds `amountIn ≥ 1e6`; the honest round-trip bound is *relative* to the move, because one output wei maps to `2^96/L` wei of sqrt price. (4) `TickMath`'s reverts are tested through an external harness: an inlined library call reverts in the caller's frame, so `vm.expectRevert` cannot catch it.

## Security Analysis

**1. Rounding direction is a security property (the anchor class).** Every amount computation must favor the pool: inputs round up, outputs round down. A pool that pays the *ceil* of the output hands the trader a wei the pool must fund per swap — the Balancer V2 failure (~$128M, Nov 2025), full treatment in Ch 26. The lab's `test_pool_reverts_slippage` and `test_swap_zeroFee_outputMatchesLiquidityMath` pin the floor direction; Ch 18's `CeilOutPool` was the same class in V2 form.

**2. Fee accounting can underflow if the accumulator order is wrong.** `owed = L·(inside − insideLast)/2^128` assumes `inside ≥ insideLast`, which holds because `feeGrowthInside` is monotone and `_updatePosition` writes `insideLast` *after* computing the delta. The `feeGrowthOutside` flip on crossing is the other half: forget it, and `global − below − above` mis-slices fees across bands. The lab pins `owed == L·inside/2^128` exactly.

**3. Spot price is not an oracle.** `slot0.sqrtPriceX96` moves with one swap (flash-loan-sized, Ch 34); reading it as a feed is the Mango class (Ch 11). V3's accumulator is *better* than V2's for Meridian because it accumulates the log price — a 1% manipulation must shift the accumulated tick over the observation window, and the longer the window, the costlier the distortion is to sustain.

**4. The tick walk must be bounded and gap-safe.** An unbounded or incorrect walk (a `liquidityNet` sign error, a missing `initialized` branch, a zero-liquidity gap) is a DoS or a wrong price. The lab enforces `MaxTickWalk` and breaks on `activeLiquidity == 0`; the bitmap sentinel math is pinned by the crossing test.

**5. A fee key is a trust root (Kelp DAO/Drift class).** The pool's privileged surfaces — protocol-fee key, factory-governance controls — are admin keys scoped to their actual control (fee tiers, protocol-fee settings), not arbitrary admin over core state; a compromised fee key diverts every swap's fees. In Meridian these live in the Ch 25 timelock.

**6. Concentrated positions concentrate IL.** The `1 − 2√r/(1+r)` formula still applies, but out-of-range positions are 100% one token — binary exposure. For treasury LP-ing this is a Ch 25 decision, priced by the playbook, not an autopilot.

## Common Mistakes

1. **Using the live spot tick or `sqrtPriceX96` as an oracle** — one swap moves it; the Ch 22 accumulator exists to make the average expensive to move.
2. **Rounding an amount in the trader's favor** — the Balancer direction; input up, output down, every time.
3. **Forgetting the `feeGrowthOutside` flip on tick crossing** — the inside/outside decomposition mis-slices fees after the first crossing.
4. **Not updating active `liquidity` on an in-range mint/burn** — swaps then ignore newly added depth (or price moves with phantom liquidity).
5. **Ignoring `tickSpacing`** — a position on an unaligned tick cannot be initialized.
6. **Confusing the pool's position mapping with the NFT** — the pool tracks `(owner, lower, upper)`; the NFT adds transferability and metadata; reading only one misprices collateral.
7. **Banding too narrowly** — fees must beat IL *and* rebalance cost; a band tighter than the asset's vol is a slow bleed.
8. **Leaving liquidity gaps in the curve** — a swap walking into a zero-liquidity region has no active liquidity to price against; the lab terminates and refunds, while production V3 walks on to the next initialized tick or the price limit.
9. **Writing the swap loop without a bound** — a `liquidityNet` sign error turns a small swap into an unbounded loop (Ch 1).

## Gas Optimization

Measured in this run (loop-amplified min-deltas, warm-up first — Ch 8 methodology):

- **`swap` ≈ 24,322 gas** warm for a single-range trade. Dominant costs are the two `SafeERC20` transfers and per-step state reads; the curve math is one `mulDiv` per step. Real V3 pools pay more per crossing because each tick writes observation data; the lab strips that to isolate the walk.
- **`mint` ≈ 31,779 gas** warm for an in-range position — two `_updateTick` calls (each possibly a bitmap flip), the fee-growth read, two transfers. Out-of-range mints are cheaper.
- **`getSqrtRatioAtTick` / `getTickAtSqrtRatio`** under ~3k gas warm each — shifts and multiplications, no storage; the per-call price the Ch 22 oracle pays per observation.
- **Design notes:** (1) The swap loop keeps mutable state in a `SwapState` memory struct — V3's answer to stack-too-deep, costing nothing at the ABI level. (2) Fee growth is credited **per step** against the pre-cross liquidity; a single post-swap division would misattribute fees across a crossing. (3) Rounding up input and down output is both the safe direction *and* the cheap one (Ch 8: remove, then cheapen, then measure).

Per the locked methodology, gas probes are log-only; `.gas-snapshot` rows are the regression gate (Ch 13), regenerated under the CI seed.

## Reading Production Source Code

1. **Uniswap v3-core `TickMath.sol`** — the exact source the lab ports. Read the bit-`0x80` constant, the Q128→Q96 rounding-up step, and the `log2`-with-14-bits algorithm; the round-trip identities are why the division "rounds up … so `getTickAtSqrtRatio` of the output price is always consistent."
2. **`UniswapV3Pool.sol`** — read `mint`/`_modifyPosition` (the three-branch amount selection and the `tick < tickUpper` active-liquidity write), `swap` (the `while` loop with `SwapMath.computeSwapStep` per tick, the `state.tick = zeroForOne ? tickNext − 1 : tickNext` convention, fee growth per step), and `_updatePosition`. The lab is this function, simplified and commented.
3. **`Tick.sol` / `TickBitmap.sol`** — `Tick.update` (the `tick <= tickCurrent` seeding of `feeGrowthOutside`), `Tick.cross` (the flip), and `nextInitializedTickWithinOneWord` (the sentinel-walk; note the `type(uint8).max − bitPos` fallback).
4. **`SqrtPriceMath.sol` / `SwapMath.sol`** — the rounding split in `getNextSqrtPriceFromAmount0RoundingUp` / `getAmount0Delta(…, roundUp)` and the exact-input branch of `computeSwapStep` (the `feeAmount = amountRemaining − amountIn` partial-step rule).
5. **`NonfungiblePositionManager.sol`** (v3-periphery) — the ERC-721 surface: `mint` wraps a pool position into a `tokenId`, `positions(tokenId)` returns this chapter's fields, `decreaseLiquidity`/`collect` move value out.
6. **Post-V3:** Uniswap v4's `PoolManager.sol` + hooks — the singleton + hook iteration on the per-pool fee model.

## Exercises

1. Convert price 2,000 to a tick (`log_1.0001(2000)`) and to `sqrtPriceX96 = floor(sqrt(2000)·2^96)`. Confirm `getTickAtSqrtRatio` round-trips.
2. Derive the in-range amount formulas from `x = L/√P, y = L·√P`.
3. Prove `√c/(√c−1)` for a symmetric band `[P/c, P·c]` and compute it for `c = 1.10`, `c = 1.01`.
4. For the lab's pool at price 2,000 with `L = 1e20` in `[75900, 76120]`, compute the two token amounts and verify against `getAmountsForLiquidity`.
5. Trace a swap crossing the upper tick: which line flips `feeGrowthOutside`, which changes active liquidity, and why is the departing range's fee credited *before* the cross?
6. Explain why `getSqrtRatioAtTick(MAX_TICK)` is valid but `getTickAtSqrtRatio(MAX_SQRT_RATIO)` reverts.
7. Read `NonfungiblePositionManager.positions(tokenId)` and list which fields the pool-side mapping does *not* store.

## Weekly Project

**The concentrated-liquidity playbook — `docs/concentrated-liquidity-playbook.md`, added to the pending docs list:**

1. Write the three derivations (tick↔`sqrtPriceX96`, piecewise amounts, fee inside/outside) with the lab's pinned numbers and the capital-efficiency table for `c = 1.01` / `c = 1.10` bands.
2. Add the Meridian integration contract: the Ch 22 V3-TWAP read pattern (`observe()` → average tick → price), the Ch 20 collateral note (tick-cumulative TWAP, never `slot0`), and the treasury band-selection framework (width vs IL vs rebalance cost, Ch 25 timelock signer).
3. Confirm the suite is green: `forge test` → **314 passed / 0 failed / 6 skipped (320 total)** across 27 suites; `.gas-snapshot` regenerated under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`.
4. Protocol contract count: **still 2** (MER, gMER). No protocol source changed; `MeridianVault.sol` arrives in Ch 20.

## Deliverables

1. `src/TickMathLab.sol` — the faithful pure-Solidity `TickMath` port (constants byte-exact vs v3-core), compile-verified in-run.
2. `src/IConcentratedLiquidityLab.sol` + `src/ConcentratedLiquidityLab.sol` — the error catalog + the simplified-but-correct pool (bitmap tick-walk, per-step fee growth, position fee accrual), compile-verified in-run.
3. `test/TickMathLab.t.sol` (14 tests) + `test/ConcentratedLiquidityLab.t.sol` (24 tests) — all green; repo suite **314 passed / 0 failed / 6 skipped across 27 suites**.
4. Conventions locked: input-up/output-down rounding; per-step fee growth credited pre-cross; `feeGrowthOutside` flip on crossing; active-liquidity write only when `tickLower ≤ tick < tickUpper`; bounded swap walk (`MaxTickWalk`).
5. Gas profile: swap **24,322** · mint **31,779** · conversions < ~3k (warm, loop-amplified min-deltas).
6. The Ch 22 V3-TWAP read contract and the treasury band-selection framework (in `docs/concentrated-liquidity-playbook.md`).

## Quiz

1. Why does V3 store `sqrt(P)·2^96` instead of `P`? What are the bounds on `sqrtPriceX96` and why do they fit a `uint160`?
2. `P = 1.0001^i`. What is the tick for `P = 2,000`, and what does `tickSpacing = 60` mean for a 0.3% pool?
3. Derive `amount0` and `amount1` for a position `[P_lo, P_hi]` at price `P` inside the range, from `x = L/√P, y = L·√P`.
4. A position below its range holds which token? Above its range? Why does it earn no fees in either case?
5. What is the capital efficiency of a symmetric band `[P/c, P·c]` with `c = 1.10` (loosely '±10%'), and the trade-off that makes it not free lunch?
6. State the `feeGrowthOutside` flip rule and derive `feeGrowthInside` from `global`, `below`, and `above`. How is a position's owed fee computed?
7. Why is a V3 position non-fungible, and why does the periphery represent it as an ERC-721 NFT rather than an ERC-20 share? What does the `NonfungiblePositionManager` add over the pool's internal mapping?
8. Name the V3 rounding-direction rule and connect it to the Balancer V2 incident (~$128M, Nov 2025).

**Answers:** (1) Products/divisions of prices are exact in Q64.96, and `√P ∈ [2^-64, 2^64)` for `P ∈ [2^-128, 2^128)`, so `sqrtPriceX96 ∈ [2^32, 2^160)` fits `uint160`. (2) `ln2000/ln1.0001 ≈ 76,012.8` → tick 76,012; spacing 60 restricts usable ticks to multiples of 60. (3) `amount0 = L(√P_hi − √P)/(√P·√P_hi)`, `amount1 = L(√P − √P_lo)`. (4) Below → 100% token0; above → 100% token1; both earn no new swap fees because active liquidity is only the sum of `L` for bands containing the current price. (5) `√1.1/(√1.1 − 1) ≈ 21×`; the trade-off is active management, banded IL, rebalance gas, and new MEV surface. (6) On crossing, `feeGrowthOutside = global − feeGrowthOutside`; `inside = global − below − above`; owed `= L·(inside − insideLast)/2^128`. (7) Positions are non-fungible (distinct band + liquidity), so fungible shares cannot represent them; the NFT adds ownership, transferability, metadata, and a collateral market. (8) Inputs round up, outputs round down — the pool's favor; the Balancer pool paid out the rounding edge and lost ~$128M (Ch 26).

## Further Reading

- **Uniswap V3 whitepaper** (Adams, Zinsmeister, Salem, Keefer, 2021) — primary source for capital efficiency, tick math, and the NFT design; this chapter's formulas are its section 6.1.
- **Uniswap v3-core repo** — `TickMath.sol`, `SqrtPriceMath.sol`, `SwapMath.sol`, `Tick.sol`, `TickBitmap.sol`, `UniswapV3Pool.sol`: the exact sources the lab ports.
- **Uniswap v3-periphery repo** — `NonfungiblePositionManager.sol`: the ERC-721 surface and `positions(tokenId)`.
- **Uniswap v4** (PoolManager + hooks) — the post-V3 iteration "Why AMMs moved on" points at.
- **Balancer V2 ComposableStablePool post-mortem (Nov 2025, ~$128M)** — the rounding-direction anchor; full treatment in Ch 26.
- **Ch 22** (the V3-TWAP oracle), **Ch 20** (collateral pricing off the V3 TWAP), **Ch 34** (JIT liquidity and MEV on concentrated pools), **Ch 25** (the timelock that holds the fee key and approves band selection).

## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/19_Concentrated_Liquidity_REVIEW.md`):** TWAP corrected to tick-cumulative (average tick → price), not time-weighted sqrtPriceX96; manipulation-hold-window qualified; ±10
## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/19_Concentrated_Liquidity_REVIEW.md`):** TWAP corrected to tick-cumulative (average tick → price), not time-weighted sqrtPriceX96; manipulation-hold-window qualified; capital-efficiency bands defined exactly; V3 position vs ERC-721 periphery separated; feeGrowth units (per-L × 2^128) and modular arithmetic noted; half-open interval standardized; factory-owner privilege scoped.
