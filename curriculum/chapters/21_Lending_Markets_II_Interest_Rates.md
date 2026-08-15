# Lending Markets II: Interest Rates

Chapter 20 built the vault that *consumes* a rate model; this chapter builds the model itself. `InterestRateModel.sol` — protocol contract #4 — implements the `IInterestRateModel` interface Ch 20 locked: a **kink (jump) curve** that maps utilization to a per-second borrow rate, plus the supply rate with the reserve factor. Along the way we derive why the curve has the shape it has, why rates are quoted per-second, how the borrow index compounds and who wins the rounding, and — with real incidents — every way a rate model can fail. The vault's `_accrueInterest` (Ch 20) is the consumer; the numbers it produces are the whole economics of Meridian: borrower cost, supplier yield, and the reserve that becomes sMER revenue in Ch 23.

## Learning Objectives

1. Define utilization `U = totalDebt / (totalDebt + cash)` (Ch 20 locked) and explain why it is the *single* state variable the whole curve is a function of.
2. Convert between APR and APY and between per-year, per-block, and per-second rates; justify Meridian's per-second WAD convention (Ch 4 locked).
3. Derive the kink (jump) curve from first principles: base rate, multiplier, kink, jump multiplier — and why a single slope cannot do the job.
4. Derive the supply rate `r_supply = r_borrow · U · (1 − reserveFactor)`.
5. Explain index-based accrual, the ceil rounding direction, and the compounding premium — the APR²/2 gap between linear and frequent-compounding yields (Ch 4) — with numbers.
6. Implement `InterestRateModel.sol` with immutable parameters and the governance swap path (`setInterestRateModel`).
7. Analyze rate-model failure classes against real incidents (Anchor, Cream, Balancer V2, Kelp DAO/Drift).
8. Verify the model against the vault: utilization feeds the exact rate, debt grows on the curve, the reserve accrues.

## Prerequisites

- **Chapter 20** (Lending Markets I) — the utilization definition, the borrow index, the vault error catalog, and the `IInterestRateModel` ABI this chapter implements.
- **Chapter 4** (Integer Arithmetic & Units) — WAD, the rounding policy (floor user-received / ceil user-paid), per-second linear accrual, the r²/2 compounding premium.
- **Chapter 16** (ERC4626 Vaults) — the "never create or destroy value" discipline; the rate model must obey the same invariant as share math.
- Supporting: **Ch 8** (immutables over storage — the model's parameters are immutable), **Ch 10** (parameter-exact `vm.expectRevert`), **Ch 14** (custom errors in I-prefix interfaces), **Ch 17** (the listing gate that keeps `balanceOf` meaningful).
- Foreshadowed: **Ch 22** (`OracleRegistry` — prices feed the health factor, not the rate), **Ch 23** (reserve → sMER revenue), **Ch 25** (the timelock that holds the curve's governance), **Ch 26** (the rounding-failure class), **Ch 31** (why per-second rates port to L2s).

## Theory

### Interest is the price of time and risk

A lending market is a market like any other, and the interest rate is its price. A borrower pays for the right to use capital now and return it later; a lender earns for deferring consumption and absorbing default risk. The rate is what clears the market: when demand for borrowed capital rises, the rate rises, which both incentivizes new supply and discourages marginal borrowing. The rate curve is the protocol's *thermostat*.

That thermostat has to be automatic, because the protocol cannot re-price by hand. If the rate does not respond to utilization, the market has no thermostat at all — and the canonical example of that failure is **Anchor Protocol (May 2022)**. Anchor paid a fixed ~19.5–20% APY on UST deposits regardless of how much anyone was borrowing; the gap between what borrowers paid and what depositors were promised came out of a "yield reserve." When the reserve ran low and the fixed rate had to fall, the peg broke; the LUNA/UST collapse erased roughly $60B of market value. The lesson is not "20% was too high" — it is that a rate decoupled from utilization is a marketing number, not a market mechanism. Every design decision in this chapter is an answer to Anchor.

### Utilization: the one state variable

The vault (Ch 20) computes utilization as:

```
U = totalDebt / (totalDebt + cash)        (WAD; cash = lendable debt-token balance)
```

`totalDebt` is all outstanding borrows; `cash` is what is still lendable (`balanceOf(vault) − reserve`, Ch 20 `_idleCash`). Two boundary states matter:

- `U = 0` — nobody is borrowing. The market is idle; the rate should be at its floor (the base rate), enough to make capital available but not so high as to scare off the first borrower.
- `U → 1e18` — nearly all cash is lent out. Withdrawals and new borrows are about to become impossible (Ch 20's `InsufficientLiquidity`). The rate must be punishing, because the marginal lender who supplies into a 95%-utilized market is taking withdrawal risk the moment they deposit.

Utilization is an *equilibrium*: it is pushed up by borrow demand and pulled down by supply. The curve's job is to translate that single scalar into the price of borrowing — cheap when the market is slack, expensive when it is tight, brutal at the edge.

### The rate axis: per-second WAD, APR vs APY

Rates can be quoted per-year, per-block, or per-second. **Compound v2** quotes per-block: `ratePerBlock = ratePerYear / 2,102,400`, a constant that assumes 15-second blocks. That assumption is fragile: post-Merge Ethereum runs 12-second slots, and L2s (Ch 29–31) run cadences from ~250ms to batch-based — a per-block model couples interest to a consensus property the protocol does not control, and a wrong block-time constant misprices every second of accrual. **Aave v2** (Dec 2020) moved to per-second accrual (RAY precision), and v3 kept it. Meridian locks per-second WAD (Ch 4): the rate is a WAD fraction of 100% *per second*.

Two conventions must be kept apart:

- **APR** is linear: `value(t) = 1 + r·t`. Meridian quotes rates as *linear per-second APR* — `r_sec = APR / 31,536,000` — and every accrual applies exactly that: `index' = index · (1 + r_sec·dt)`, linear over the elapsed time since the last accrual.
- **APY** is what repeated accruals compound to. Because the vault accrues on interaction, not on a timer, the effective annual yield depends on how often accruals land: one accrual at year end realizes `≈ 1 + APR`; `N` equal accruals realize `(1 + APR/N)^N − 1`; per-second accrual realizes `(1 + r_sec)^31,536,000 − 1 ≈ APR + APR²/2`.

The `APR²/2` term is the **compounding premium** — the gap between the simple linear rate and frequent discrete compounding, derived in Mathematical Foundations. It is small at lending rates (≈0.245 percentage points at 7% APR at per-second granularity), and it is an artifact of accrual frequency, not a deliberate subsidy: the vault charges the linear rate per elapsed second, and the premium only materializes when interactions compound the index repeatedly.

### The kink model: derivation

The design problem: what shape should `r(U)` have? Four requirements:

1. **Non-decreasing** — more utilization must never be cheaper than less.
2. **Low at low utilization** — idle markets need cheap capital to attract borrowers.
3. **Brutal near 1e18** — the last cash must be rationed, and the marginal lender compensated for withdrawal risk.
4. **Continuous** — a rate jump at some utilization creates an arbitrage between adjacent states and a governance-bait parameter. (The curve is continuous but *not differentiable* at the kink — the slope steps from `multiplier` to `jumpMultiplier` there by design.)
5. **Governable** — a handful of parameters, each with an obvious meaning.

The minimal shape is a straight line `r(U) = base + multiplier·U`. It fails requirement 3: a slope steep enough to make `U = 1e18` punishing makes `U = 50%` prohibitively expensive, killing the normal operating band. One slope cannot serve both the cruising altitude and the emergency brake.

The answer — **Compound's JumpRateModel (2019)** — is two slopes joined at a **kink**:

```
U ≤ kink:  r(U) = base + multiplier·U
U > kink:  r(U) = base + multiplier·kink + jumpMultiplier·(U − kink)
```

Each parameter has a job:

- **base** — the cost of capital at zero demand: the risk-free rate plus the protocol's risk premium. Even with no borrowers, capital has an opportunity cost.
- **multiplier** — how fast the market heats up inside the normal operating band. This is the *competition* slope: it tracks supply and demand.
- **kink** — the operating ceiling, conventionally ~80%. Above it, cash is scarce and every additional unit of utilization is a withdrawal-risk event. The 20% idle buffer is what keeps withdrawals possible without liquidations cascading; the curve must make consuming the buffer expensive.
- **jumpMultiplier** — the emergency brake. It applies only to the utilization above the kink, so it can be extreme without touching the normal band.

**Aave v3** uses the same shape under a different name: "optimal utilization" (typically 80–90%, per-asset, governance-set), with a gentle `slope1` below it and a much steeper `slope2` above. The shape is consensus across the two largest lending protocols; the parameters are per-asset governance decisions, not laws.

Meridian's example parameters (EXAMPLE values, set at deployment by governance):

```
base = 2% APR, multiplier = 10% APR, jumpMultiplier = 100% APR, kink = 80%, reserveFactor = 20%
```

which produces the rate table (derived precisely below): `r(0%) = 2%`, `r(50%) = 7%`, `r(80%) = 10%`, `r(100%) = 30%` APR.

### The supply rate and the reserve factor

Interest flows one way: borrowers pay, and the pool distributes. In one second, borrowers pay `r_borrow · D` (in debt-token units), where `D = totalDebt`. That interest accrues to the pool and is shared pro-rata over *all* supplied capital — the entire lendable supply `D + C`, including the portion that is currently borrowed out. So the per-unit-of-supplied-capital yield is:

```
interest = r_borrow · D
total supplied = D + C
r_supply = r_borrow · D/(D+C) = r_borrow · U
```

because `U = D/(D+C)`; `r_supply` stays bounded in `[0, r_b]`. This is the standard result — Aave and Compound both distribute this way: interest accrues to the pool and is shared pro-rata over all supply.

> **Common mistake:** deriving `r_supply = r_b · D/C = r_b · U/(1−U)` by counting only idle cash `C` as "supplied." That diverges as `U → 1e18` — suppliers cannot earn infinite yield. The pool's supplier base is `D + C`, not `C`: the borrowed-out portion is supplied capital too.

The **reserve factor** takes a protocol cut *before* distribution (Ch 20 locked):

```
r_supply = r_borrow · U · (1 − reserveFactor)
```

With the example parameters at the kink: `10% · 0.8 · 0.8 = 6.4%` APR to suppliers; the 3.6-point gap is protocol revenue, which flows to the reserve and from there to sMER stakers (Ch 23). The reserve is also the protocol's skin in the game — it backstops bad debt before suppliers do (Ch 24).

### The borrow index: compounding premium and discrete-accrual behavior

Ch 20 recap: a user's debt is `principal · borrowIndex / interestIndex`; the global `borrowIndex` starts at `1e18` and every accrual updates it:

```
borrowIndex' = borrowIndex + ceil(borrowIndex · r_sec · dt / 1e18)      (Ch 20, line 449)
```

Each accrual applies `(1 + r_sec·dt)` — **linear over the elapsed time since the last accrual**, not `(1 + r_sec)^dt`. The `+1·borrowIndex` factor multiplies the index by that per-step factor, so across several accruals a user's debt grows by the product `Π(1 + r_sec·dt_i) ≈ 1 + r_sec·Δt` — the linear APR over the window, to first order, no matter how many other users interact or how the window is sliced. That is what makes accrual O(1) instead of O(users): debt grows with elapsed time, not with per-user bookkeeping. (The second-order difference between one large accrual and many small ones is the compounding premium, quantified in Mathematical Foundations.) The `ceil` is the locked rounding direction: borrowers pay the ceil, so the reserve and the supplier share can never come up short (Ch 4/16 policy, and the Ch 20 vault NatSpec states it verbatim).

Why is `(1 + r·dt)` the right step rather than `e^(r·dt)`? Per-second granularity makes `r·dt` tiny between accruals — even at the 30% APR maximum, `r_sec·1s ≈ 1e-8`. The step `(1 + r·dt)` is *exact* for the discrete world the protocol actually lives in: it charges precisely `r_sec` per elapsed second. Compared to continuous compounding `e^(r·dt)`, each step falls short by `(r·dt)²/2`; accumulated over a year of per-second steps that is `APR²/(2N)` at `N = 31,536,000` — ≈7.8e-11 relative at 7% APR, far below wei granularity. The `APR²/2` that shows up in the APY math is a different quantity: the compounding premium of frequent discrete accrual over the simple rate (derived next), not a shortfall against continuous compounding.

## Mathematical Foundations

### Conversions

Seconds per year: `31,536,000` (365 days). Linear APR → per-second WAD:

```
r_sec = APR_wad / 31,536,000
```

Example: 10% APR → `r_sec = 1e17 / 31,536,000 = 3,170,979,198` WAD wei (≈ 3.171e-9 per second).

Effective yield depends on the accrual schedule — three reference models:

| Model | One-year factor |
|---|---|
| Simple / one-shot linear (a single accrual at year end) | `1 + r` |
| N equal accruals | `(1 + r/N)^N` |
| Continuous compounding | `e^r` |

The middle row expands binomially — `(1 + x)^N` with `x = r/N`:

```
(1 + r/N)^N = 1 + r + N(N−1)/2 · (r/N)² + … ≈ 1 + r + r²/2
```

so `N` equal accruals realize `APY ≈ APR + APR²/2` — the **compounding premium** over the simple rate — and as `N → ∞` the factor approaches `e^r`. Thus 7% APR → ≈ 7.245% APY at per-second granularity (`e^0.07 − 1 = 7.251%` continuous); 30% APR → ≈ 34.5% APY (`e^0.3 − 1 = 34.99%` continuous — the higher-order terms are the rest). Meridian's realized yield sits on this spectrum, set by the vault's interaction-driven accrual: one end-of-year accrual realizes the `1 + r` row exactly, and frequent interactions drift toward the compounding rows. The protocol *guarantees* the linear row — `r_sec · dt` per elapsed second — and the compounding premium is what repeated accruals add on top.

Legacy per-block conversion (Compound v2): `r_block = r_year / 2,102,400`, hard-coding 15s blocks. On a 12s post-Merge chain the same constant understates the annual rate by 25% (`15/12 − 1`); on an L2 with 1s blocks it understates by 15×. Per-second is cadence-agnostic — one more reason it is locked.

### The kink curve, precisely (WAD)

```
U ≤ kink:  r(U) = base + floor(U · multiplier / 1e18)
U > kink:  r(U) = base + floor(kink · multiplier / 1e18) + floor((U − kink) · jumpMultiplier / 1e18)
```

**Continuity at the kink** falls out of the formula: at `U = kink`, both branches evaluate to `base + kink·multiplier` (the jump term is zero). The function is continuous but *not differentiable* at the kink — the slope steps from `multiplier` to `jumpMultiplier`, which is the design intent: a smooth value, an abrupt slope. **Monotonicity** holds because every parameter is non-negative; the curve is steeper above the kink iff `jumpMultiplier ≥ multiplier`, which a sane deployment enforces at governance-review time (the constructor validates ranges, not ordering — see Security Analysis).

Example curve (base 2%, multiplier 10%, jump 100%, kink 80% — all APR):

| U | r_borrow (APR) | r_supply @ RF 20% (APR) |
|---|----------------|--------------------------|
| 0% | 2% | 0% |
| 50% | 7% | 2.8% |
| 80% (kink) | 10% | 6.4% |
| 90% | 12% | 8.64% |
| 100% | 30% | 24% |

The last row is the brake: at full utilization the borrow rate triples relative to the kink, and the supply rate is still capped below it — suppliers cannot earn more than borrowers pay.

### Supply rate, precisely

```
r_supply(U) = floor( r_borrow(U) · floor( U · (10_000 − reserveFactorBps) / 10_000 ) / 1e18 )
```

Floor, not ceil: the supply rate is supplier-received (Ch 4 policy). Chained `mulDiv`s keep full intermediate precision.

### Index update and debt growth

The vault accrues `interest = ceil(totalDebt · r_sec · dt / 1e18)` and `borrowIndex += ceil(borrowIndex · r_sec · dt / 1e18)` (Ch 20 lines 443–449). Worked example — borrow 5,000 USDC at `U = 50%` (rate 7% APR), one year of silence, then one accrual:

```
interest    = 5,000 · 0.07                  = 350.00 USDC        (exact)
totalDebt   = 5,000 + 350                   = 5,350.00 USDC
reserve     = 350 · 20%                     = 70.00 USDC
borrowIndex = 1e18 + 1e18·0.07              = 1.07e18            (exact)
debtOf      = principal · index/interestIndex = 5,000 · 1.07     = 5,350.00 USDC
```

All four values land exactly — no dust — because `7e16/1e18` divides cleanly. These are the *idealized* numbers, computed as if 7% APR were applied as one exact factor. The real model quantizes rates to per-second WAD integers, so the live rate at `U = 50%` is `floor(7e16/31,536,000) = 2,219,685,438` WAD wei — the base and multiplier floors cancel at this utilization, so the floored sum lands exactly on the floored ideal (the real quotient is `2,219,685,438.8635…`, and the integer is its floor). The one-year interest factor is `2,219,685,438 × 31,536,000 = 69,999,999,972,768,000`, which sits `27,232,000` WAD units below the ideal `7e16` — ≈3.89e-10 relative, below the wei granularity of a 6-decimal debt — so the final USDC values round to the same 6-decimal display as the idealized ones. The measured one-year accrual is therefore exactly `5,350.000000` USDC debt, `70.000000` reserve, index `1.06999999972768e18`. The integration test asserts exact equality against the model's *own* rate (self-consistent wiring), and the per-second quantization is documented as a real-but-negligible effect. If the same year is split into two six-month accruals, the index compounds: `5,000 · (1.035)² = 5,356.125` — the extra 6.125 USDC (0.1225%) is the two-accrual compounding premium (the `N = 2` case, `APR²/4` — a member of the `APR²/2` family), now visible as a number. The vault's tests pin both forms (self-consistent one-shot linear, banded two-step compounding).

### The no-cash asymptote

At `U = 1e18` the market is frozen by construction: `cash = 0`, so `withdrawCollateral` (HF permitting) is the only exit, borrows revert with `InsufficientLiquidity`, and repayments are the only thing that thaws it. The jump curve's job at that point is to make *staying* at 100% painful — the 30% APR is the market's way of saying "pay down or get liquidated as the index eats your health factor." This is why the kink exists at all: without the jump, a market could idle at 99% utilization at a 12% rate, and the last lender in would be trapped at a rate that does not reflect their risk.

## Production Implementation

### `InterestRateModel.sol` — protocol contract #4

Design decisions, each locked by an earlier chapter:

- **All parameters immutable** (Ch 8: immutables over storage): the model is a pure function of utilization. Changing a curve = deploy a new model and call the vault's `setInterestRateModel`, which *accrues at the old model first* (Ch 20, line 385) so pending interest is locked before the curve changes. Zero storage means zero SLOADs in the hot path.
- **Per-second WAD rates** on the Ch 20 interface; utilization is computed by the vault and read, never re-derived (the interface docstring is explicit).
- **Custom errors in the interface** (Ch 2/14 convention): the two constructor-validation errors are added *additively* to `IInterestRateModel` — existing function ABIs untouched, same precedent as Ch 20's additive `getPrice` on `IMeridianOracle`.
- **Full-precision `Math.mulDiv`** (OZ v5; Ch 4 lab-verified) for every multiply-divide.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInterestRateModel} from "./IInterestRateModel.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Meridian kink (jump) interest rate model
/// @notice Protocol contract #4. Implements the Compound-style jump curve on
///         the Ch 20 interface: per-second WAD rates, utilization computed by
///         the vault (`totalDebt / (totalDebt + cash)`, Ch 20 locked). All
///         curve parameters are IMMUTABLE — to change a curve, governance
///         deploys a new model and swaps it via the vault's
///         `setInterestRateModel` (which accrues at the old model first).
///         Parameter values in this chapter's tests are EXAMPLE values; real
///         ones are a governance vote (Ch 25 timelock holds the role).
/// @dev Curve (per-second WAD):
///         U <= kink:  r = base + U·multiplier
///         U >  kink:  r = base + kink·multiplier + (U − kink)·jumpMultiplier
///      Continuous at the kink by construction (both branches equal
///      `base + kink·multiplier` at U == kink). Rates are quoted as LINEAR
///      per-second APR; the vault's per-second index compounding turns them
///      into effective APY with the Ch 4 r²/2 compounding premium.
///      Rounding: borrowRate floors (rate is quoted, not paid directly);
///      supplyRate floors (supplier-received, Ch 4 policy); the vault's index
///      accrual ceils (borrower-paid, Ch 20 line 449).
contract InterestRateModel is IInterestRateModel {
    /// @notice Per-second base borrow rate at zero utilization (WAD).
    uint256 public immutable override baseRatePerSecond;
    /// @notice Per-second slope between zero and the kink (WAD).
    uint256 public immutable override multiplierPerSecond;
    /// @notice Per-second slope above the kink — the "jump" (WAD).
    uint256 public immutable override jumpMultiplierPerSecond;
    /// @notice Kink utilization, WAD (1e18 == 100%).
    uint256 public immutable override kink;
    /// @notice Protocol share of interest, basis points (e.g. 2000 == 20%).
    uint64 public immutable reserveFactorBps;

    constructor(
        uint256 baseRatePerSecond_,
        uint256 multiplierPerSecond_,
        uint256 jumpMultiplierPerSecond_,
        uint256 kink_,
        uint64 reserveFactorBps_
    ) {
        if (kink_ > 1e18) revert InvalidKink(kink_);
        if (reserveFactorBps_ > 10_000) revert InvalidReserveFactor(reserveFactorBps_);
        baseRatePerSecond = baseRatePerSecond_;
        multiplierPerSecond = multiplierPerSecond_;
        jumpMultiplierPerSecond = jumpMultiplierPerSecond_;
        kink = kink_;
        reserveFactorBps = reserveFactorBps_;
    }

    /// @inheritdoc IInterestRateModel
    /// @dev `public` (not `external`) because `supplyRate` calls it internally
    ///      — the Ch 4/5 external-called-internally bug class, fixed the same way.
    function borrowRate(uint256 utilization) public view override returns (uint256) {
        if (utilization <= kink) {
            return baseRatePerSecond + Math.mulDiv(utilization, multiplierPerSecond, 1e18);
        }
        return baseRatePerSecond
            + Math.mulDiv(kink, multiplierPerSecond, 1e18)
            + Math.mulDiv(utilization - kink, jumpMultiplierPerSecond, 1e18);
    }

    /// @inheritdoc IInterestRateModel
    function supplyRate(uint256 utilization) external view override returns (uint256) {
        // r_supply = r_borrow · U · (1 − reserveFactor). Floors: supplier-received.
        uint256 borrow = borrowRate(utilization);
        uint256 netShare = Math.mulDiv(10_000 - reserveFactorBps, utilization, 10_000);
        return Math.mulDiv(borrow, netShare, 1e18);
    }
}
```

Gas shape: `borrowRate` below the kink is one `mulDiv` (Ch 4 lab baseline ~1,057) plus two `PUSH`/`IMMUTABLE` loads — no SLOADs; above the kink it is two `mulDiv`s. Measured in-run (loop-amplified min-deltas, warm call included): **1,107 gas below the kink, 1,498 above** — a pure-function cost the vault pays once per touching transaction.

### The test suite: `InterestRateModel.t.sol`

- **Constructor:** parameters read back; `kink = 1e18` allowed; `kink > 1e18` → `InvalidKink`; `reserveFactorBps = 10_000` allowed (supply = 0); `> 10_000` → `InvalidReserveFactor`.
- **Curve pins (example params, per-second WAD):** `r(0) = BASE_PS` (2% APR); `r(5e17) = BASE_PS + floor(5e17·MULT_PS/1e18)` (7% APR); `r(8e17) = BASE_PS + floor(8e17·MULT_PS/1e18)` (10% APR); `r(1e18) = BASE_PS + floor(8e17·MULT_PS/1e18) + floor(2e17·JUMP_PS/1e18)` (30% APR); each also sanity-checked against its ideal APR within 0.01% (per-second quantization); continuity at the kink via both branches.
- **Fuzz (bound to `[0, 1e18]`):** monotonic non-decreasing; never below base; matches the closed-form piecewise formula at full range.
- **Supply rate:** at the kink = `6.4e16` (6.4% APR); zero at `U = 0`; zero at RF = 10,000; `supplyRate ≤ borrowRate` at full range.
- **Vault integration (real model + Ch 20 mocks):** deposit collateral (mETH @ 2000e8), supply debt liquidity, borrow 5,000 mUSDC at `U = 50%`; one-year warp + accrual trigger → `totalDebt`, `reserve`, `borrowIndex`, and `debtOf` all match the values computed from the model's own (per-second-quantized) rate — measured EXACTLY `5,350e6` debt / `70e6` reserve / index `1.06999999972768e18` (the interest factor `69,999,999,972,768,000` sits 27,232,000 WAD units below ideal `7e16`, ≈3.89e-10 relative — below wei granularity; `r(50%)` itself equals `floor(7e16/31,536,000) = 2,219,685,438` exactly); two six-month accruals → debt strictly above the one-shot linear value (compounding) and inside a band; `model.borrowRate(vault.utilization())` equals the pinned 7% APR at `U = 50%`; model swap via `setInterestRateModel` as admin; non-privileged swap reverts `AccessControlUnauthorizedAccount`.
- **Gas probes:** `borrowRate` below/above kink (loop-amplified min-deltas, warm-up first — Ch 8/9 standing rules).

The integration tests reuse the Ch 20 harness untouched — the vault's `FixedRateInterestRateModel` mock is replaced by the real model in a fresh vault, proving the interface contract both sides were built against.

## Security Analysis

### Failure class 1: rate decoupled from utilization — Anchor (May 2022, ~$60B)

A fixed ~19.5–20% deposit APY on UST, paid regardless of borrow demand, subsidized by a yield reserve that was auditable but finite. The rate was set by marketing, not by the market; when the subsidy ran out, the rate had to move and the peg did not survive the move. Meridian's answer is the whole chapter: every rate is a pure function of utilization, and there is no subsidy account anywhere in the model — the reserve factor only *skims* interest, it never *creates* it.

### Failure class 2: garbage-in — utilization and price integrity

The model is only as good as the numbers fed to it. Two poisoning vectors:

- **Utilization from `balanceOf` instead of internal accounting.** A donation to the vault inflates the token balance, depressing `U` and cheapening *all* borrowing — the Ch 16 donation class redirected at the rate model. Ch 20's `_idleCash` (`balance − reserve`) is the answer, and the Ch 17 listing gate (no fee-on-transfer, no rebase, no hooks) is what keeps `balanceOf` meaningful at all.
- **Collateral priced at a manipulable share rate.** **Cream Finance (Oct 2021, ~$130M):** collateral (Yearn vault shares) was valued at a share price the attacker could inflate with flash loans, then borrowed against at face value. The rate model dutifully priced loans against collateral worth a fraction of its quoted value. Meridian's answer is Ch 22's `OracleRegistry` — Chainlink primary, TWAP fallback, and *never* a share-derived price.

### Failure class 3: rounding direction — the Balancer V2 anchor

The index must ceil (locked). A floor index silently mints free value on every accrual — a few wei per user per interaction, which is exactly the rounding-direction leakage class that **Balancer V2's ComposableStablePool (Nov 2025, ~$128M)** demonstrated at scale (full treatment Ch 26). The vault's `Ceil` on interest, index, and reserve (Ch 20 lines 443–449) is this chapter's contract with that class.

### Failure class 4: cadence-coupled rates

A per-block model with a 15s constant on a 12s chain underprices borrowing by ~25% annually; on an L2 with 1s blocks the error is an order of magnitude worse. Per-second accrual (locked) is cadence-agnostic and ports to any post-Fusaka L2 (Ch 29–31) without a parameter change.

### Failure class 5: the curve as privileged state

Curve parameters are *governance keys*. A compromised admin (the **Kelp DAO/Drift Apr 2026, ~$285–292M** class, carried from Ch 8–20) could set `base = jump = 0` and turn the market into free money for borrowers, or set rates at 100%+ and force mass liquidations. Two structural mitigations, both locked: the model's parameters are **immutable** (a governance attack must deploy and swap a *new contract* through `setInterestRateModel`, which first accrues at the honest model), and the role that can do it sits in the Ch 25 timelock. The one thing the constructor does *not* enforce — `jumpMultiplier ≥ multiplier`, so the curve stays convex — is a deploy-time governance review item, noted in the deployment checklist, because an ordering check is a policy choice, not a range error.

## Weekly Project

- `docs/interest-rate-model.md` — the curve spec with the example parameter table, the swap procedure (`setInterestRateModel` semantics: accrual-first, zero-address guard), and the deployment checklist (params reviewed for convexity, model wired into the vault, `.gas-snapshot` regenerated).
- `docs/gas-budget.md` extension — the per-accrual cost of the rate read (one `borrowRate` view call per transaction that touches the market) and the immutable-vs-storage SLOAD math (Ch 8) that justifies it.
- On disk this run: `src/InterestRateModel.sol`, `src/IInterestRateModel.sol` (additive errors), `test/InterestRateModel.t.sol` — compile-verified, suite green, snapshot regenerated (numbers in the Ledger Update).

## Deliverables

1. `src/IInterestRateModel.sol` — extended additively with `InvalidKink(uint256)` and `InvalidReserveFactor(uint64)` (constructor-time errors; existing ABIs untouched).
2. `src/InterestRateModel.sol` — the kink/jump model with immutable params, per-second WAD, OZ `Math.mulDiv`. **Protocol contract #4.**
3. `test/InterestRateModel.t.sol` — constructor validation, curve pins, monotonicity/closed-form fuzz, supply-rate pins, vault integration (self-consistent one-year accrual, compounding bonus, utilization→rate wiring, governance swap + negative test), gas probes.
4. Full suite green; `.gas-snapshot` regenerated under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`.
5. Gas profile: `borrowRate` below/above kink (measured in-run; see Ledger Update).
6. Conventions locked: linear per-second APR (r_sec = APR/31,536,000); each accrual applies `(1 + r_sec·dt)` — effective APY depends on the accrual schedule (`N` equal accruals → `(1 + APR/N)^N − 1`, compounding premium ≈ APR²/2 in the frequent-accrual limit); model params immutable, curve changes via governance swap; `borrowRate` floors, `supplyRate` floors, vault index ceils.

## Quiz

1. Convert 10% APR to a per-second WAD rate. What is the effective yield after a year with a single end-of-year accrual, and after a year of per-second accruals? Which one does the vault guarantee, and what is the compounding premium?
2. Why does a single-slope model fail? Name the requirement it cannot satisfy.
3. Derive the supply rate at the kink for base 2%, multiplier 10%, jump 100%, kink 80%, reserve factor 20%.
4. Why must the borrow index round up? Which incident class does a floor index belong to?
5. What does `U = 1e18` mean operationally, and what does the jump multiplier do about it?
6. Why per-second instead of per-block? Name the legacy constant and its failure mode on a 12s chain and on an L2.
7. Classify each failure: a fixed 20% deposit APY regardless of utilization; utilization computed from `balanceOf`; collateral priced at a manipulable share rate.
8. Why are the model's parameters immutable, and what is the governance path to a new curve? What happens to pending interest on a swap?
9. If governance set base = multiplier = jump = 0, what breaks, and which 2026 incident class does that belong to?

**Answers:** (1) `1e17/31,536,000 = 3,170,979,198` WAD wei; a single end-of-year accrual realizes ≈ 10% (the linear APR); a year of per-second accruals realizes ≈ 10% + 0.5% = 10.5% (`(1 + 0.1/N)^N − 1` at `N = 31,536,000`, continuous limit `e^0.1 − 1 = 10.517%`); the `APR²/2 = 0.5%` is the compounding premium of frequent accrual over the simple rate — the vault guarantees only the linear step `r_sec · dt`, so the premium materializes only when interactions compound the index repeatedly. (2) One slope cannot be both gentle in the normal band and brutal at 100% utilization — requirement 3 (rationing the last cash) forces a slope that kills the cruising band. (3) `r_b(80%) = 2 + 8 = 10%`; `r_s = 10% · 0.8 · 0.8 = 6.4%` APR. (4) A floor index leaks value per accrual to borrowers at suppliers'/reserve's expense — the rounding-direction class of Balancer V2 (~$128M, Nov 2025). (5) No cash: borrows revert (`InsufficientLiquidity`), withdrawals impossible; the 30% rate is the brake that makes staying at 100% painful. (6) Compound v2's `2,102,400` blocks/year assumes 15s blocks; on 12s post-Merge the rate is understated ~25%/yr, and on fast L2s the error explodes; per-second is cadence-agnostic. (7) Anchor (May 2022, ~$60B) — fixed-rate trap; donation-inflated `balanceOf` — the Ch 16 donation class hitting the rate model; Cream (Oct 2021, ~$130M) — share-price-collateral blindness. (8) Immutable params keep the hot path SLOAD-free and force curve changes through `setInterestRateModel`, which accrues pending interest at the old model first; the timelock (Ch 25) holds the role. (9) Borrowing becomes free — the rate model stops being a thermostat; a zero-rate market invites unlimited leverage against the book; the class is compromised-governance keys (Kelp DAO/Drift, ~$285–292M, Apr 2026).

## Further Reading

- **Compound v2 `JumpRateModel`** (2019) — the origin of the kink curve; the parameter semantics this chapter ports.
- **Aave v2/v3 interest-rate strategy docs** — "optimal utilization" + slope1/slope2; per-second RAY accrual as the modern convention.
- **Anchor Protocol post-mortem (May 2022)** — the fixed-rate trap and the yield-reserve failure mode.
- **Cream Finance post-mortem (Oct 2021, ~$130M)** — collateral priced at a manipulable share rate; the rate model pricing risk it cannot see.
- **Balancer V2 ComposableStablePool (Nov 2025, ~$128M)** — the rounding-direction anchor; full treatment Ch 26.
- **Kelp DAO / Drift (Apr 2026, ~$285–292M, admin keys)** — curve parameters as privileged state; full treatment Ch 27.
- **Ch 20** (`MeridianVault._accrueInterest`, the consumer), **Ch 22** (`OracleRegistry`), **Ch 23** (reserve → sMER), **Ch 25** (timelock governance), **Ch 26** (rounding class).

