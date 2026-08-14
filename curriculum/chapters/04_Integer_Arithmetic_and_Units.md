# Integer Arithmetic & Units

The EVM has no fractions and no floating point — only 256-bit integers. Every ratio, rate, and price in a lending protocol is therefore a rounding-policy decision disguised as arithmetic. Get the direction wrong and you have invented a value-extraction vulnerability. This chapter derives the rules once so the vault code (Ch 20–23) inherits them without rediscovery.

### Contents

1. [Learning Objectives](#learning-objectives)
2. [Why Integers — The EVM Has No Fractions](#why-integers--the-evm-has-no-fractions)
3. The Unit Ladder — wei, gwei, ether, decimals
4. [Modular Arithmetic — uint256 is ℤ/2²⁵⁶ℤ](#modular-arithmetic--uint256-is-z2256z)
5. [Division Truncates — Rounding is Policy](#division-truncates--rounding-is-policy)
6. [Phantom Overflow & mulDiv](#phantom-overflow--muldiv)
7. [Fixed Point — WAD & RAY](#fixed-point--wad--ray)
8. [Per-Second Rates — Linear vs Compound](#per-second-rates--linear-vs-compound)
9. [Mathematical Foundations](#mathematical-foundations)
10. [Locked Conventions](#locked-conventions--chapter-04-additions)
11. [Code Walkthrough — ArithProbe.sol](#code-walkthrough--arithprobesol)
12. [Production References](#production-references)
13. [Security Analysis](#security-analysis--arithmetic-vulnerability-classes)
14. [Gas Optimization](#gas-optimization)
15. [Common Mistakes](#common-mistakes)
16. [Exercises & Weekly Project](#exercises--weekly-project)
17. [Quiz](#quiz)
18. [Further Reading](#further-reading)

## Learning Objectives

- **Obj 01** —  Explain why the EVM computes money as integers and derive the unit ladder (wei → gwei → ether) as pure scaling, not separate types.
- **Obj 02** —  Prove `uint256` arithmetic is modular mod 2²⁵⁶, state exactly what Solidity 0.8.x's checked math inserts (`Panic 0x11`), and know the incident history that made it the default.
- **Obj 03** —  Derive and implement overflow-safe `mulDiv` (512-bit intermediate) and distinguish it from naive `(a*b)/c`, which suffers the phantom-overflow failure class.
- **Obj 04** —  Treat rounding direction as a policy decision: derive floor vs ceil division, the overflow-safe `ceilDiv` form, and the protocol-favorable convention Meridian locks.
- **Obj 05** —  Work fluently in fixed-point: WAD (1e18) for amounts, RAY (1e27) for rates, per-second linear accrual, and decimal normalization via `toWad`/`fromWad`.
- **Obj 06** —  Read and apply the production references: OZ `Math.mulDiv`, Aave V3 `MathUtils`, MakerDAO DS-Math, Uniswap V3 `FullMath`.

## Why Integers — The EVM Has No Fractions

Chapter 01 established the execution substrate: a stack machine of 256-bit words. There is no floating-point unit, no `double`, no `NaN`. Every arithmetic opcode — `ADD`, `SUB`, `MUL`, `DIV`, `MOD` — operates on 256-bit integers and nothing else. This is not an accident.

> **The accounting identity that motivates everything** —  
>  An EVM ledger represents $0.10 as 100,000,000,000,000,000 wei — a single integer — so the accounting identity `sum(in) == sum(out)` is a theorem about integers, not a rounding convention. Floating-point arithmetic cannot provide this guarantee (see IEEE 754 accumulation errors). Integer arithmetic can, if and only if you control rounding direction explicitly.

The first rule of protocol math follows: **all money is an integer count of the smallest unit.** A "fractional" amount like 0.5 ETH is stored as 5 × 10¹⁷ wei. Division is the only operation that loses information — it truncates — which is why every division in a protocol is a rounding-policy decision, the subject of §Rounding.

## The Unit Ladder — wei, gwei, ether, token decimals

Ether denominations are pure scaling of one base unit. In Solidity, `1 ether`, `1 gwei`, `1 wei` are compile-time constants — literal sugar resolved at compile time. They are not types. Two values of different "denomination" are the same `uint256`.

### Token decimals extend the same ladder per-asset

USDC uses 6 decimals, WBTC 8, MER will use 18 (locked in Ch 14). The cross-token problem is real: 1 "unit" of USDC (10⁶ raw) and 1 wei of MER (10¹⁸ raw) are vastly different values. Any protocol that prices, lends, or collateralizes multiple tokens must normalize to a single internal scale.

**1. Variable named `amountEther` that holds wei.** The denomination is in the name, not the type. A reviewer reads `amountEther` and assumes it holds 1e18-scaled values. It does not. Every amount variable in Meridian is suffixed with its scale or carries a NatSpec unit annotation.

**2. Comparing a 6-decimal Chainlink price feed against an 18-decimal TWAP without normalizing.** The `OracleRegistry` (Ch 22) normalizes all feeds to WAD before any comparison. Skipping this step produces a 10¹²× ratio error — always silent.

## Modular Arithmetic — uint256 is ℤ/2²⁵⁶ℤ

The EVM's `ADD`, `SUB`, `MUL` are defined on 256-bit words, so their results are taken mod 2²⁵⁶ — the hardware wraps. This is not an error; it is the defining identity of the ring.

### What Solidity 0.8.x actually inserts

The compiler wraps every arithmetic operation with a bounds check. For addition: the check is effectively `if (result < a) revert Panic(0x11)` — the canonical overflow sentinel. For multiplication: the check is `if (a != 0 && result / a != b) revert Panic(0x11)`.

These checks are inserted *by the compiler* — not by the developer — unless the expression is inside an `unchecked { }` block. The `unchecked` keyword restores the native EVM semantics: the operation compiles to a single opcode that wraps silently.

### The incident history — why checked math is the default

> **2018 batchOverflow class — BeautyChain & SmartMesh** —  
>  In April 2018, BeautyChain's `BEC` token was drained via an overflow in a `batchTransfer` function: it summed recipient amounts without a bounds check. The overflowed total passed the sender-balance guard (wrapping made it tiny), while each recipient received a full share — effectively minting from nothing. SmartMesh's `SMT` suffered the same class in January 2018. 
 
>  Both incidents predate checked arithmetic. The lesson is not "use SafeMath" — it is that **unchecked integer math is an invariant violation waiting for an input**. Solidity 0.8.0 (December 2020) made checked math the default for the entire language.

### Measured cost of the check — solc 0.8.24

63 gas per element is small in isolation. In a hot per-second accrual loop it compounds; Meridian pays it because accrual runs once per market per block — not per user action — making the security win dominant.

## Division Truncates — Rounding is Policy

`DIV` truncates toward zero: `7 / 3 == 2`, and `4 / 5 == 0`. For unsigned integers this is *floor* division. The remainder — the dust — goes somewhere. In a protocol, every division is an opportunity to give that dust to the user or extract it, and the convention must be explicit.

Dust stays in the protocol. Favors the protocol on every withdrawal and redemption.

- Withdrawn tokens
- Redeemed shares → underlying
- Interest credited to depositor
- `fromWad` conversion
- `mulDiv` default (truncation)

Dust is charged to the user. Favors the protocol on every debt and fee.

- Collateral required
- Debt accrued
- Fees charged
- `ceilDiv` for collateral/debt requirements
- `mulDiv(a, b, c, Math.Rounding.Ceil)`

> **Rounding direction is a security property** —  
>  Systematic rounding in the *attacker's* favor is a value-extraction vulnerability. The Balancer V2 ComposableStablePool exploit (~$128M, November 2025) was a rounding/precision failure in pool math — each trade extracted a few wei, compounding across millions of transactions. §Security Analysis treats this class in full.

### Overflow-safe ceil division

The naive ceil formula has a fatal overflow:

The lab implements exactly this in `ceilDiv` and fuzzes the identity `ceil(a/b) == a/b + (a%b != 0)` over the full `uint256` domain.

## Phantom Overflow & mulDiv

Consider computing a collateral factor: `collateralValue * factor / 1e18`. The quotient fits in 256 bits (it is a fraction of `collateralValue`), but the *product* `collateralValue * factor` may exceed 2²⁵⁶ — reverting with `Panic 0x11` even though the mathematically correct result is representable. This is the **phantom-overflow** failure class.

### The failure visualized

### How mulDiv solves it — the 512-bit algorithm

The fix is to compute the full product in two 256-bit limbs, then divide the 512-bit number by the denominator. This is Remco Bloemen's algorithm, implemented in OpenZeppelin `Math.mulDiv` and Uniswap V3 `FullMath.mulDiv`.

- **Compute low limb.** `prod0 = a * b mod 2²⁵⁶` — the native `MUL` opcode, which wraps.
- **Compute high limb.** `prod1 = mulmod(a, b, 2²⁵⁶−1) − prod0`, corrected for borrow using Remco Bloemen's trick: `sub(sub(mm, prod0), lt(mm, prod0))` where `mm = mulmod(a, b, not(0))`.
- **Fast path (common case).** If `prod1 == 0`, the product fits in 256 bits — single `DIV`. Cost: ~1,079 gas.
- **Slow path (512-bit divide).** Factor out powers of two from the denominator, compute its modular inverse mod 2²⁵⁶ via six rounds of Hensel lifting (Newton–Raphson), multiply. Cost: ~1,375 gas.
- **Quotient overflow check.** If `denominator ≤ prod1`, the quotient would overflow 256 bits — revert with `MulDivOverflow` (a custom error carrying `a`, `b`, `denominator`).

> **Meridian convention — mulDiv is the only ratio primitive** —  
>  Every collateral factor, utilization, and share-price computation (Ch 20–23) uses `mulDiv`. Naive `(a*b)/c` is banned in review — flagged as a finding regardless of whether the phantom overflow is reachable with current inputs. The measured overhead: **+22 gas over naive on the fast path**. That is the price of correctness over the entire `uint256` domain.

## Fixed Point — WAD & RAY

Since the EVM has no fractions, protocols agree on a scale and do all math in that scale. Two scales dominate in Meridian:

The "decimal point sits 18 places from the right." Used for token amounts, prices, and ratios.

- `wadMul(a, b) = mulDiv(a, b, 1e18)`
- `wadDiv(a, b) = mulDiv(a, 1e18, b)`
- 1.0 in WAD = `1e18`
- 0.5 in WAD = `5e17`
- Error per `wadMul`: < 1 WAD (1 unit of least precision)

27 decimal places. Used for rates — because a per-second rate at 5% annual is ~1.6e-9, and 1.6e-9 × 1e27 = 1.6e18: representable without losing precision.

- `rayMul(a, b) = mulDiv(a, b, 1e27)`
- `rayDiv(a, b) = mulDiv(a, 1e27, b)`
- Aave V3's convention — Meridian adopts it for `InterestRateModel` (Ch 21)
- Per-second rate in RAY: `annualRateRay / 31,536,000`

### toWad / fromWad — the only sanctioned conversion points

| Function | Formula | Direction | Decimals > 18? |
| --- | --- | --- | --- |
| `toWad(amount, decimals)` | `amount × 10^(18−decimals)` | Scales up — no precision lost | Reverts — `DecimalsAbove18` |
| `fromWad(amount, decimals)` | `amount / 10^(18−decimals)` | Floors — dust stays in protocol ✓ | Reverts — `DecimalsAbove18` |

> **Why decimals > 18 are rejected** —  
>  A 24-decimal token cannot be scaled *up* to WAD by multiplication — it would need division (losing precision) or a scale larger than WAD. Meridian rejects such tokens at the interface rather than silently operating at a different precision. The custom error `DecimalsAbove18(uint8 decimals)` carries the offending value for client display.

### Worked decimal example — USDC at 6 decimals

## Per-Second Rates — Linear vs Compound

Interest accrues over time. Two models matter:

| Model | Formula | Gas | Bias | Used by |
| --- | --- | --- | --- | --- |
| **Linear (per-second)** | `principal × ratePerSecond × Δt / RAY` | Cheap — single mulDiv | Understates compound — borrower-favorable ✓ | Aave V3, Meridian Ch 21 |
| **Exponential (continuous)** | `principal × e^(r×t)` | Impractical on-chain | Exact — no bias | Off-chain analytics only |

### The understatement is quantifiable

This bias is *documented and intentional*. Borrowers benefit from the model's imprecision at the margin; the protocol does not extract rounding from interest. Meridian's `InterestRateModel` (Ch 21) inherits this property and its documented direction.

`ratePerSecondRay = annualRateRay / 31,536,000`. Division truncates down — the per-second rate is slightly understated, again borrower-favorable. The lab asserts that one full year of per-second accrual lands within one RAY-second of the nominal annual rate.

## Mathematical Foundations

### Mod-2²⁵⁶ identities

### Newton–Raphson modular inverse (the slow path)

After factoring powers of two from the denominator, the remaining factor is odd and has a unique inverse mod 2²⁵⁶. Starting from a 4-bit-correct seed `(3·d) XOR 2`, six Hensel iterations double the correct bits: 4 → 8 → 16 → 32 → 64 → 128 → 256. Each iteration: `inverse *= 2 − d·inverse`. Six operations, exact result.

### Ceil identity and overflow proof

### Fixed-point error budget

Each `wadMul`/`wadDiv` rounds down by less than 1 WAD. A chain of *k* multiplications accumulates less than *k* WAD of downward bias — negligible per operation, but the bias direction is systematic and therefore an attack surface if reversed (§Security Analysis).

## Locked Conventions — Chapter 04 Additions

- **WAD (1e18) for all amounts and prices; RAY (1e27) for all rates.** Cross-token math is normalized to WAD via `toWad`/`fromWad` before any comparison or computation. Tokens with decimals > 18 are rejected at the interface (`DecimalsAbove18`).
- **`mulDiv` as the only ratio primitive.** Naive `(a*b)/c` is banned in review — flagged regardless of whether phantom overflow is currently reachable. `mulDiv` with `Math.Rounding.Ceil` for the ceil direction.
- **Floor for user-received; ceil for user-paid.** Floor: withdrawals, redemptions, credited interest. Ceil: collateral required, debt accrued, fees charged. Every division in protocol code carries a comment stating the direction and the party it favors.
- **Checked math by default; `unchecked` only with a documented bound proof.** The proof must appear as a comment immediately above the `unchecked` block, stating why the value cannot overflow given the preceding constraints.
- **Linear per-second accrual (Aave V3 model).** Borrower-favorable by construction (~r²/2 understatement per year). Documented as a design choice, not a bug.
- **No amount variable named by denomination.** No `amountEther`, `priceGwei`. NatSpec `@dev unit: WAD` annotation on every amount state variable and function parameter.
- **Divide-by-zero must revert loudly.** A guarded `if (b == 0) return 0` that masks a broken invariant is a finding. `ceilDiv` and all division helpers preserve the `Panic 0x12` path.

## Code Walkthrough — ArithProbe.sol

`ArithProbe` is pedagogical — not a protocol contract. Each function pins one measurable arithmetic fact; the test suite makes every fact verifiable with a single `forge test -vvv` run.

> **The external/public footgun — discovered in this chapter's own lab** —  
>  `ArithProbe` originally declared `mulDiv` as `external` and called it from `wadMul`. This failed to compile with *"An external function cannot be called internally (compiler Error 7576)"*. The fix — implement the interface function as `public`, which satisfies an `external` interface declaration *and* permits internal calls — is the OpenZeppelin v5 pattern used in every `IERC20` implementation. Every Meridian interface implementation (Ch 14, 20–23) follows this.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

uint256 constant WAD = 1e18;   // compile-time constant — compiler folds into calls
uint256 constant RAY = 1e27;   // no SLOAD: PUSH32 ~3 gas (Ch 2 immutable rule)

interface IArithProbe {
    /// Custom error: mulDiv quotient would exceed 256 bits.
    error MulDivOverflow(uint256 a, uint256 b, uint256 denominator);
    /// Custom error: token has more than 18 decimals.
    error DecimalsAbove18(uint8 decimals);

    function addChecked(uint256 a, uint256 b) external pure returns (uint256);
    function addUnchecked(uint256 a, uint256 b) external pure returns (uint256);
    function wrapMaxPlusOne() external pure returns (uint256);
    function ceilDiv(uint256 a, uint256 b) external pure returns (uint256);
    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256);
    function wadMul(uint256 a, uint256 b) external pure returns (uint256);
    function toWad(uint256 amount, uint8 decimals) external pure returns (uint256);
    function fromWad(uint256 amount, uint8 decimals) external pure returns (uint256);
    function ratePerSecondRay(uint256 annualRateRay) external pure returns (uint256);
}

contract ArithProbe is IArithProbe {

    // ── Checked vs unchecked ──────────────────────────────────────────
    function addChecked(uint256 a, uint256 b) public pure returns (uint256) {
        return a + b; // compiler inserts Panic 0x11 check — one conditional branch
    }
    function addUnchecked(uint256 a, uint256 b) public pure returns (uint256) {
        unchecked { return a + b; } // native ADD — wraps mod 2²⁵⁶
    }
    function wrapMaxPlusOne() public pure returns (uint256) {
        unchecked { return type(uint256).max + 1; } // proves: wraps to 0
    }

    // ── Overflow-safe ceil division ───────────────────────────────────
    function ceilDiv(uint256 a, uint256 b) public pure returns (uint256) {
        if (a == 0) return 0;      // guard: (0-1) underflows
        return (a - 1) / b + 1;       // b==0 → Panic 0x12 preserved ✓
    }

    // ── 512-bit mulDiv ───────────────────────────────────────────────
    function mulDiv(uint256 a, uint256 b, uint256 d)
            public pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = a * b;
            uint256 mm = mulmod(a, b, type(uint256).max);
            uint256 prod1 = mm - prod0 - (mm < prod0 ? 1 : 0); // high limb
            if (prod1 == 0) return prod0 / d; // fast path: product fits in 256 bits
            if (d <= prod1) revert MulDivOverflow(a, b, d); // quotient overflows
            // … slow path: Newton inverse, 6 Hensel iterations …
        }
    }

    // ── WAD fixed-point wrappers (public — callable internally) ──────
    function wadMul(uint256 a, uint256 b) public pure returns (uint256) {
        return mulDiv(a, b, WAD); // mulDiv is public — internal call works
    }

    // ── Decimal normalization ─────────────────────────────────────────
    function toWad(uint256 amount, uint8 decimals) public pure returns (uint256) {
        if (decimals > 18) revert DecimalsAbove18(decimals);
        return amount * (10 ** (18 - decimals)); // safe: decimals ≤ 18
    }
    function fromWad(uint256 amount, uint8 decimals) public pure returns (uint256) {
        if (decimals > 18) revert DecimalsAbove18(decimals);
        return amount / (10 ** (18 - decimals)); // floors — dust stays in protocol ✓
    }

    // ── Per-second rate conversion ────────────────────────────────────
    function ratePerSecondRay(uint256 annualRateRay) public pure returns (uint256) {
        return annualRateRay / 31_536_000; // floors — borrower-favorable ✓
    }
}
```

#### Test suite — 32 tests, what each category pins

| Category | Key tests | Fact pinned |
| --- | --- | --- |
| Checked semantics | `testCheckedOverflowReverts`, `testUncheckedWraps`, `testWrapMaxPlusOne` | Checked reverts `Panic 0x11`; unchecked wraps; `max + 1 == 0` |
| Rounding | `testCeilDivMax`, `testCeilDivByZero`, `testFuzzCeilIdentity` | Safe at `uint256.max`; div-by-zero preserves `Panic 0x12`; ceil identity fuzzed |
| mulDiv | `testPhantomOverflow`, `testMulDivExact`, `testFuzzFloorIdentity` | Phantom overflow (2²⁶⁰ product, 2¹⁹⁶ quotient); floor behavior; no off-by-one |
| WAD/RAY | `testWadMulBasic`, `testFuzzWadMulEqualsMultiDiv` | Basic scaling; fuzz equality with `mulDiv(a, b, WAD)` |
| Decimals | `testToWadUsdc`, `testDecimalsAbove18`, `testFuzzRoundTrip` | USDC 6-decimal scaling; rejection of decimals > 18; round-trip exactness |
| Rates | `testRatePerSecondRay`, `testOneYearAccrual` | Per-second conversion floors; one year within one RAY-second of nominal |
| Gas | `testGasCheckedVsUnchecked`, `testGasMulDivPaths` | Loop-amplified min-delta: 13,506 vs 17,582 (checked); 1,079 vs 1,375 (fast vs slow path) |

## Production References

| Library | What to read | Meridian connection |
| --- | --- | --- |
| **OZ v5 Math.sol** | `mulDiv` and `mulDiv(Rounding)` modes. Compare the assembly 512-bit multiply against `ArithProbe.mulDiv`; note the `denominator > prod1` quotient check. OZ's rounding *modes* expose both floor and ceil from one primitive. | Vault math will be diffed against OZ in review. Any deviation requires a documented reason. |
| **Aave V3 WadRayMath.sol + MathUtils.sol** | `wadMul`/`rayMul`/`rayDiv` in production; `calculateLinearInterest` — the per-second accrual model Meridian's `InterestRateModel` (Ch 21) implements. | Direct template for Ch 21. Read the per-second division and note the floor direction. |
| **MakerDAO DS-Math** | The original WAD/RAY library (~100 lines). Uses `assert` overflow checks (pre-0.8 pattern). Historical origin of the WAD/RAY terminology every later library inherits. | Historical context — understand what was manual before 0.8.0 checked math. |
| **Uniswap V3 FullMath.sol** | `mulDiv` + `mulDivRoundingUp` feeding Q64.96 tick math. The first place many auditors meet the 512-bit `mulmod(a, b, type(uint256).max)` trick. `mulDivRoundingUp` = the ceil policy for "user pays." | Alternative implementation to compare; the Q64.96 scale is a third design option if WAD/RAY proves insufficient for a future module. |

## Security Analysis — Arithmetic Vulnerability Classes

**Arithmetic Overflow / Underflow (Panic 0x11)** —   **2018 batchOverflow class** — BeautyChain BEC (April 2018) and SmartMesh SMT (January 2018): unchecked sums in batch-transfer functions wrapped past 2²⁵⁶, allowing minting of arbitrary token value.   In 2026 the class survives in: `unchecked` blocks added without a bound proof; inline assembly arithmetic; migration code paths (Ch 38 upgrade discipline).  
**Fix:** checked math by default (Solidity ≥0.8.0). unchecked only with a comment proving the bound. Meridian's convention is locked since Ch 02.

**Phantom Overflow — Silent Wrong Result in unchecked** —   Naive `(a*b)/c` reverts on representable quotients in checked mode. In `unchecked` mode the same expression silently wraps, producing a wrong-but-valid-looking result — strictly worse than a revert, because no signal indicates failure. The collateral factor or share price becomes garbage; liquidations fail or overpay.  
**Fix:** mulDiv everywhere ratios appear. The fuzz floor-identity test is the regression guard. Reviewing for naive (a*b)/c is a protocol-level audit rule.

**Rounding-Direction Theft — Systematic Bias Extraction** —   Rounding is value flow. If the attacker-controlled side of a computation rounds in the attacker's favor, dust extraction compounds into real value across millions of operations.   **Balancer V2 ComposableStablePool (~$128M, November 2025)** — a rounding/precision failure in pool math. Full treatment in Ch 26.   **ERC4626 inflation / donation attack (Ch 16)** — same root cause viewed from the share side: first-depositor rounding grants a claim on subsequent deposits.  
**Fix:** locked rounding direction (floor for user-received, ceil for user-paid) + invariant tests asserting the bias direction (Ch 12). Every division in protocol code carries a direction comment.

**Division-by-Zero — the Silent-Mask Variant** —   `Panic 0x12` on a user-controlled zero denominator is acceptable — the call reverts and the state is unchanged. The dangerous variant is a *guarded* `if (b == 0) return 0` that silently masks a broken invariant: the protocol continues with a zero result where it should have stopped.  
**Fix:** ceilDiv and all division helpers preserve Panic 0x12. Silent-zero guards are a review finding unless the zero case is a documented, tested policy with a NatSpec explanation.

## Gas Optimization

All numbers measured: loop-amplified `gasleft()` min-delta, plain `forge test -vvv`, solc 0.8.24, optimizer 200 runs.

| # | Comparison | Before | After | Delta | When to pay it |
| --- | --- | --- | --- | --- | --- |
| 1 | Checked vs unchecked (64-element sum) | 13,506 gas | 17,582 gas | +4,076 gas (~63/elem) | Pay it everywhere; use unchecked only with a bound proof |
| 2 | mulDiv fast vs slow path (512-bit Newton) | 1,079 gas | 1,375 gas | +296 gas (+27%) | Fast path is the common case (WAD-scale products fit in 256 bits) |
| 3 | Naive (a*b)/c vs full mulDiv (fast path) | 1,046 gas | 1,068 gas | +22 gas (+2.1%) | Pay it always — the correctness guarantee over the full domain is worth it |
| 4 | WAD/RAY as `constant` vs storage | ~3 gas (PUSH32) | 2,100 gas (cold SLOAD) | −2,097 gas | Always use `constant` for compile-time scales — compiler folds to immediate |

### Checked vs unchecked — when to consider unchecked

```solidity
// Checked — safe, always correct
function sumChecked(uint256[] calldata xs)
    external pure returns (uint256 s) {
    for (uint256 i; i < xs.length; ++i)
        s += xs[i]; // 63 gas check per iter
}
// 17,582 gas (64 elements)
```

```solidity
// unchecked — only if: each xs[i] ≤ 2²⁴⁸
// AND xs.length ≤ 256 (bound proven by caller)
function sumBounded(uint256[] calldata xs)
    external pure returns (uint256 s) {
    unchecked {
        for (uint256 i; i < xs.length; ++i)
            s += xs[i];
    }
}
// 13,506 gas (64 elements)
```

↓ 17,582 → 13,506 gas — only acceptable with a documented bound proof above the block

## Common Mistakes

- **Declaring an `external` function and calling it internally.** `f()` from within the same contract fails — compiler Error 7576. Fix: implement interface functions as `public` (OZ v5 pattern), which satisfies `external` declarations and permits internal calls.
- **`(a + b - 1) / b` for ceil division.** Overflows when `a + b - 1 ≥ 2²⁵⁶`. Use `a == 0 ? 0 : (a - 1) / b + 1` — proved above.
- **`unchecked` blocks without a bound proof.** Saving 63 gas/element is not worth a wrapped collateral factor. If the block is justified, the comment immediately above must state *why* it cannot overflow.
- **Dividing before multiplying.** `a / b * c` loses precision that `mulDiv(a, c, b)` preserves — the classic utilization/ratio bug. Always multiply first, use `mulDiv` when the product may overflow.
- **Unit confusion in variable names and constants.** `amountEther` holding wei; comparing 1e6-scale USDC units against 1e18-scale MER units without normalization. Add `@dev unit: WAD` to every amount state variable.
- **Rounding in the wrong direction for the party.** Flooring what a user pays (or ceiling what they receive) is the rounding-theft class in miniature. Check every division against the locked convention.
- **Using `%` on `int256`.** Solidity's `%` on signed integers truncates toward zero: `-7 % 3 == -1`, not `2`. Protocol money math must be `uint256`; signed intermediates need explicit semantics.
- **Forgetting the scale when comparing prices.** A Chainlink feed at 8 decimals and a TWAP at 18 decimals are different numbers for the same price. `OracleRegistry` (Ch 22) normalizes before comparing — every comparison must happen after `toWad`.
- **`type(uint256).max` as "infinite" in arithmetic.** Valid as an ERC-20 allowance sentinel — but adding 1 wraps to 0. Never use it as a sentinel in computations where arithmetic follows.
- **Silent `if (b == 0) return 0` guards.** `ceilDiv` keeps the `Panic 0x12` path intentionally. A guard that masks a zero denominator hides a broken invariant — flag as a finding unless the zero case is documented and tested.

## Exercises & Weekly Project

### Conceptual exercises

- **Prove, then fuzz,** that `ceilDiv`'s `(a-1)/b + 1` cannot overflow for any `a, b` with `b > 0`. Bound `(a-1)/b` and state why adding 1 cannot reach 2²⁵⁶.
- **Compute by hand** `mulDiv(2²⁰⁰, 2⁶⁰, 2⁶⁴)` and `mulDiv(2²⁰⁰, 2⁶⁰, 2²)`. Explain why the second reverts with `MulDivOverflow`. Verify against the lab.
- **For a 6-decimal token,** compute `toWad(1_000_000, 6)`, `toWad(1, 6)`, and `fromWad(1e18 - 1, 6)`. Which direction loses dust, and is it protocol-favorable?
- **Derive** the linear-vs-compound understatement for `r = 0.10` (10% annual). Verify against `testRatePerSecondRay`'s bound check.
- **Write a fuzz test** asserting `wadMul(a, b) ≤ a` whenever `b ≤ 1e18` — the WAD-side statement of the floor policy.
- **Take `ArithProbe.mulDiv`, change it to `external`,** and compile. Read the exact compiler error; restore `public` and explain why the interface override still type-checks.

### Weekly Project — Lock the Units & Rounding Convention

> **Project 1.4 · docs/units-and-rounding.md** —  
> The reference document Ch 20–23 must implement without rediscovery — every rounding decision derives from this document, not from a per-engineer judgment call.

1. Write `docs/units-and-rounding.md` with four sections: (a) unit ladder and token-decimal policy (MER at 18, all internal amounts normalized to WAD); (b) fixed-point constants and their value ranges; (c) the rounding-direction table with one row per operation type; (d) the measured gas budget from this chapter.
2. Extend `ArithProbeTest.t.sol` with the vault-invariant seed: `wadMul` monotonicity — `b1 ≤ b2 ⟹ wadMul(a, b1) ≤ wadMul(a, b2)`. This is the property Meridian's liquidation engine's price comparisons (Ch 24–25) rely on.
3. Add a one-paragraph note to the doc stating which operations floor, which ceil, and the invariant that ensures no operation extracts value from users via rounding.

> **Success criteria** —  
> All 70/70 tests green including the monotonicity fuzz. The rounding table is mechanically checkable — each row is a yes/no against the locked convention. The gas budget table matches the measured numbers within 5%.

## Quiz

Tap a question to reveal the answer.

- **Q.** type(uint256).max + 1 in an unchecked block evaluates to what, and why? 
  **A.** `0`. `uint256` arithmetic is modular mod 2²⁵⁶. The EVM's native `ADD` opcode wraps, so `max + 1 ≡ 0 (mod 2²⁵⁶)`. In a checked context the same expression reverts with `Panic 0x11` (selector `0x4e487b71`). The `unchecked` block suppresses the compiler's overflow branch and restores the native opcode semantics.
- **Q.** Why does (a * b) / c revert even when the quotient fits in 256 bits, and what is the fix? 
  **A.** The intermediate product `a * b` may overflow 256 bits before the division — this is the phantom-overflow failure class. In checked mode it reverts with `Panic 0x11`; in unchecked mode it silently wraps, producing a wrong result. The fix: a 512-bit intermediate — compute the product in two 256-bit limbs (low: `a*b mod 2²⁵⁶`; high: Remco Bloemen's mulmod trick), then divide the 512-bit number. This is `mulDiv` in OpenZeppelin v5 and `ArithProbe.mulDiv`. Measured overhead: +22 gas over naive on the fast path (when the product fits).
- **Q.** Name the vulnerability classes of the 2018 BeautyChain/SmartMesh drains and the 2025 Balancer V2 exploit, with the one-line mitigation for each. 
  **A.** **2018 (BeautyChain BEC, SmartMesh SMT):** arithmetic overflow in unchecked batch-transfer sums — the overflow wrapped total past 2²⁵⁶, passing the balance check while recipients received full amounts. Mitigation: checked math (default since Solidity 0.8.0) and bounded `unchecked` blocks with proven bounds. **2025 (Balancer V2 ComposableStablePool, ~$128M):** rounding/precision failure in pool math — systematic extraction of dust across millions of operations. Mitigation: locked rounding direction (floor for user-received, ceil for user-paid) plus invariant tests asserting the bias direction. Full treatment in Ch 26.
- **Q.** ceilDiv uses (a − 1) / b + 1, not (a + b − 1) / b. Why? 
  **A.** `a + b − 1` can exceed 2²⁵⁶ and wrap before the division — a silent wrong result in unchecked mode or a `Panic 0x11` in checked mode. The form `(a − 1) / b + 1` is bounded: `(a−1)/b ≤ a−1`, so adding 1 gives at most `a ≤ 2²⁵⁶ − 1` — cannot overflow. The `a == 0` guard prevents underflow of the subtraction, and the `b == 0` `Panic 0x12` path is preserved intentionally.
- **Q.** A 6-decimal USDC amount of 1,000,000 units is toWad'd to what value, and why does fromWad(1e18 − 1, 6) floor to 999,999? 
  **A.** `toWad(1_000_000, 6) = 1_000_000 × 10^(18−6) = 1_000_000 × 10¹² = 1e18` — one USDC token at WAD scale. `fromWad(1e18 − 1, 6)` divides by `10¹²` and truncates (floor): `(1e18 − 1) / 10¹² = 999,999`. The 1 WAD of dust floors to zero — stays in the protocol, not the user. This is the protocol-favorable direction for "user receives" operations, per the locked convention.
- **Q.** What does per-second linear interest understate relative to continuous compounding, and why is the understatement acceptable? 
  **A.** For annual rate `r`, the linear model accrues `1 + r` over one year; continuous compounding yields `e^r = 1 + r + r²/2 + O(r³)`. The understatement is approximately `r²/2` per year — at 5%, about 0.125% of principal. This is acceptable because the bias is in the *borrower's favor*: the protocol charges slightly less interest than exact compounding would require. This is a documented design choice, inherited from Aave V3, and recorded in `docs/units-and-rounding.md` as a deliberate rounding convention, not an error.

## Further Reading

- Docs **Solidity Documentation — "Types" (integer types, unchecked, units)** — canonical spec of overflow behavior, unit literals, and the `unchecked` block semantics.
- Library **OpenZeppelin v5 Math.sol** — `mulDiv` with rounding modes; Remco Bloemen's 512-bit multiplication write-up. The reference implementation Meridian's vault math will be diffed against.
- Library **Aave V3 WadRayMath.sol + MathUtils.sol** — `wadMul`/`rayMul`/`calculateLinearInterest` in production. Direct template for Ch 21's `InterestRateModel`.
- Historical **MakerDAO DS-Math** — the original WAD/RAY library; origin of the terminology. Read to understand what was manual before 0.8.0 checked math.
- Library **Uniswap V3 FullMath.sol + TickMath.sol** — `mulDiv` + `mulDivRoundingUp` in Q64.96 price math; the first widely-audited 512-bit multiply implementation.
- Library **Solmate FixedPointMathLib.sol** — Rari Capital's minimal fixed-point; a compact alternative implementation for comparison.
- Incident **BeautyChain BEC + SmartMesh SMT (2018)** — the original batchOverflow class reports; post-mortems establish exactly how the overflow was constructed and why the balance check passed.
- Incident **Balancer V2 ComposableStablePool (~$128M, November 2025)** — rounding/precision failure; full analysis in Ch 26. Read the executive summary now to understand the threat model.
