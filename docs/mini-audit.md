# Meridian Finance — Full-System Audit Report (mini-audit)

> Ch 39 capstone deliverable (completes the Ch 28 mini-audit commitment).
> Scope: the entire Meridian protocol surface as shipped through Ch 38 —
> tokens (MER, gMER, sMER), the isolated lending vault, oracle registry,
> interest-rate model, factory, upgrade path, and the invariant suites.
> Method per Ch 28: findings ship with evidence; severity ladder
> Critical / High / Medium / Low / Informational; every claim reproduced.

- **Date:** 2026-08-16
- **Auditor:** curriculum pipeline (Ch 39 full-system audit pass)
- **Commits:** findings apply to `main` at `cc43672`; fix landed in the
  follow-up Ch 39 commit.
- **Test evidence:** full suite **537 passed / 0 failed (48 suites)** —
  includes the new `MeridianVaultInvariant` suite (4 invariants, 256 runs,
  16,384 calls each, 0 reverts) and the new unit test
  `test_setCollateralFactor_atOrAboveLiquidationThreshold_reverts`.

---

## Findings

### F-01 — `setCollateralFactor` lacked the LT > CF cross-check — **High (fixed)**

**Location:** `src/MeridianVault.sol`, `setCollateralFactor`.

**Description.** The constructor validates the safety buffer —
`liquidationThreshold * BPS > collateralFactor * WAD` (liquidation threshold
strictly above the collateral factor) — but `setCollateralFactor` checked
only `collateralFactorBps_ > BPS`. Governance could raise the collateral
factor to or above the liquidation threshold, silently erasing the buffer.
At CF == LT a max-borrow position sits at HF == 1, exactly on the
liquidation line; at CF > LT it sits at HF < 1 — **liquidatable on entry**.

**Reproduction (probe, pre-fix).** With LT = 80%, set CF = 90%, deposit
10 ETH @ 2000, borrow to capacity (18,000 USDC = 0.9 × collateral value):

```
HF = collateralValue * LT / debt = 0.9x * 0.8 / 0.9x = 0.889 < 1
isLiquidatable(alice) == true        // position liquidatable on entry
```

Detector-sensitivity probe result: **PASS on pre-fix code, FAIL on fixed
code** (the setter reverts `InvalidCollateralFactor(9000)`) — the finding is
real and the detector turns red exactly when the bug exists.

**Additional evidence.** The existing unit test
`test_setCollateralFactor_updatesCapacity` itself set CF = 8000 with
LT = 0.8e18 — CF == LT, the very boundary the constructor forbids. The test
encoded the bug's premise (buffer == 0 is "fine"); it was corrected to
CF = 7900 as part of the fix.

**Fix.** `setCollateralFactor` now applies the constructor's cross-check:
`if (_liquidationThreshold * BPS <= uint256(collateralFactorBps_) * WAD)
revert InvalidCollateralFactor(...)`. New test
`test_setCollateralFactor_atOrAboveLiquidationThreshold_reverts` pins CF ==
LT and CF > LT reverting and CF just below LT (7999) succeeding; invariant
I4 (`LT * BPS > CF * WAD`) now pins the rule across the whole governance
surface (constructor + both setters) at the state level.

**Severity rationale.** High, not Critical: the vulnerability requires a
compromised or malicious governor (the same trust root the 2026 incidents
calibrate — Ch 25/27/38), and it does not directly move funds; but it
silently removes the protocol's core safety buffer with no error, no event
distinguishing it, and it makes every max-borrow position instantly
liquidatable — exactly the "silent parameter" failure class Ch 38's storage
and ops chapters warn about.

---

### F-02 — v1 `liquidate()` is a stub — **Low (accepted, by design)**

**Location:** `src/MeridianVault.sol`, `liquidate` reverts
`LiquidationNotImplemented`.

**Description.** The liquidation engine is deliberately deferred (Ch 20
scoping; Ch 24-25 teach the patterns on `ReentrancyLab`/`TrustChainLab`
instead). `isLiquidatable` is live and correct; the state machine guarantees
positions only become liquidatable via oracle moves or interest drift, not
user action (invariant I1, frozen-market proof).

**Disposition.** Accepted as documented scoping (ledger entry, Ch 20), not
drift. Revisit when the liquidation engine materializes in a future version;
the invariant suite's I1 is the regression net for that work.

---

### F-03 — `withdrawExcessLiquidity` allows admin to pull idle cash below zero-reserve — **Informational (accepted)**

**Location:** `src/MeridianVault.sol`, `_idleCash` saturates at zero.

**Description.** `_idleCash` returns `balance > reserve ? balance - reserve
: 0`; `withdrawExcessLiquidity` limits withdrawals to idle, so the reserve
claim is never breached by admin withdrawals. Correct as designed; noted
because the saturating behavior means `utilization()` can read 100% while a
reserve remains — informational for downstream dashboards (Ch 37 indexer
should display reserve separately from borrowable liquidity).

---

## Reference audit checklist (per Ch 28 methodology)

| Surface | Check | Result |
|---|---|---|
| Accounting | Rounding: borrow index / interest ceil, capacity / HF floor (Ch 4/16) | ✅ pinned by `MeridianVaultTest` rounding tests + I3 (books exact) |
| Conservation | `sum(debtOf) == totalDebt` under snapshot folding | ✅ invariant I3 (exact under zero-rate model) |
| Collateral | Deposit/withdraw conservation, no double-spend | ✅ invariant I2 (ghost == sum) |
| Health factor | Borrow/withdraw enforce HF line; no self-inflicted liquidation | ✅ invariant I1 + `test_borrow_exactlyCapacity_healthFactorAboveOne` |
| Governance | Setter validation consistent with constructor | ✅ F-01 fixed; I4 pins the rule state-wide |
| Access control | Admin-only setters; non-privileged negatives for every guarded path | ✅ Ch 10 convention, full negative coverage |
| Tokens | MER/gMER/sMER invariants (supply conservation, role rules) | ✅ existing `MeridianTokenInvariant` / `MeridianGovernanceTokenInvariant` suites |
| Upgrades | Proxy admin = Safe, timelock + governor chain (Ch 38) | ✅ `UpgradeLab` + runbook; storage-diff gate (Ch 38 C1) |
| Reentrancy | CEI, no cross-function hazard in vault ops | ✅ vault ops are CEI-clean; `ReentrancyLab` covers the classic paths |

## Invariant suite summary (finalized for capstone)

| Suite | Invariants | Runs / calls | Result |
|---|---|---|---|
| `MeridianVaultInvariant` (NEW, Ch 39) | I1 no-self-inflicted-liquidation, I2 collateral conserved, I3 books exact, I4 buffer positive | 256 / 16,384 each, 0 reverts | ✅ |
| `MeridianTokenInvariant` (Ch 14) | supply conservation, holder completeness | pinned | ✅ |
| `MeridianGovernanceTokenInvariant` (Ch 15) | voting/delegation rules | pinned | ✅ |
| `InvariantLabInvariant` (Ch 26) | arithmetic/invariant-failure detectors | pinned | ✅ |

## Conclusion

One High finding (F-01) — found by the full-system pass, fixed with a
cross-check identical to the constructor's, and pinned by a unit test plus
a state-level invariant (I4). No Critical issues. The v1 scope gaps
(liquidation engine, non-upgradeable vault) are documented design decisions,
not defects. Protocol is ready for the Ch 40 launch checklist.
