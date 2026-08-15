# AMMs: Constant Product

Everything Meridian has built so far — tokens (Ch 14), governance (Ch 15), vault share math (Ch 16), token security (Ch 17) — is *accounting*: the protocol records what it owes and holds, and the invariant is that the two agree. An AMM is different: a **price-discovery machine with no order book**, a pool of two tokens and one algebraic invariant that turns any trade into a price update. The constant-product market maker (CPMM), the curve behind Uniswap V2 and every clone since, is the simplest complete example of the class. This chapter derives that curve from first principles, pins its math in a lab, and shows why the one-line detail that makes a pool safe — **the direction in which amounts round** — was the exact detail that emptied a Balancer pool for ~$128M in November 2025.

## Learning Objectives

By the end of this chapter you will be able to:

1. Derive the invariant `x·y = k` and explain why constant product (not constant sum or constant mean) gives an open market its unbounded price response — as one reserve approaches zero the marginal price diverges, and no finite trade fully drains the pool.
2. Solve the swap equation `out = y − k/(x + in)`, restate it as Uniswap V2's `getAmountOut`, and compute the spot price `|dy/dx| = y/x`.
3. Distinguish execution price from spot price and quantify slippage in closed form: `slippage = α/(1+α)` for a trade of `α·x` against reserve `x`.
4. Explain fee-on-input: the effective input `in·(1−f)`, the effective invariant `k' = (x + in·(1−f))·(y − out)`, and why the invariant **drifts upward** with every swap.
5. Reproduce V2 LP-share math (first mint `sqrt(x·y) − 1,000`, later mints by min-ratio) and derive impermanent loss `IL = 1 − 2√r/(1+r)` with a full numeric walkthrough vs HODL.
6. Explain why the **rounding direction is a security property** (the Balancer ~$128M flaw class): amount-out must floor, never ceil.
7. Place AMMs in Meridian: Ch 22's TWAP oracle reads AMM reserves; Ch 20 prices collateral; Ch 34's MEV and liquidation arbitrage run against AMM liquidity.

## Prerequisites

- **Chapter 16** (ERC4626 Vaults) — share-of-pool math, rounding directions, the `conversionsNeverGain` family; LP-share and rounding questions are the same shapes applied to a pool.
- **Chapter 14** (ERC20 Deep Dive) — token transfers, `safeTransferFrom`, the I-prefix error-catalog convention (OZ v5).
- **Chapter 4** (Integer Arithmetic & Units) — WAD/RAY fixed point, the rounding policy (floor user-received, ceil user-paid), full-precision `mulDiv`.
- Supporting: **Ch 2** (custom errors in interfaces), **Ch 8** (gas measurement), **Ch 10** (parameter-exact `vm.expectRevert`, non-privileged negatives), **Ch 12** (`bound` over `vm.assume`). Locked conventions remain in force.

## Theory

### The invariant that prices a pool

A CPMM holds reserves `x` of token0 and `y` of token1 and requires their **product** to stay constant:

```
x · y = k
```

That single equation is the entire market. A trader adds `Δx` of token0; the pool pays `Δy` of token1; the new state must satisfy `(x + Δx)(y − Δy) = k`. Solve for the output:

```
y − Δy = k / (x + Δx)
Δy = y − k/(x + Δx) = y · Δx / (x + Δx)          (no-fee form)
```

The second equality is algebraic (`y − xy/(x+Δx) = y·Δx/(x+Δx)`). Both forms describe the same trade; the single fraction is what the code uses, because it is one division, floored.

Why **product** and not sum or mean?

- **Constant sum** (`x + y = k`): price is fixed at `1` until one reserve runs dry, then the pool is dead. Fine inside a tight peg, useless as a market: no price response to demand.
- **Constant product** (`x·y = k`): price `y/x` moves continuously as reserves shift. The curve is asymptotic — a pool can never be fully drained by one trade — so there is always *some* price at which a trade clears.
- **Constant mean** (`Π xᵢ^{wᵢ} = k`, Balancer): the weighted generalization; price is `(w₁/w₀)·(y/x)`, impact depends on weight. Constant product is the 50/50 case.

### Spot price, execution price, slippage

From the invariant, `y = k/x`, so the marginal rate is the derivative's magnitude:

```
|dy/dx| = |−k/x²| = xy/x² = y/x
```

This **spot price** is what an infinitesimal trade would pay. A finite trade pays the **execution price** `p_exec = Δy/Δx`, which is strictly worse for the bought side: as `x` rises, the marginal price keeps climbing, and `p_exec` is the average over that climb. The gap is **slippage**.

For a fee-less trade of `Δx = α·x` there is a clean closed form:

```
p_exec = (y·αx/(x+αx)) / (αx) = spot / (1+α)
slippage = 1 − p_exec/spot = α/(1+α)
```

A 1% trade costs ~0.99%, a 10% trade 9.1%, a trade equal to the whole reserve (`α = 1`) 50%. Slippage is a function of **size relative to reserves**: the cost of a trade is set by the ratio of the trade to the pool. Throughout, **price impact** is the curve effect alone, **fee** the explicit trading fee, and **execution shortfall** their combined gap; "slippage" names the fee-less curve effect and "total slippage" the combined shortfall. The three are related but not interchangeable.

### Fees and the drift of the invariant

Uniswap V2 charges **0.3% on the input** — not subtracted from the output, but subtracted from the *effective input the invariant math sees*:

```
effective input = in · 997/1000
out = y − k / (x + in·997/1000) = y · in·997 / (x·1000 + in·997)
```

The pool **records the full `in` as reserve growth**, so the post-trade reserves are `(x + in, y − out)` and the recorded invariant is:

```
k' = (x + in)(y − out)  ≥  k   (strictly > when f > 0)
```

Because `out` moved the curve with only `in·997/1000`, the pool keeps the other 0.3% as extra reserve. That is the invariant **drifting upward with fees**: fees are structurally profit for LPs, a continuous upward drift of `k` paid by traders. The reserve growth is fee value retained by the pool; protocol-level fee switches can later divert a portion to a protocol fee recipient. The floor below is the second guard — even at zero fees, rounding the output down can never lose pool value.

Why the **input** rather than the output? Both are algebraically workable, but the input convention (Uniswap's standard, inherited by every fork) keeps `getAmountOut` a single clean division and takes the fee from value the trader was already committing — the pool can never pay out more than the invariant allowed *and* the fee.

### LP shares: mint by ratio, protect with dead shares

Liquidity is measured by `L = sqrt(x·y)`, the geometric mean of reserves. The first deposit sets the ratio and mints:

```
liquidity = sqrt(x·y) − MINIMUM_LIQUIDITY        (MINIMUM_LIQUIDITY = 1,000)
```

The 1,000 shares are minted to `address(0)` — **dead shares** no one can burn. They keep `totalSupply` permanently nonzero after initialization and substantially raise the cost of first-depositor manipulation — inflation, donation, and withdraw-and-reseed attacks (Ch 16's donation family) — though they do not make every donation or repricing attack impossible. Later deposits mint by the **smaller** reserve ratio:

```
liquidity = min(Δx·totalSupply/x,  Δy·totalSupply/y)
```

A proportional deposit gets exactly its share; an imbalanced one gets the binding ratio and the excess stays as a donation that drifts `k` up. The implementation floors minted liquidity and the amounts returned on burn, leaving rounding dust in the pool.

### Impermanent loss

An LP position underperforms simply holding the two tokens: as the price moves, the pool rebalances toward the cheap token, and the shortfall — **impermanent loss** — is a function of the price ratio only. The formula is the **fee-free divergence loss** relative to HODL; in production, LP fees and incentives offset it:

```
r = p₁/p₀        IL = 1 − 2√r / (1 + r)
```

Concrete walkthrough: pool 100 ETH / 200,000 USDC (spot 2,000); you deposit 10 ETH + 20,000 USDC = 10% of the pool. ETH doubles to 4,000 (`r = 2`). The pool rebalances: `xy = k`, `y/x = 4000` ⇒ `x = 70.71 ETH`, `y = 282,842.7 USDC`. Your 10% is 7.071 ETH + 28,284.3 USDC = **56,568.6 USDC**. HODL is 10·4,000 + 20,000 = **60,000 USDC**. IL = **5.72%** — and `1 − 2√2/3 = 0.0572`. ✓

The loss is "impermanent" only if the price returns — held long-term it is a real, paid cost. **For Meridian this is a treasury question:** sMER accrues protocol revenue as share appreciation (Ch 23). If the DAO LPs those reserves into an AMM, fees must beat the IL against the HODL baseline, and the decision belongs in the Ch 25 timelock — treasury LP-ing has a formula-priced downside.

## Mathematical Foundations

### The swap equation, solved exactly

With fee `f = 3/1000`, derive from `(x + in·997/1000)(y − out) = k`:

```
out = y − x·y / (x + in·997/1000)
    = y·(in·997/1000) / (x + in·997/1000)
    = y · in · 997 / (x·1000 + in·997)                [×1000/1000]
```

The last line is **exactly** Uniswap V2's `getAmountOut`:

```
amountOut = in · 997 · reserveOut / (reserveIn · 1000 + in · 997)
```

The lab pins this equivalence (`test_swapMath_getAmountOut_matchesInvariantDerivation`).

### Full numeric example (lab-pinned)

Pool 100e18 / 200,000e18 wei (spot 2,000), fee 3/1000, swap `in = 1e18`:

| Quantity | Value | Derivation |
|---|---|---|
| no-fee out | 1,980.198 USDC | `200000 − 20000000/101` |
| with-fee out | **1,974.316** USDC | `200000 − 20000000/100.997` |
| execution price | 1,974.3 | `out / in` |
| price impact | 0.99% | `(spot − exec_noFee)/spot` |
| fee | 0.29% | `(out_noFee − out_fee)/spot` |
| total slippage | **1.28%** | `(2,000 − 1,974.316)/2,000` |

Slippage grows non-linearly: 10 ETH in → `out ≈ 18,132` (exec 1,813.2, −9.34%); 100 ETH in → `out ≈ 99,850` (exec 998.5, −50.1%). The closed form `α/(1+α)` predicts all three. The 1.28% / 0.99% / 0.29% split is approximate, not an identity: fee and curve impact are not exactly additive in percentage terms, because the fee changes the effective input the curve sees. Precisely: execution shortfall ≈ 1.28%, fee contribution ≈ 0.29 percentage points, fee-less curve impact ≈ 0.99 percentage points.

### The rounding direction, formalized

Let the exact no-fee output be the real number `o = y·in/(x+in)`. A pool computing `out = floor(o)` leaves `k' = (x+in)(y−out) ≥ (x+in)(y−o) = k` — never a loss to rounding. A pool computing `out = ceil(o)` pays the trader more than `o`, so `k' < k`: **every fractional trade hands pool value to the trader**, and repeated trades create a systematic value leak that can accumulate — gas and minimum trade sizes bound how economically exploitable it is. The safe direction is floor (the pool's favor) — Ch 4's "floor for user-received" — and the vulnerable direction is the one that rounds the payout up. The lab's `CeilOutPool` is the minimal demonstration: zero fee, one ceil, and `k` monotonically non-increasing. This `k' ≥ k` statement is the ideal-CPMM form; Uniswap V2's production check is fee-adjusted and runs on measured post-swap balances via `_update` — the pair stores no raw `k` to compare directly — but the direction is identical: the pool must never pay the fractional remainder.

### Impermanent loss, derived

An LP holds fraction `s` of a pool starting at `(x₀, y₀)`. At price `p₁`, the pool rebalances to `x₁ = √(k/p₁)`, `y₁ = √(k·p₁)`. LP value in token1 units is `s·(x₁p₁ + y₁) = 2s·√(k·p₁)`; HODL is `s·(x₀p₁ + y₀)`. With `p₁ = r·p₀` and `p₀ = y₀/x₀`, the ratio `2√(k·p₁)/(x₀p₁+y₀)` reduces to `2√r/(1+r)` — hence `IL = 1 − 2√r/(1+r)`, symmetric in `r` and `1/r` (doubling and halving cost the same).

## Engineering Perspective

For Meridian, AMMs are **infrastructure to consume, not a product line**. Three integration points:

1. **Oracles (Ch 22).** The `OracleRegistry` fallback is a **TWAP computed from AMM reserves**. V2 pairs maintain `price0CumulativeLast`/`price1CumulativeLast`, a sum of the spot price per block; the TWAP over an interval is `(cumulative₁ − cumulative₀)/Δt`. Cumulative-price TWAPs make sustained manipulation more expensive — the attacker must influence the accumulated price over the observation interval — but they do not make manipulation impossible. This chapter's pool is the reserve shape that accumulator reads — foreshadowed here, built in Ch 22.
2. **Collateral valuation (Ch 20).** `MeridianVault` prices collateral through the oracle layer, never a raw AMM spot read — a spot read is manipulable with one flash loan (Ch 34). If Meridian ever accepts LP positions as collateral, their value is `2·√k/totalSupply`, itself this chapter's math.
3. **MEV and liquidation arbitrage (Ch 34).** A large swap's slippage is an extractable edge: a sandwich attacker wraps it in two small swaps and captures the price impact. Liquidation engines exit seized collateral into AMM liquidity; designing them MEV-hard requires exactly this curve.

The 2026 grounding keeps the stakes honest. **Balancer V2's ComposableStablePool (~$128M, Nov 2025) was a rounding-direction failure in pool swap math** — amount-out (and BPT-out) rounded in the trader's favor, and the pool paid for it. It is this chapter's anchor: the direction of a division, worth nine figures. **Kelp DAO/Drift (~$285–292M, Apr 2026)** are a different axis — admin keys, not math — and enter only where this chapter's single privileged surface lives: the swap-fee key. On L2s (post-Fusaka, PeerDAS/EIP-7594 live, BPO scaling; Glamsterdam is roadmap-only), AMM math is chain-agnostic but cheap DA makes smaller pools viable, changing the `α` at which slippage turns dangerous (Ch 30/31).

## Mermaid Diagram

```mermaid
sequenceDiagram
    participant T as Trader (Alice)
    participant P as ConstantProductPool
    participant T0 as token0 (ETH)
    participant T1 as token1 (USDC)

    Note over P: reserves (x=100, y=200,000), k = x·y = 2e43
    T->>T: sign swap(1 ETH, amountOutMin, zeroForOne=true)
    T->>P: swap(amountIn=1 ETH, amountOutMin)
    P->>P: fee on input: effective in = 1 · 997/1000 = 0.997
    P->>P: out = y − k/(x + 0.997) = 1,974.316 USDC  (FLOOR)
    P->>P: reserves := (x + 1, y − 1,974.316)   [full in recorded]
    Note over P: k' = (x+1)(y−1,974.316) > k — fee drifts k UP (lab CEI ordering; V2 validates post-transfer balances under lock)
    T0-->>P: transferFrom 1 ETH
    P-->>T1: transfer 1,974.316 USDC
    Note over T: exec price 1,974.3 vs spot 2,000 → 1.28% slippage
    Note over T,P: slippage ≈ α/(1+α): 1% of reserves ≈ 1%, 100% of reserves ≈ 50%
```

## Code Walkthrough

The lab spans three files mirroring the Ch 16 vault-lab shape: `src/IConstantProductPoolLab.sol` (the error catalog on the interface — `ZeroAmount`, `InsufficientLiquidity`, `InsufficientShares`, `SlippageExceeded`, `NotAuthorized`, `FeeOutOfBounds`, `Reentrancy`), `src/ConstantProductPoolLab.sol` (an abstract base plus safe/flawed twins), and `test/ConstantProductPoolLab.t.sol` (30 tests).

**The abstract base** implements the V2-shaped surface. `getAmountOut(amountIn, zeroForOne)` selects in/out reserves and delegates the single math line to abstract `_amountOut`; `swap` enforces CEI — reserves update *before* token transfers — and reverts `SlippageExceeded(min, out)` when the trader's minimum is unmet. That ordering is the lab's simplification for its state machine; Uniswap V2's `swap` instead performs the optimistic transfers first, measures the post-transfer balances, derives the actual input, applies the fee-adjusted invariant, and only then `_update`s the cached reserves — all under the reentrancy lock. `addLiquidity` pulls both tokens, measures balance deltas, and applies the first-mint `sqrt(x·y) − 1,000` / later-min-ratio rules with the dead 1,000 shares to `address(0)`; `removeLiquidity` burns shares then pays pro-rata floors; `sync` re-reads reserves from balances so a donation joins the invariant; `setSwapFee` is the single owner-gated surface. The `lock` modifier is Ch 24's reentrancy answer, carried for faithfulness (the lab's MiniToken is hookless, so it is structural, not exercised).

**The twins differ in exactly one line** — the rounding direction of `_amountOut`:

- `ConstantProductPool` — fee 3/1000, `Math.mulDiv(...)` default **Floor**. The pool keeps every rounding edge.
- `CeilOutPool` — fee 0, `Math.mulDiv(..., Math.Rounding.Ceil)`. **The flaw**: with the fee removed, the ceil alone pays the trader a wei per fractional trade the pool must fund, so `k' ≤ k` always. The Balancer-direction class, isolated from fees so the leak is attributable to the rounding line.

**Tests, by property.** Swap math: `getAmountOut` matches the invariant-derived single-floor formula, plus a pinned concrete number (`1,974,316,068,794,122,597,700` wei for 1 ETH into the 100/200,000 pool). Invariant: `test_invariant_withFee_driftsUp` pins the strict upward drift; `testFuzz_swap_withFee_invariantNonDecreasing` asserts `k' ≥ k` over 1,000 bounded swaps. Slippage: the spot/execution/impact/size tests plus `test_slippage_numericExample_feePlusImpact` pin the ≈1.28% / ≈0.99% / ≈0.29% decomposition in bps. Minimum liquidity: dead shares locked, supply never zero after full withdrawal. Rounding: floor vs ceil differ by exactly 1 wei; the same trade gives `k_safe ≥ k₀` and `k_ceil < k₀`; 500 tiny swaps end with the ceil pool's token1 balance strictly below the safe pool's; two fuzz mirrors (`kNonDecreasing` / `kNonIncreasing`). LP math: proportional mint `totalSupply/10`, imbalanced excess as donation, pinned removeLiquidity dust (10e18−1, 20_000e18−33). Reverts: parameter-exact `SlippageExceeded`/`InsufficientShares`/`NotAuthorized`/`FeeOutOfBounds`; selector-exact `ZeroAmount`/`InsufficientLiquidity`. Gas probes are log-only.

## Production Example

**The Ch 22 TWAP oracle reading a real V2 pair** is this chapter's production shape. The vault (Ch 20) and the liquidation engine (Ch 24-25) never ask "what's the price right now?" — they ask "what was the average over the last N seconds?", answered from the pair's `price0CumulativeLast` accumulator. The engineering content here feeds that: reserves are the raw input, spot `y/x` is the instantaneous marginal rate, and the accumulator's job is to make the *average* expensive to move. The lab's `spotPrice` is exactly what the accumulator sums; the Ch 34 manipulation surface is why `OracleRegistry` prefers the average.

A second thread is **protocol liquidity as a treasury decision**. Meridian's revenue accrues to sMER stakers via share appreciation (Ch 23); if the DAO LPs some of those reserves into a pool, fees accrue to LPs and IL is a priced, formula-known drag (5.72% on a doubling, symmetric on a halving). The `docs/cpmm-playbook.md` weekly document captures the framework — expected volume-to-depth, IL exposure per asset, the Ch 25 timelock as sole signer. Real counterparts: yearn/Curve and Convex treasury-LP patterns, and every protocol that found "we LP'd and the IL ate the yield" the hard way.

## Foundry Lab

Materialized and **compile-verified in this run** (forge 1.7.1, solc 0.8.24, cancun, optimizer 200):

- **New artifacts:** `src/IConstantProductPoolLab.sol`, `src/ConstantProductPoolLab.sol` (`AbstractConstantProductPool`, `ConstantProductPool`, `CeilOutPool`), `test/ConstantProductPoolLab.t.sol` (30 tests). All Ch 1-17 suites untouched and green.
- **Full repo suite: 276 passed / 0 failed / 6 skipped (282 total) across 25 suites** (Ch 17 baseline 246/0/6 across 24; +30 tests, +1 suite). `.gas-snapshot` regenerated to **281 rows** under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`, paired `--check` green (Ch 14 rule).
- **Gas probes (loop-amplified min-deltas, warm-up first, log-only):** swap **33,783** · `getAmountOut` **2,073** per call. The swap cost is dominated by two `SafeERC20` transfers and the packed-reserve `SLOAD`s — the math is one full-precision `mulDiv`.
- **Real findings, all kept:** (1) Ch 16 finding #1 recurred — a public `IERC20` immutable cannot satisfy `token0() returns (address)` (error 4822); fixed with the OZ `_asset`-private + explicit-getter pattern. (2) `test_removeLiquidity_reverts_insufficientShares` initially "did not revert" because the *test contract* seeded the pool and held shares — the negative needed a non-LP caller (`vm.prank(alice)`), the Ch 14 finding #3 family: the caller's state, not the function's, was the wrong assumption.

## Security Analysis

**1. Rounding direction is a security property, not a nicety (the anchor class).** One division separates a safe pool from a draining one: floor-out guarantees `k' ≥ k`; ceil-out guarantees `k' ≤ k` and hands value to traders. Balancer V2's ComposableStablePool (~$128M, Nov 2025) is the anchor — a rounding-direction flaw that let value be extracted over repeated trades. The lab's `CeilOutPool` is the same class in minimal form; full Balancer-specific treatment is Ch 26. The rule is Ch 4's: amounts the pool *pays* floor; amounts it *receives* ceil.

**2. Slippage guards are the trader's only defense against MEV.** `amountOutMin` is what stops a sandwich (Ch 34): without it a swap accepts whatever the front-runned state returns. The guard reverts `SlippageExceeded(min, out)` before any state change — cheap, and the lab pins the parameter-exact revert. It bounds how much worse than quoted a trade may be; it does not stop the sandwich, it caps the extraction.

**3. Spot price is not an oracle.** `y/x` is manipulable by moving reserves — a flash-loan-sized swap shifts it instantly (Ch 34). Reading live spot as a price feed is a known critical (Mango Markets ~$114M, Ch 11, is the cousin). Meridian's answer is the accumulator/TWAP (Ch 22); the lab keeps `spotPrice` as a math object, never a feed.

**4. The first-depositor ratio is protected by dead shares.** Without `MINIMUM_LIQUIDITY`, a 1-wei seed can be inflated away and re-seeded at an attack ratio (Ch 16's donation family). The 1,000 dead shares keep `totalSupply` permanently nonzero after initialization and substantially raise the cost of initial-liquidity manipulation; the lab pins `totalSupply == 1,000` after a full LP exit.

**5. The fee key is a trust root (Kelp DAO/Drift class).** The pool's only privileged surface is `setSwapFee`, owner-gated with the `NotAuthorized` negative pinned. A compromised fee key can set an extreme fee like 999/1000, making swaps economically unusable and redirecting value toward liquidity providers rather than traders — or 0, killing LP revenue. In production that key belongs in the Ch 25 timelock — the Kelp DAO/Drift (~$285–292M, Apr 2026) discipline: an admin key is an admin key.

## Common Mistakes

1. **Rounding the amount-out UP** — the Balancer direction; the trader receives a wei the pool must fund — a systematic value leak that accumulates across repeated trades. Floor the output.
2. **Using the AMM spot price as an oracle.** `y/x` is instant and manipulable; the fallback oracle is the TWAP accumulator (Ch 22).
3. **No slippage guard.** `amountOutMin = 0` hands the swap to the mempool; every trader-facing swap needs a bound and a `SlippageExceeded` revert.
4. **Trusting cached reserves instead of balances.** Cached reserves support pricing/oracle state, while actual balances reconcile transfers and validate state transitions — a donation is invisible until `sync`, and fee-on-transfer tokens (Ch 17) shift balances. Validation must read measured balances; balance-based reconciliation improves fee-on-transfer compatibility, but the router and integration must still be explicitly fee-on-transfer aware.
5. **Charging the fee on the output and forgetting it changes the invariant.** Input-fee keeps the pool recording the full input, so the fee is structural reserve growth; mixing the two breaks `k' ≥ k`.
6. **Skipping `MINIMUM_LIQUIDITY`.** The first depositor's ratio becomes attackable; the pool can be drained to zero shares.
7. **Adding liquidity at the wrong ratio.** The min-ratio rule means the excess is a donation — fewer shares than the token value deposited.
8. **Treating protocol LP-ing as free revenue.** IL is a formula-priced drag (5.72% on a doubling); it is a treasury decision (Ch 25), not an autopilot.

## Gas Optimization

Measured in this run (loop-amplified min-deltas, warm-up first — Ch 8 methodology):

- **`swap` ≈ 33,783 gas** warm. The curve math is one full-precision `mulDiv`; the cost is dominated by two `SafeERC20` transfers and the packed-reserve `SLOAD`s. Re-reading `balanceOf` before *and* after the transfers, or applying the fee with a second multiplication on the output, adds overhead with no safety gain.
- **`getAmountOut` ≈ 2,073 gas** per view call — one division, two reserve `SLOAD`s, interface dispatch. This is what the Ch 22 TWAP oracle pays per accumulator read; cheap enough to read in loops.
- **Design note:** the fee-on-input single-division formula is both the safe rounding direction *and* the cheap one. An "auditor-pleasing" version that computes the exact output then rounds it in a second step is strictly worse: more gas, more code, more surface for the direction to flip. Remove, then cheapen, then measure (Ch 8).

Per the locked methodology, gas probes are log-only; the `.gas-snapshot` rows are the regression gate (Ch 13), regenerated under the CI seed.

## Reading Production Source Code

1. **Uniswap V2 `UniswapV2Library.sol`** — `getAmountOut` is exactly this chapter's formula (`amountInWithFee = amountIn * 997`). Note it is a *pure library function* — the pool never computes the output itself.
2. **Uniswap V2 `UniswapV2Pair.sol`** — read `swap`: it takes explicit `amount0Out`/`amount1Out` from the caller (the router computed them), enforces the invariant via `_update` from measured balances, and guards with `lock`. The pair does **not** trust the router's quoted amounts — it validates the post-transfer balances against the invariant itself, so `getAmountOut` is a quoting helper, not the security boundary. Read `mint` (the `sqrt` first-mint and dead 1,000), `_update`, and `sync`. The lesson: math is a pure function; the pair is a guarded state machine.
3. **Uniswap V2 `UniswapV2Factory.sol`** — `createPair` derives the pair address with CREATE2 from `keccak256(abi.encodePacked(token0, token1))` and the **init code hash** (the pair runtime bytecode's keccak, burned into the factory) — Ch 5's machinery in production.
4. **The pair's TWAP fields** — `price0CumulativeLast`/`price1CumulativeLast` updated in `_update` — are the raw material for Ch 22's `OracleRegistry` fallback. Read them now.
5. **Note on V3 (Ch 19):** V3 abandons the global curve for **concentrated liquidity** — LPs choose price ranges, the effective curve is piecewise, and the math lives in `TickMath`/`SqrtPriceMath` (fixed-point √price, not `x·y`). The CPMM here is the foundation V3's tick math generalizes.

## Exercises

1. Derive the swap equation twice — `Δy = y − k/(x + Δx)` and `Δy = y·Δx/(x + Δx)` — and reconcile them. Then add the fee and derive `getAmountOut`.
2. Prove the closed-form slippage for a fee-less trade of `Δx = α·x`. What is the slippage for a 5% trade? A 20% trade? A 100% trade?
3. Confirm `getAmountOut(1e18)` against `Math.mulDiv(y, in·997, x·1000 + in·997)` and the 1.28% / 0.99% / 0.29% decomposition in `test_slippage_numericExample_feePlusImpact`.
4. Compute `k' = (x+in)(y−out)` by hand for the safe (floor) and ceil pools on the same trade; confirm `k'_safe ≥ k` and `k'_ceil < k`. Explain in one sentence why this is the entire Balancer class.
5. Run the IL example through a **halving** (ETH 2,000 → 1,000) and confirm `IL = 1 − 2√r/(1+r)` gives the same 5.72% at `r = 1/2`.
6. Read `UniswapV2Pair.sol`'s `swap` and list every line protecting the invariant (the `lock`, the balance-of sync, fee-on-input), then name the single line in `CeilOutPool` that violates the same protection.
7. Extend the lab: a third pool whose `_amountOut` floors the *input* fee instead of the output. Which direction does `k'` move, and does the pool leak?

## Weekly Project

**The CPMM playbook — `docs/cpmm-playbook.md`, added to the pending docs list:**

1. Write the chapter's three derivations (swap equation, closed-form slippage, impermanent loss) with the pinned lab numbers and the `α/(1+α)` table for 1%, 5%, 10%, 20%, 100% trades.
2. Add the Meridian integration contract: the TWAP-read pattern for Ch 22 (pair address, `price0CumulativeLast` delta over a window), the Ch 20 collateral note (why TWAP, never spot), and the treasury-LP decision framework (volume-to-depth, IL exposure, Ch 25 timelock signer) for the sMER revenue framing.
3. Confirm the suite is green: `forge test` → **276 passed / 0 failed / 6 skipped (282 total)** across 25 suites; `.gas-snapshot` regenerated under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`.
4. Protocol contract count: **still 2** (MER, gMER). No protocol source changed; the lab is LAB ONLY, and `MeridianVault.sol` arrives in Ch 20.

## Deliverables

1. `src/IConstantProductPoolLab.sol` + `src/ConstantProductPoolLab.sol` — the abstract CPMM base (reserves, fee-on-input swap, min-ratio LP shares, dead shares, `sync`, `lock`) and the safe/unsafe twins differing in one rounding line, compile-verified in-run.
2. `test/ConstantProductPoolLab.t.sol` — 30 tests all green; repo suite **276 passed / 0 failed / 6 skipped across 25 suites**.
3. Conventions locked: floor the amount-out (the pool's favor) is the CPMM rounding rule; fee on the input with full-input reserve recording; min-ratio LP minting; `MINIMUM_LIQUIDITY` dead shares; slippage guard as a parameter-exact `SlippageExceeded` revert.
4. Gas profile: swap **33,783** · `getAmountOut` **2,073** per call (warm, loop-amplified min-deltas).
5. The Ch 22 TWAP-read contract and the treasury-LP decision framework (in `docs/cpmm-playbook.md`).

## Quiz

1. Derive `out = y − k/(x + in)` from `x·y = k`. Why is constant product preferred over constant sum for an open market?
2. What is the spot price of a pool with reserves (100, 200,000)? The execution price and slippage for a fee-less 1% trade, and for a 100% trade?
3. With a 0.3% input fee, what is the effective input, and why does the recorded invariant `k' = (x + in)(y − out)` *exceed* `k`?
4. What exactly does `MINIMUM_LIQUIDITY` protect, and what does it guarantee about `totalSupply` forever?
5. Compute impermanent loss for `r = 2` and `r = 1/2` with `IL = 1 − 2√r/(1+r)`. Why are they equal?
6. The lab's two pools differ in one line. State the line, the direction each rounds, and the resulting sign of `k' − k` on a fractional trade.
7. Why does Meridian's `OracleRegistry` prefer a TWAP accumulator over a live spot price, and which Ch 22 field provides it?

**Answers:** (1) From `(x+Δx)(y−Δy)=k`, solve for `Δy`; constant product has an unbounded, continuous price response (the curve is asymptotic), while constant sum fixes the price at 1 until a reserve is exhausted. (2) Spot `= 2,000`. A 1% fee-less trade: `p_exec ≈ 1,980.2`, slippage `≈ 0.99%`. A 100% trade: `p_exec = 1,000`, slippage 50%. (3) Effective input is `in·997/1000`, but the pool records the full `in` as reserve growth, so `k' ≥ k`, strictly greater when the fee is positive — the fee drifts the invariant up. (4) It mints 1,000 dead shares to `address(0)`, so `totalSupply` never reaches zero, substantially raising the cost of first-depositor manipulation such as withdraw-and-reseed attacks. (5) `1 − 2√2/3 ≈ 5.72%` at both, because the formula is symmetric in `r` and `1/r`. (6) The `_amountOut` rounding line: the safe pool floors (pool keeps the edge, `k' ≥ k`); the ceil pool ceils (trader gains a wei, `k' < k`). (7) Spot is instantly manipulable by moving reserves (flash loans, Ch 34); the pair's `price0CumulativeLast`/`price1CumulativeLast` accumulator makes the average expensive to move — the Ch 22 fallback.

## Further Reading

- **Uniswap V2 whitepaper** (Adams, Zinsmeister, Robinson, 2020) and the **v2-core repo** (`UniswapV2Pair.sol`, `UniswapV2Library.sol`, `UniswapV2Factory.sol`): primary sources for the formulas and architecture the lab mirrors.
- **Uniswap V3 whitepaper** (2021): the concentrated-liquidity generalization Ch 19 derives; read why V3 abandons the global `x·y` curve.
- **Balancer V2 ComposableStablePool post-mortem** (Nov 2025, ~$128M): the anchor incident for the rounding-direction class; the lab's `CeilOutPool` is the minimal demonstration. Full treatment in Ch 26.
- **Ch 22** (the TWAP oracle that consumes AMM reserves), **Ch 20** (collateral valuation off the oracle layer), **Ch 34** (sandwich/MEV and liquidation arbitrage), **Ch 19** (concentrated liquidity), **Ch 25** (the timelock that holds the fee key and approves treasury LP-ing).

## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/18_AMMs_Constant_Product_REVIEW.md`):** Uniswap V2 swap ordering corrected (optimistic transfers + measured balances under lock, NOT CEI reserves-first); fee-key claim scoped (fees accrue to LPs absent a protocol-fee recipient); MINIMUM_LIQUIDITY scope; TWAP hold-window qualified; `k`-invariant vs fee-adjusted balance check separated; cached reserves vs actual balances distinguished; model/V2/lab layers labeled.

## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/18_AMMs_Constant_Product_REVIEW.md`):** Uniswap V2 swap ordering corrected (optimistic transfers + measured balances under lock, NOT CEI reserves-first); fee-key claim scoped (fees accrue to LPs absent a protocol-fee recipient); MINIMUM_LIQUIDITY scope; TWAP hold-window qualified; k-invariant vs fee-adjusted balance check separated; cached reserves vs actual balances distinguished; model/V2/lab layers labeled.
