# Lending Markets I: Collateral & LTV

Lending is Meridian's core primitive. A lending market lets a user deposit one token as collateral and borrow another against it, up to a **fraction** of the collateral's value — never the whole thing, because price moves. The safety of the entire protocol rests on a small set of numbers: the **collateral factor** (how much of your collateral you may borrow against), the **health factor** (how far you are from the edge), and the **liquidation threshold** (where other users may step in and close you out). This chapter builds `MeridianVault.sol` **v1** — the third protocol contract, after MER and gMER — the isolated market core that every subsequent module stands on: interest rates (Ch 21), oracles (Ch 22), the supply side (Ch 23), the liquidation engine and governance (Ch 24-25).

v1's scope is deliberately tight: collateral deposit/withdraw, borrow/repay, and health-factor enforcement on borrow and withdraw. There is **no liquidation engine yet** (Ch 24-25), but the shape it will use — the health factor, the liquidation threshold, the `isLiquidatable` predicate, a placeholder `liquidate` — is anticipated and live. v1 consumes two interfaces rather than implementations (`IMeridianOracle` → Ch 22, `IInterestRateModel` → Ch 21), and it **finalizes the vault error catalog** that has been PROVISIONAL since Ch 2.

## Learning Objectives

1. Compute borrow capacity as `collateral · factor · price`; define the collateral factor and LTV.
2. Define the health factor `HF = Σ(collateralᵢ · liquidationThresholdᵢ · priceᵢ) / Σ(debtⱼ · priceⱼ)` and explain why HF must stay above 1.
3. Explain the liquidation threshold and the safety buffer between the collateral factor and the liquidation threshold, and why liquidations activate while the position is still solvent.
4. Derive the liquidation incentive and penalty math.
5. Contrast isolated vs pooled lending and what isolation buys: contagion containment.
6. Explain debt accrual via interest-rate snapshots (the borrow index), not per-user interest.
7. Apply the Ch 4/16 rounding policy (floor user-received, ceil user-paid) across the vault's math.
8. Read production lending code (Aave v3 / Compound cToken) and map its accounting onto `MeridianVault`.
9. State the FINAL vault error catalog (Ch 2's PROVISIONAL, resolved here).

## Prerequisites

- **Chapter 14** (ERC20 Deep Dive) — `SafeERC20`, ERC-2612, and the OZ interface-error convention the vault's catalog follows.
- **Chapter 16** (ERC4626 Vaults) — rounding discipline; the vault's borrow-index accrual obeys the same "never create or destroy value" invariant.
- **Chapter 18** (AMMs: Constant Product) — price math: why a spot price moves with one swap, and why collateral valuation leans on manipulation-resistant pricing (Ch 22).
- Supporting: **Ch 4** (WAD + rounding policy), **Ch 2** (custom errors in I-prefix interfaces), **Ch 8** (immutables, gas), **Ch 10** (parameter-exact `vm.expectRevert`), **Ch 14** (hoist view reads before pranks).
- Foreshadowed: **Ch 22** (`OracleRegistry`, consumed here), **Ch 24-25** (liquidation engine + the governance that holds the admin role).

## Theory

### Collateral factor, LTV, borrow capacity

A lending market has two sides: the **collateral token** you put up and the **debt token** you take out. In Meridian each market is one `(collateral, debt)` pair with its own parameters — this is the **isolated** model, and we return to why below.

You cannot borrow the full value of your collateral, because collateral is volatile and you might never repay. The protocol therefore discounts it by a **collateral factor** `CF` (a fraction, e.g. 75%). Your **borrow capacity** is:

```
borrow capacity = collateral · price_collateral · CF        (in debt-token units)
```

This is the loan-to-value (LTV) ratio the protocol *allows* — the fraction of collateral value you may draw as debt.

### Health factor and why it must stay above 1

The **health factor** (HF) is the ratio of your collateral value — discounted by the *liquidation threshold*, not the collateral factor — to your debt:

```
HF = Σ(collateralᵢ · liquidationThresholdᵢ · priceᵢ) / Σ(debtⱼ · priceⱼ)
```

For v1's single-pair market this is `collateralValue · LT / debtValue`. Think of HF as "how many times my collateral, valued at the liquidation threshold, covers my debt." **HF must stay above 1** — below it the debt exceeds `LT`-discounted collateral and the position is open to liquidation. The `≥ 1` line is the boundary the protocol enforces; the `> 1` margin is the solvency cushion that keeps the market repayable. Note what HF is *not*: it is not the borrow limit. The collateral factor governs how much debt you may create; the liquidation threshold governs when that debt is unsafe — HF is built from the latter, and the two controls stay separate throughout this chapter.

### Liquidation threshold and the safety buffer

If liquidations only fired at the point where debt equals collateral, the protocol would be racing the price feed — by the time a position crossed the line the collateral might already be worth less than the debt. Real lending protocols therefore separate two numbers: the **collateral factor** controls how much debt a user may *create*; the **liquidation threshold** controls when that debt becomes *unsafe* and other users may close it. The health factor is built on the liquidation threshold:

```
HF = collateralValue · LT / debtValue
liquidatable  ⟺  HF < 1
```

The two controls bracket the **safety buffer**: with `CF = 75%` and `LT = 80%`, a borrower may open at up to 75% LTV, liquidation begins above 80% LTV, and the 5 percentage points between them are the buffer — the room a price move can eat before the position becomes liquidatable, while the borrower is still economically solvent (debt still below collateral). Liquidating *early* at a discount keeps the market whole — the liquidator is paid, the borrower gives up collateral worth more than the debt repaid, and the protocol never races the feed to the point where collateral falls below debt. The buffer is the gap; `CF < LT` is what makes it exist.

### Isolated vs pooled lending

**Pooled / cross-market** lending (Compound, Aave) evaluates a borrower's collateral and debt together at the account level: assets carry their own risk parameters, but they share a broader risk pool, and one collateral asset's collapse can drag an entire account — and through it, the lenders it backs. **Isolated** lending confines collateral and debt risk to a defined market: each market is its own contract with its own collateral, debt token, collateral factor, liquidation threshold, rate model, and oracle — the Euler V2 lineage, which Meridian simplifies to a single market pair. Meridian is isolated per market pair. Isolation buys **contagion containment**: a correlated-collateral crash in one market (say, a category of staking tokens) leaves that market underwater without touching the others — the account model is per-instance, so there is no shared pool to drain. The 2026 incident set makes this concrete: failures that took down entire books were overwhelmingly *cross-market* by construction (Ch 26/27); isolation is the cheap structural answer. The cost is granularity — every market needs its own risk parameters and oracle wiring, which is exactly why `MeridianVault` consumes rather than owns them.

## Mathematical Foundations

### Health factor, precisely

Let `P_c` be the collateral price and `P_d` the debt price, both from `IMeridianOracle`, quoted in **base units per whole token** (a $2,000 ETH feed with 8 decimals reads `2000e8`; a $1 USDC feed with 6 decimals reads `1e6`). For amounts in native token units `c` and `d` with token decimals `dec_c`, `dec_d`:

```
collateralValue = c · P_c / 10^dec_c        (base units)
debtValue       = d · P_d / 10^dec_d        (base units)
HF = collateralValue · LT · 1e18 / (debtValue · 10_000)
```

The `·1e18` puts HF on the WAD axis (Ch 4). `HF = type(uint256).max` when there is no debt; `HF = 0` when there is debt but no collateral. The borrow capacity in debt-token units is the same numbers rearranged:

```
borrowCapacity = c · P_c · CF · 10^dec_d / (10^dec_c · 10_000 · P_d)
```

Both are exact `mulDiv` chains in the code (Ch 16), and both **floor** — the protocol gives the user the conservative estimate, never the optimistic one.

### Liquidation incentive and penalty math

When a position is liquidatable, a liquidator repays some debt and receives collateral in return. The **liquidation incentive** `B` (e.g. 10%) is the bonus that makes this profitable: covering `debtToCover` entitles the liquidator to collateral worth `debtToCover · (1 + B)`:

```
collateralToSeize = debtToCover · P_d · (1 + B) / P_c     (collateral units)
```

`B` is the **nominal gross incentive**; realized liquidator profit is `B` minus execution costs and price risk (gas, slippage, oracle latency, competing liquidators, collateral liquidity). The borrower gives up collateral worth `(1+B)·debtToCover` to settle `debtToCover` of debt — the excess compensates the liquidator and, depending on protocol design, may be split with a protocol reserve. These are four separate controls, and v1 keeps them distinct: `collateralFactor` is the borrowing limit, `liquidationThreshold` is the liquidation trigger, `liquidationIncentiveBps` is the liquidator compensation, and the **close factor** — how much debt one liquidation may settle — is Ch 24's decision. The safety buffer makes the zone expensive to sit in; the incentive makes closing positions a competitive market. Ch 24 implements the engine; v1 stores `liquidationIncentiveBps` and exposes the predicate.

### Debt accrual: index snapshots, not per-user interest

Interest must accrue continuously, but recomputing every user's debt on every interaction is an O(n) loop — banned by Ch 1. The production answer is the **borrow index** (Compound's `borrowIndex`): a global `_borrowIndex` starts at `1e18` and grows with time at the borrow rate:

```
_accrueInterest():
    dt = now - lastAccrual
    rate = model.borrowRate(utilization)               # per-second, WAD
    interestFactor = rate · dt                          # WAD
    interest = totalDebt · interestFactor / 1e18        # CEIL
    reserve += interest · reserveFactorBps / 10_000     # CEIL
    totalDebt += interest
    borrowIndex += borrowIndex · interestFactor / 1e18  # CEIL
    lastAccrual = now
```

Each user stores a snapshot `{principal, interestIndex}`; their current debt is derived lazily:

```
debtOf(user) = ceil(principal · borrowIndex / interestIndex)
```

The ratio `borrowIndex / interestIndex` is the growth factor applied to the principal since the snapshot — a dimensional check: `principal × growth factor = current debt`. When a user borrows or repays, the vault **resets the snapshot**: `principal = currentDebt ± amount`, `interestIndex = borrowIndex`. Within v1's tracked borrower state machine — every borrower in the set, no rounding leakage outside `totalDebt`, no bad-debt write-off — snapshot reset keeps the aggregate derived debt equal to `totalDebt` without a loop: `Σ debtOf(user) == totalDebt`, pinned by `test_newBorrowerAndExistingBorrower_snapshotConsistency`. This is the "debt accrual vs interest-rate snapshot" distinction: the *rate* is applied to the index (one storage write), and each user's *debt* is derived lazily.

Utilization, which Ch 21's kink model consumes, is defined here and locked. Meridian defines **borrowable cash** as the underlying balance minus protocol reserves — reserves are intentionally excluded from borrowable liquidity, and the same quantity is both the reserve's accounting claim and the liquidity it withholds from borrowers, so the two treatments agree:

```
utilization = totalDebt / (totalDebt + cash)
cash        = vault.debtToken balance − reserve       (saturates at 0)
```

### Rounding direction

Ch 4's policy — floor user-received, ceil user-paid — appears in four places, all pinned by tests:

| Quantity | Direction | Why |
|---|---|---|
| `borrowCapacity` | floor | the user's credit is the conservative estimate |
| `healthFactor` | floor | never overstate a position's health |
| debt/`borrowIndex` accrual | ceil | borrowers pay the rounding dust |
| `reserve` share | ceil | the protocol's claim never comes up short |

A floor where a ceil is due (or vice versa) is a value leak — the Balancer V2 class (Security Analysis #1).

## Engineering Perspective

For the repo, this chapter is the transition from *tokens* (M4) to *markets* (M5). Three structural decisions matter:

1. **Consume, don't own.** `MeridianVault` holds `IMeridianOracle` and `IInterestRateModel` as storage references. The manipulation-resistance strategy (Ch 22) and the kink curve (Ch 21) swap without touching the vault — and the tests mock both, so the vault's correctness is separable from the next two chapters' choices.

2. **Native-unit accounting.** Collateral and debt are stored in the tokens' own units; WAD appears only where fractional math lives (index, prices, rates, HF). Transfers are exact — no boundary rounding between accounting and `transfer`.

3. **The listing gate is a security boundary.** The vault assumes plain ERC-20s: no fee-on-transfer, no rebase, no EIP-777 hooks (Ch 17). A fee-on-transfer collateral silently over-credits depositors; a rebasing token changes value without an oracle move. Ch 17's answer — reject or wrap at the gate — is the vault's contract with its tokens.

2026 grounding keeps the stakes honest. **Kelp DAO / Drift (~$285–292M, Apr 2026, compromised admin keys)** is the trust-surface theme: the vault's `DEFAULT_ADMIN_ROLE` controls collateral factors, liquidation parameters, the oracle, and the rate model — keys that belong in the Ch 25 timelock. **Balancer V2 (~$128M, Nov 2025, rounding)** is the arithmetic-failure theme: a rounding direction leaking a wei per operation becomes $128M of leaked value. Both are fully treated in Ch 26/27; here they set the two rules the vault must not break — the rounding direction and the privilege boundary. On L2s (post-Fusaka, PeerDAS/EIP-7594 live, BPO scaling; Glamsterdam is roadmap-only), cheap DA makes many small isolated markets viable — more markets, not bigger pools.

## Mermaid Diagram

```mermaid
sequenceDiagram
    participant A as User (Alice)
    participant V as MeridianVault (isolated ETH/USDC market)
    participant O as IMeridianOracle (mock)
    participant IR as IInterestRateModel (mock)

    Note over V: one market pair, own CF/LT/oracle/model — no cross-market state
    A->>V: depositCollateral(2 ETH)
    V->>V: collateralOf[alice] += 2e18
    Note over A,V: collateral value = 2 · 2000e8 = 4000e8; capacity = 4000e8 · 75% = 3000 USDC; LT = 80%
    A->>V: borrow(1000 USDC)
    V->>IR: borrowRate(utilization)
    V->>O: getPrice(ETH), getPrice(USDC)
    V->>V: debtAfter 1000e6 <= capacity 3000e6 -> OK
    V->>V: snapshot reset: principal=1000e6, interestIndex=borrowIndex
    V-->>A: transfer(1000 USDC)
    Note over V: HF = 4000e8 · 80% / 1000e8 = 3.2 — healthy (HF >= 1)
    A->>V: borrow(1000 USDC) again — debt 2000e6, still within capacity
    O--)V: price drops 40% -> getPrice(ETH)=1200e8
    Note over V: collateral 2400e8; HF = 2400e8 · 80% / 2000e8 = 0.96 < 1 -> liquidatable
    A->>V: withdrawCollateral(2 ETH)
    V-->>A: revert HealthFactorTooLow(alice, 0, 1e18)
    Note over V: isLiquidatable(alice) = true (HF < 1)
    Li-->>V: liquidate(alice, …) -> revert LiquidationNotImplemented (Ch 24)
    A->>V: repay(0) — full repay, snapshot cleared, interest settled
```

## Code Walkthrough

Three files ship this chapter, all under `meridian/src/`:

**`IMeridianOracle.sol` (extended).** The Ch 3 weekly-project interface gains `getPrice(address asset)` — the per-asset price resolution the vault needs. The extension is *additive*: `latestRoundData()`, `consult()`, and `decimals()` are untouched, so the Ch 3 ABI pins still hold. Ch 22's `OracleRegistry` implements `getPrice` (feed → staleness → TWAP fallback); the vault never sees that logic.

**`IInterestRateModel.sol` (new).** The vault↔model contract: `borrowRate(uint256 utilization)` returns a per-second WAD rate; `kink()` and the rate parameters fill in Ch 21. The vault computes utilization (locked definition above) and the model reads it — the model never re-derives it. The fixed-rate mock implements the same interface, so the vault is testable before Ch 21.

**`IMeridianVault.sol` (new — the FINAL error catalog).** The protocol-facing surface: views, user actions, governance setters, events, and the error catalog. Every error carries its offending values (Ch 2 convention), e.g. `BorrowCapacityExceeded(address user, uint256 requestedDebt, uint256 capacity)`.

**`MeridianVault.sol` (new — the market core).** Key implementation points, in the order the code hits them:

- **`_accrueInterest()`** runs at the top of every state-changing path. It is O(1): one rate read, three `mulDiv`s, three storage writes, all Ceil so the reserve and index never come up short.
- **`borrow`** computes `debtAfter = currentDebt + amount`, checks it against `borrowCapacity`, then against idle liquidity (`InsufficientLiquidity` if the pool can't fund it), then resets the snapshot. Capacity is checked before liquidity so the user always learns the *reason* the borrow failed.
- **`withdrawCollateral`** re-derives the health factor with the post-withdrawal collateral and reverts `HealthFactorTooLow` when the resulting HF would drop below 1 (`resulting HF ≥ 1` is the gate) — the HF enforcement the chapter is named for. The three checks are conceptually distinct: `borrow()` checks `debtAfter ≤ collateralValue · CF` (capacity), `withdraw()` checks the resulting `HF ≥ 1`, and liquidation fires at `HF < 1`.
- **`repay`** (`amount == 0` = repay-all) folds the repayment into a fresh snapshot. The `debt` it settles is Ceil-rounded, so a full repay always clears the snapshot; a partial repay leaves at most the rounding dust, owed to the protocol (pinned by `test_repayDust_staysOwed_thenFullRepayClears`).
- **`liquidate`** reverts `LiquidationNotImplemented`. The shape — `(borrower, debtToCover)`, with `isLiquidatable` and `liquidationIncentiveBps` already live — is the interface Ch 24's engine implements without breaking the ABI.
- **Governance setters** are `onlyRole(DEFAULT_ADMIN_ROLE)` (OZ `AccessControl`, matching MER/gMER). `setInterestRateModel`/`setOracle` accrue interest *first* so pending interest locks at the old parameters. The constructor grants admin to the deployer; in production that role moves to the Ch 25 timelock.

Rounding follows the table from Mathematical Foundations, and each direction is pinned by a test. Accounting is in native token units; WAD appears only in the index, prices, rates, and HF.

## Production Example

**A user's borrow lifecycle on a real market.** Suppose the ETH/USDC market has `collateralFactor = 75%`, `liquidationThreshold = 80%`, `liquidationIncentive = 10%`, `reserveFactor = 20%`. Alice deposits 2 ETH at `P_c = $2,000`: capacity `2 · 2000 · 0.75 = $3,000`, borrows 1,000 USDC, HF `(2·2000·0.80)/1000 = 3.2`, then tops up to 2,000 USDC (still inside capacity, HF 1.6). Over the month the borrow rate (Ch 21's kink curve) compounds through the borrow index — every transaction runs `_accrueInterest`; Alice's debt is derived from her snapshot, never recomputed. If the ETH feed drops to $1,200 her collateral is worth `2 · 1200 = $2,400` and her HF becomes `(2·1200·0.80)/2000 = 0.96` — below 1, liquidatable. The production shape to notice: every HF/capacity/isLiquidatable read hits `oracle.getPrice` through the Ch 22 registry, which resolves the Chainlink feed, rejects stale rounds, and falls back to the on-chain TWAP. A flash-loan-sized swap moves a spot read instantly; it moves a long-window TWAP only slightly — not necessarily with zero effect (Ch 34's Mango class) — hence the registry, never a pool's `slot0`.

**The supply side is a future interface, not a v1 feature.** The debt pool is seeded by `DEFAULT_ADMIN_ROLE` via `supplyDebtLiquidity`. In production that liquidity is the sMER vault (Ch 23) — stakers supply, borrowers borrow, the spread accrues to sMER share appreciation. The `supplyDebtLiquidity`/`withdrawExcessLiquidity` pair is the narrow seam that keeps the market operable before the supplier exists; Ch 23 replaces the admin call with the 4626 supply flow without changing the vault.

## Foundry Lab

Materialized and compile-verified in this run (forge 1.7.1, solc 0.8.24, cancun, optimizer 200):

- **New protocol artifacts:** `src/IMeridianVault.sol` (FINAL vault error catalog), `src/IInterestRateModel.sol`, `src/MeridianVault.sol` (v1 market core), and the additive extension of `src/IMeridianOracle.sol` (`getPrice(address)`).
- **New test artifacts:** `test/MeridianVaultMocks.sol` (`MockERC20`, `FixedRateInterestRateModel`, `MockOracle` — mocks in `test/`, no cheatcodes in `src/`) and `test/MeridianVault.t.sol` (**50 tests**).
- **Full repo suite: 394 passed / 0 failed / 6 skipped (400 total) across 29 suites** (Ch 19 baseline 314/0/6 across 27, plus the Ch 4 `ArithProbe` lab; +50 tests, +1 suite). The 6 skips remain the Ch 11 fork tests (RPC-gated).
- **`.gas-snapshot` regenerated to 399 rows** under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`, paired `--check` green (Ch 14 rule).
- **Gas (test-level snapshot rows):** `depositCollateral` **69,653** · `borrow` **221,988** · `repay` **214,133**. The borrow row includes the two oracle reads and the SafeERC20 transfer — the Ch 8 gas-budget row the Ch 13 snapshot gate now watches.
- **Real findings, all kept:** (1) the **snapshot-reset requirement** — an initial design minted principal by scaling `amount·interestIndex/index` without resetting `interestIndex`, silently breaking `Σ debtOf == totalDebt` once two users interacted at different indices; the Compound-style reset keeps the invariant exact (pinned). (2) **`healthFactor` must be `public`**, not `external` — `isLiquidatable` calls it internally (error 7576). (3) **Views don't accrue** — `debtOf` after `vm.warp` returns the stale index; accrual tests trigger it with a no-op `setOracle(oracle)` call (state-changing calls accrue, views do not — a genuinely subtle trap).

## Security Analysis

**1. Rounding direction is a security property (the anchor class).** Every computation must favor the protocol: capacity and HF floor; debt, index, and reserve ceil. A pool that pays the *ceil* of a user-received amount leaks a wei per operation that compounds over volume — the Balancer V2 failure (~$128M, Nov 2025), full treatment in Ch 26. The vault pins the direction in four tests.

**2. Price-manipulation surface.** The vault's HF and capacity are only as good as `oracle.getPrice`. A live spot read (a pool's `slot0.sqrtPriceX96`, or a stale feed) can be moved with a flash-loan-sized swap (Ch 34), letting an attacker borrow against inflated collateral or liquidate a healthy position — the Mango class (~$114M, Oct 2022). Ch 22's `OracleRegistry` answers with a Chainlink primary feed plus staleness checks and an on-chain TWAP fallback: the *window* average, which costs real money to hold. v1's contribution is that the vault reads *only* through `IMeridianOracle.getPrice`, so the manipulation-resistance choice lives in exactly one place.

**3. Admin keys are a trust root (Kelp DAO / Drift class).** `DEFAULT_ADMIN_ROLE` can change the collateral factor, liquidation threshold/incentive, reserve factor, oracle, and rate model, and withdraw idle liquidity. A compromised admin can liquidate everyone (liquidation threshold 0, incentive 0) or drain the market — the ~$285–292M Apr 2026 shape (an admin key is an admin key, Ch 15/17). The mitigation is not to remove the surface but to move it behind the Ch 25 timelock + multisig and make `withdrawExcessLiquidity` provably idle-only. Every guarded path has a non-privileged negative test (Ch 10), so the boundary is enforced mechanically.

**4. Collateral-token quirks must be rejected at the listing gate (Ch 17).** A fee-on-transfer collateral over-credits depositors; a rebasing collateral changes value without an oracle move; an EIP-777 hook token re-enters mid-transfer. The vault does none of the defensive accounting that would absorb these (balance-delta, gons, callback guards) — by design. The listing gate rejects or wraps such tokens.

**5. Undercollateralized-borrow edge cases.** Three boundary states are pinned: zero collateral (capacity 0 → `BorrowCapacityExceeded(user, amount, 0)`), exactly capacity (LTV = CF → HF = LT/CF ≈ 1.067 — allowed, comfortably above the liquidation line), and liquidity failure rather than capacity (`InsufficientLiquidity`). The 1-wei dust of a partial repay stays owed (Ceil), so a borrower can never repay *less* than the true debt.

**6. The safety buffer is a design choice Ch 24 must honor.** v1 exposes `isLiquidatable` and the incentive but does not freeze the position — a liquidatable-but-solvent borrower could still transact. Ch 24 decides the freeze semantics and close factor; v1 leaves that to the liquidation chapter rather than shipping a half-engine.

## Common Mistakes

1. **Using a spot price as the collateral oracle** — one swap moves it; the Ch 22 window TWAP exists to make the average expensive to move (Mango class).
2. **Rounding in the user's favor** — capacity/HF floor, debt/index/reserve ceil; the Balancer direction is the counterexample.
3. **Recomputing interest per user on every interaction** — the O(n) loop Ch 1 bans; the borrow index is the O(1) answer.
4. **Minting principal without resetting the snapshot** — `Σ debtOf == totalDebt` breaks once users interact at different indices (finding #1).
5. **Forgetting views don't accrue** — `debtOf` after `vm.warp` returns the stale index; a state-changing call is the accrual trigger.
6. **Confusing the borrow limit with the liquidation threshold** — CF sets how much you may borrow (LTV ≤ CF); LT sets when liquidation begins (LTV > LT, HF < 1). They are distinct controls; the gap between them is the safety buffer.
7. **Letting `withdrawExcessLiquidity` touch the reserve** — the idle-only cap (`balance − reserve`, saturating) keeps the protocol's claim whole.
8. **Listing fee-on-transfer or rebasing collateral** — native-unit accounting assumes plain ERC-20s; wrap or reject at the gate (Ch 17).
9. **Skipping the non-privileged negative tests** — every `onlyRole` path needs its unauthorized-caller test; that is the security posture (Ch 10).

## Gas Optimization

Measured in this run (`.gas-snapshot` rows under the CI seed — the Ch 13 gate; no `gasleft()` assertions in the tests):

- **`depositCollateral` 69,653** warm: one `SSTORE`, one SafeERC20 `transferFrom`. Deliberately no `_accrueInterest` on deposit — collateral doesn't move debt, so accruing would burn gas for nothing. Withdraw, borrow, and repay all accrue.
- **`borrow` 221,988** warm: the accrue (one model call + two index `mulDiv`s), two oracle reads, the capacity `mulDiv` chain, one `SSTORE` for the snapshot reset, and the SafeERC20 transfer. The two oracle reads dominate the non-transfer cost and are the Ch 22 registry's design target.
- **`repay` 214,133** warm: the accrue, the transfer-in, and the snapshot reset. No HF computation on repay — repaying can only improve health, so the check is skipped (Ch 8's "remove, then cheapen").

Design notes consistent with Ch 8: (1) **immutables** for both tokens and their decimals — `PUSH32` each, never cold `SLOAD` (the four reads replace ~8,400 gas of cold reads on the hot path). (2) **The borrow index makes accrual O(1)** — the alternative is unbounded by construction. (3) **No redundant HF check on repay or deposit** — the checks live exactly where the action can harm the market (borrow, withdraw). (4) The two `getPrice` calls are the cost of a manipulation-resistant oracle; Ch 22 can batch them if the gate ever flags the row. Gas claims carry numbers from the snapshot; `--gas-report` is not used.

## Reading Production Source Code

1. **Compound cToken `borrowFresh` / `repayBorrowFresh`** (`contracts/CToken.sol`) — the exact snapshot pattern this chapter pins: `accountBorrows[borrower] = {principal, interestIndex}`, current debt `principal · borrowIndex / interestIndex`, reset on borrow/repay. Read `accrueInterest` (the index bump via `simpleInterestFactor = borrowRate · blockDelta`) — the vault's `_accrueInterest` is this, minus the exchange-rate machinery. Treat cToken as a *reference for the index pattern, not a one-to-one architecture model*: Compound is a pooled, multi-asset market with an exchange rate, while Meridian's vault is a single isolated pair.
2. **Compound `InterestRateModel` (JumpRateModelV2)** — the model interface the vault consumes; Meridian moves the utilization computation to the vault so the definition is shared, but the kink math Ch 21 builds is the same curve.
3. **Aave v3 `Pool.sol` + `ValidationLogic.sol`** — Aave expresses the same separation Meridian uses: the health factor is `collateral · liquidationThreshold / debt` (HF < 1 → liquidatable) while the borrow limit is `collateral · LTV`. Compare `CF` ↔ Aave's LTV and Meridian's `liquidationThreshold` ↔ Aave's `liquidationThreshold`: same axis, same formula — the differences are the single-pair isolation and per-market parameters, not the risk model.
4. **Aave v3 `LiquidationLogic.sol`** — the call flow Ch 24 implements: check HF < 1, apply `closeFactor` and `liquidationBonus`, compute `collateralToSeize = debtToCover · price / collateralPrice · (1 + bonus)`, settle repay + seize. v1's placeholder anticipates exactly this shape.
5. **OpenZeppelin `Math.mulDiv`** — the rounding-direction primitive every formula here uses; the Ch 16 lab pinned its floor/ceil behavior.
6. **Euler (isolated lending) docs** — the borrow-factor/liquidation-factor pair is the production semantics Meridian's `collateralFactor`/`liquidationThreshold` generalize.

## Exercises

1. With `P_c = $1,800`, `CF = 70%`, compute the borrow capacity in USDC of 1.5 ETH (18-dec) with `P_d = $1` (6-dec). Verify against `borrowCapacity`.
2. Derive the health factor for a position exactly at capacity (`LTV = CF`), and show how far the collateral price must fall before HF drops below 1.
3. With `CF = 75%` and `LT = 80%`, state the maximum borrow LTV, the LTV at which liquidation begins, and the size of the safety buffer.
4. A liquidator covers 200 USDC with `B = 10%`, `P_d = $1`, `P_c = $1,500`. Compute the collateral seized in ETH and the liquidator's profit.
5. Trace the borrow index: a user borrows 100 USDC at index 1.0, the index doubles, they borrow another 100. Show the snapshot reset and confirm `debtOf == 300`.
6. Why does `withdrawCollateral` accrue interest but `depositCollateral` does not?
7. Repay the floor amount after an accrual that leaves a fractional debt: what is the remaining debt and why does it stay owed (the Ceil dust)?
8. Read Compound's `borrowFresh` and list three places Meridian's `borrow` diverges (single-asset market, HF-on-borrow, no exchange rate).

## Weekly Project

**`docs/lending-vault-v1.md`, added to the pending docs list:**

1. Write the v1 spec: the two interfaces (`IMeridianVault` error catalog + `IInterestRateModel`), the market parameters, the health-factor and capacity formulas with the lab's pinned numbers (2 ETH → 3,000 USDC capacity at 75%; HF 3.2 at 1,000 USDC), and the rounding-direction table.
2. Document the borrow-index accounting with the worked snapshot example (index doubles, second borrow, `Σ debtOf == totalDebt`).
3. Add the Meridian integration contract: what Ch 22's `getPrice` must deliver (staleness + TWAP fallback), what Ch 21's model receives (the locked utilization definition), and what Ch 24's engine consumes (`isLiquidatable`, `liquidationThreshold`, `liquidationIncentiveBps`, the `liquidate` shape).
4. Confirm the suite is green: `forge test` → **394 passed / 0 failed / 6 skipped (400 total)** across 29 suites; `.gas-snapshot` regenerated under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`, paired `--check` green.
5. Protocol contract count: **3** (MER, gMER, MeridianVault). `IMeridianOracle` promoted from provisional; vault error catalog FINAL.

## Deliverables

1. `src/IMeridianOracle.sol` — extended additively with `getPrice(address)` (Ch 3 ABI pins intact; noted in the ledger).
2. `src/IInterestRateModel.sol` — the vault↔model contract (`borrowRate(utilization)`, kink params); Ch 21 implements it.
3. `src/IMeridianVault.sol` — the FINAL vault error catalog + interface (resolves Ch 2's PROVISIONAL for the vault).
4. `src/MeridianVault.sol` — v1 isolated market core: collateral deposit/withdraw, borrow/repay, HF enforcement, index-based accrual, consumed oracle + rate model, placeholder liquidation hook. **Protocol contract #3.**
5. `test/MeridianVaultMocks.sol` + `test/MeridianVault.t.sol` (50 tests) — happy paths, HF enforcement negatives (borrow above capacity, withdraw below HF, undercollateralized), rounding pins, oracle-price scenarios, non-privileged negatives per guarded path.
6. Full suite **394 passed / 0 failed / 6 skipped across 29 suites**; `.gas-snapshot` 399 rows, `--check` green.
7. Gas profile: deposit **69,653** · borrow **221,988** · repay **214,133** (test-level snapshot rows).
8. Conventions locked: HF floors, capacity floors, debt/index/reserve ceil; snapshot reset on borrow/repay; utilization `= totalDebt/(totalDebt + cash)`; native-unit accounting; every guarded path has a non-privileged negative test.

## Quiz

1. Define borrow capacity and the health factor. Why must HF stay above 1?
2. What is the safety buffer between the collateral factor and the liquidation threshold, and what does it buy the protocol that a liquidation line at `HF = 1` alone would not?
3. With `CF = 75%` and `LT = 80%`, state the maximum borrow LTV, the LTV at which liquidation begins, and the size of the safety buffer.
4. A liquidator covers 100 USDC with a 10% incentive and `P_c = $1,500`, `P_d = $1`. What collateral do they seize, and what is the borrower's penalty?
5. Why is `Σ debtOf(user) == totalDebt` an invariant within v1's state model, and what would break it?
6. State the rounding direction for capacity, HF, debt accrual, and reserve, and connect the wrong direction to a real incident.
7. Name the three reasons a borrow can revert, in the order the vault checks them.
8. Why is Meridian isolated per market pair rather than pooled? Name the containment property and its cost.
9. What does `IMeridianOracle.getPrice` shield the vault from, and where is the manipulation-resistance strategy implemented?

**Answers:** (1) `capacity = collateral·price·CF`; `HF = Σ(collateralᵢ·liquidationThresholdᵢ·priceᵢ)/Σ(debtⱼ·priceⱼ)`; below 1 the debt exceeds LT-discounted collateral — open to liquidation. (2) The safety buffer — LTV between CF and LT, equivalently HF between 1 and LT/CF: liquidations fire at `HF < 1` while the position is still solvent, so the protocol never races the feed to the point where collateral falls below debt; the zone is liquidatable-but-solvent. (3) Borrow up to 75% LTV (`CF`); liquidation begins above 80% LTV (`LT`, HF < 1); the buffer is 5 percentage points. (4) `collateralToSeize = 100 · 1 · 1.10 / 1500 = 0.0733 ETH`; the borrower gives up $110 of collateral to settle $100 of debt — the excess compensates the liquidator (10% nominal incentive). (5) Within v1's tracked borrower state machine, each user stores `{principal, interestIndex}`; debt = `principal·borrowIndex/interestIndex`; borrow/repay reset the snapshot to the current index, so the sum equals `totalDebt` without a loop; never resetting (or resetting stale), or writing off debt, breaks the equality. (6) capacity/HF floor, debt/index/reserve ceil; the wrong direction leaks value per operation — the Balancer V2 ~$128M (Nov 2025) rounding class (Ch 26). (7) Capacity (`BorrowCapacityExceeded`), liquidity (`InsufficientLiquidity`), zero amount (`ZeroAmount`). (8) Isolation contains correlated-collateral contagion — a crash in one market cannot drain others (no shared pool); the cost is per-market parameters and oracle wiring. (9) It hides the spot-vs-TWAP and staleness decisions behind one surface; `OracleRegistry` (Ch 22) implements Chainlink-primary-with-TWAP-fallback so the vault never reads a manipulable spot price.

## Further Reading

- **Compound `CToken.sol` / `Comptroller.sol`** — the borrow-index snapshot pattern and `getAccountLiquidity` this chapter ports (`borrowFresh`, `accrueInterest`, `liquidateBorrowFresh`).
- **Aave v3 `Pool.sol` + `ValidationLogic.sol` + `LiquidationLogic.sol`** — the LTV/liquidation-threshold pair and the liquidation flow Ch 24 mirrors; the mapping is direct — `collateralFactor` ↔ Aave's LTV, `liquidationThreshold` ↔ Aave's `liquidationThreshold` — the same risk model in an isolated, single-pair shell.
- **Euler Finance docs (isolated lending)** — the borrow/liquidation-factor pair and the isolated design rationale Meridian follows.
- **OpenZeppelin `Math.mulDiv`** — the floor/ceil primitive used throughout.
- **Balancer V2 post-mortem (Nov 2025, ~$128M)** — the rounding anchor; full treatment Ch 26.
- **Kelp DAO / Drift (Apr 2026, ~$285–292M, admin keys)** — the privilege-boundary anchor; full treatment Ch 27.
- **Ch 21** (kink model on the utilization definition locked here), **Ch 22** (`OracleRegistry.getPrice`), **Ch 23** (the supply side replacing `supplyDebtLiquidity`), **Ch 24-25** (liquidation engine + the timelock holding `DEFAULT_ADMIN_ROLE`).

## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/20_Lending_Markets_I_Collateral_and_LTV_REVIEW.md`):** health-factor model rewritten to the standard CF/LT separation (borrow limit = collateral × CF; liquidation trigger = LT; HF = collateral × LT / debt; liquidate when HF < 1) — the prior CF/1.05-threshold contradiction removed; effective-liquidation-LTV formula removed; safety buffer = LT − CF; utilization/reserve definition made explicit; mermaid example recomputed (CF 75%, LT 80%).
