# Token Security Patterns

Chapter 16 ended with the vault math that makes `sMER` safe against untrusted value. This chapter is the other half of the "standards-grade tokens that survive an audit" story: **the tokens themselves are not all safe to integrate**. The ERC-20 interface says nothing about whether a transfer actually moves what you asked it to move, whether your balance changes while you are not looking, or whether someone else's code runs in the middle of your transfer. Three classes of token — fee-on-transfer, rebasing, and hook-bearing (EIP-777) — exploit exactly those gaps, and a fourth hazard, the approval race, is baked into the EIP-20 allowance itself.

## Learning Objectives

By the end of this chapter you will be able to:

1. Reproduce the approve-then-transfer race (the two-transaction pattern EIP-20 itself warns about), derive *why* an absolute `approve` is race-prone, and enumerate the mitigation set — two-step `approve(0)→approve(N)`, `SafeERC20.forceApprove`, the v4-era relative helpers, and ERC-2612 permit — with the honest limits of each.
2. Explain **permit griefing**: an attacker front-runs a user's signed permit with the same signature, consuming the nonce, so the user's own permit transaction reverts; derive the integrator rules that follow (bounded values, fresh-nonce resubmission, never assuming a permit tx succeeded).
3. Integrate fee-on-transfer tokens correctly: why naive credit-by-`amount` accounting breaks, the `balanceOf` delta-measurement fix, the mint/burn-fee variants, and why a lending protocol must either handle them or reject them at listing (Ch 20).
4. Account for rebasing tokens: the gons/rate mechanics, why raw-unit ledgers break Ch 16's `totalAssets()`-based vault math, fractional (share-of-balance) accounting as the fix, and how a rebase token differs from a yield-bearing wrapper.
5. Explain EIP-777's hooks and operator model, walk the imBTC/Uniswap v1 incident (Aug 2019), and state why ERC-777 is rarely adopted in new DeFi infrastructure (OpenZeppelin no longer ships an implementation) and why integrators block hook-bearing assets.
6. Apply the defense taxonomy — token feature → accounting trap → safe pattern — as the token-semantics gate for Meridian's market listing, and measure the price of the safe patterns (lab-pinned gas deltas).

## Prerequisites

- **Chapter 14** (ERC20 Deep Dive) — EIP-20 `approve` semantics, ERC-2612 permit, the error catalog, and the OZ v5 fact that `increaseAllowance`/`decreaseAllowance` were **removed** (Ch 14 finding #1); the relative-helper lab here is the v4-era mitigation, kept to show the concept the token no longer ships.
- **Chapter 15** (Governance Tokens) — the shared EIP-712 + nonce space between `permit` and `delegateBySig` (Ch 15 finding #2); permit griefing consumes exactly the nonce that shared space guards.
- **Chapter 16** (ERC4626 Vaults) — `totalAssets()`-reads-the-balance and share accounting; rebasing tokens make `totalAssets` *jump on its own*, and the fractional fix pinned here is Ch 16's share math applied to an elastic asset.
- Supporting: **Ch 2** (custom errors in I-prefix interfaces), **Ch 4** (rounding policy), **Ch 9** (`SafeERC20` returndata gates), **Ch 10** (parameter-exact `vm.expectRevert`), **Ch 12** (the `noFreeAssets` invariant family). Locked conventions remain in force.

## Theory

### Approval races — the two-transaction hazard

EIP-20's `approve` is an **absolute setter**: `allowance(owner, spender) = value`, overwriting whatever was there. That is the entire vulnerability. A user who decides the current allowance of 100 is too much and wants 50 cannot *reduce* — they can only *set* to 50, which is a new transaction. Between their intent and that transaction landing, the mempool is public, and any spender (or a bot watching for the pending tx) can spend the *old* 100 first. Then the stale `approve(50)` lands, and the spender takes another 50. Reach: 150 against an intended 50. EIP-20's own "Note" in the spec warns that a "safe pattern" must be used; the standard ships the hazard and leaves the fix to integrators.

The allowance is a *limit*, not a balance — spending it does not consume the right to receive a new allowance, so a spender watching a reduce-intent captures the old value and then benefits from the new one. The canonical mitigation set:

- **Two-step `approve(0)` → `approve(N)`.** Breaking the overwrite into zero-then-set means a front-run of the *second* step finds a zeroed allowance — it captures only `N`. It does **not** protect the old allowance if the spender acts before the zero step lands (a front-run of `approve(0)` still takes the old 100). Its real role is also to satisfy USDT-class tokens that require a zero allowance before a non-zero one.
- **`SafeERC20.forceApprove`.** OZ's integrator-side helper: tries a single `approve(N)`; *only* when the token returns `false` (the USDT convention) does it fall back to `approve(0)→approve(N)`. On true-returning tokens it is a single approve — it does not force a two-step (Ch 14 finding #4).
- **Relative helpers (`increaseAllowance`/`decreaseAllowance`).** v4-era atomic read-modify-write: `decreaseAllowance(50)` lands at exactly `allowance − 50` in **one transaction**. There is no second tx to front-run; a spender who already drained the old 100 makes the decrease *revert* (`current < delta`) rather than mint a fresh 50 on top. OZ v5 removed them from the token; the lab re-implements the concept to pin the property.
- **`safeApprove` and its pitfalls.** The v3/v4 helper *reverted* unless the allowance was exactly 0 (going to `N`) — a legitimate re-approve at the same value (e.g. refreshing a max allowance) reverted, which broke integrations that periodically topped up. v5 removed it in favor of `forceApprove`; the pitfall class is "a safety helper that rejects benign states".

### ERC-2612 permit — the structural fix, and its own front-run

Permit fixes the race *structurally*: the allowance intent is signed off-chain as an EIP-712 digest containing the exact `value` and a `nonce`, and anyone can submit it. Because the value is pinned in the signature, no front-run can change it — the allowance lands at exactly what was signed. Permit removes the transaction-order race around *choosing* the new allowance value: the signed `value` is fixed and an attacker cannot alter it. It does not erase existing exposure — if an old allowance exists, the signed permit simply overwrites it, and the resulting allowance plus the spender still determines the drain surface.

But permit has its own front-running hazard — **permit griefing**. The attacker takes the user's *same* signed permit and submits it first. It succeeds: the allowance is set to the signed value and the nonce increments. The user's original permit transaction then rebuilds the struct hash with the *current* nonce (OZ v5.7 hashes `_useNonce(owner)` into the struct), the recovered signer no longer matches the owner, and the tx reverts `ERC2612InvalidSigner`. No funds are stolen — the attacker cannot change the signed value — but the user's gas is wasted, their transaction fails, and the spender keeps the allowance. The lab pins this exact sequence.

The structural-fix claim therefore has a caveat: **permit is only a fix if the integrator and UI actually use it and handle its failure mode.** An integrator that submits `approve` in the background still has the race; a UI that assumes a permit tx succeeded leaves the user believing the spender is funded when it is not.

**Derived rules for integrators** (this chapter's checklist, locked):

1. Never overwrite a non-zero allowance with a reduce intent via a single `approve`; use `approve(0)→N` (which bounds only the step after the zeroing has landed), `forceApprove`, or a relative helper.
2. Treat any allowance as a *spendable limit*, not a promise: enforce your own slippage/limit checks at spend time.
3. With permit, always sign against the current on-chain nonce, bound the `value` and `deadline`, and verify the result (event or `allowance` read) — never assume the tx succeeded.
4. On a permit revert, resubmit with a freshly signed digest (the nonce moved); do not retry the same signature.
5. Remember the asymmetry: permit removes the *race* but not the *exposure* — an infinite allowance signed with a max deadline is the same drain surface as an infinite `approve`.

### Fee-on-transfer — balance-delta ≠ transfer amount

A fee-on-transfer token charges a fee on every transfer — burned, or redirected to a fee recipient. The sender pays `value`; the recipient receives `value − fee(x)`. `transferFrom(from, to, amount)` therefore moves `amount − fee`, and **the credited balance delta does not equal the requested transfer amount.** Mint/burn-fee tokens are the same class with the fee on the entry or exit path.

The trap is trivial and catastrophic: an integrator that does `transferFrom(...)` then `credits[user] += amount` records a liability the token never delivered. With a 1% fee, a single full deposit leaves the integrator holding 99 against a recorded 100 — the redeemer can never be paid in full (the lab's `NaiveFeeIntegrator` reverts on its own withdrawal). This accounting mismatch has repeatedly appeared in integrations for fee-on-transfer tokens.

The correct pattern is the **measured delta**:

```
uint256 before = token.balanceOf(address(this));
token.safeTransferFrom(from, address(this), amount);
uint256 received = token.balanceOf(address(this)) - before;
credits[to] += received;
```

Now `Σ credits == real balance` stays true by construction and every credit is backed. The price is two extra external `balanceOf` reads — measured at +1,955 gas per deposit on a warm token (Foundry Lab).

**Integration checklist:** (1) never trust `amount` as received — measure the delta per operation; (2) if the token is held for multiple purposes, measure per-operation, never from a cumulative ledger a donation could pollute; (3) fees may round — account for the dust floor; (4) **lending (Meridian's model, Ch 20):** a fee-on-transfer *collateral* arrives short, so a naive `deposit 100 → credit 100` instantly undercollateralizes the position, and a fee-on-transfer *borrow* token delivers less than the recorded debt — insolvency. Either handle with delta-accounting *and* fee-aware LTV, or **reject the token at listing**; the listing gate (Production Example) is where that decision is made. Delta accounting is the correct pattern for *supported* fee-on-transfer semantics, subject to the token's reentrancy/trust model — a fully adversarial token (reentrancy, behavior changes between calls, asymmetric fees) is a listing decision, not an accounting fix.

### Rebasing tokens — elastic supply

A rebasing token (AMPL is the canonical example) multiplies every holder's balance by a factor on a schedule. Positive rebase: supply up, balances grow. Negative: supply down, balances shrink. A common O(1) implementation — the **gons** scheme, an instance of index-scaling — stores balances in a fixed base unit ("gons") and applies a single global scaling factor (`rate`) to map them to real units,

```
balanceOf(a) = gons[a] · rate / BASE        totalSupply = totalGons · rate / BASE
```

A rebase changes only `rate`, so every balance scales together with one state write — no per-account loop. The lab's `RebasingToken` implements exactly this.

The trap for integrators is Ch 16's vault math colliding with an elastic asset: **`totalAssets()` jumps on its own.** A vault that reads `balanceOf(vault)` sees the balance change after every rebase; a vault that instead tracks raw deposited units drifts. With raw-unit accounting, a *positive* rebase makes the vault hold more than it recorded (free value no share claims — either stuck or sweepable), and a *negative* rebase makes it hold less than it owes (the last redeemer is insolvent). The lab pins both.

Rebasing tokens are **not** the same as yield-bearing wrappers. A share/exchange-rate wrapper (cToken, sMER) keeps your `balanceOf` units fixed while the value per unit changes — though not every yield-bearing token follows that shape (Aave's aTokens, for example, are themselves rebasing). A rebaser changes supply and holder balances through a protocol-defined scaling factor; its market price is a separate property — a positive rebase grows your `balanceOf` directly. Both deliver "yield," but the integration traps are inverted: tracking `balanceOf` over time is fine for a wrapper and wrong for a rebaser, because the rebaser's growth arrives as a balance change with no deposit.

**Accounting strategies:** (1) **Fractional (share-of-balance) accounting** — the lab's `FractionalRebaseVault`: `totalAssets()` reads the live balance, deposits mint shares proportionally, redemptions pay a pro-rata slice of the current balance. Because a rebase scales every holder together, the split is invariant under rebase — no free value, no insolvency. This assumes the rebase scales holders proportionally, with no holder-specific exemptions, transfer taxes, or other asymmetric balance mutations. This *is* Ch 16's share math applied to an elastic asset. (2) **Wrap it** — hold the rebasing token inside an ERC4626 vault; the share price absorbs rebases (same math, expressed as a wrapper). (3) **Whitelist/reject** — many lending protocols refuse rebasing collateral, or accept only LSTs with known schedules, because *debt* accounting is ambiguous: does a positive rebase accrue to the borrower or the protocol? Aave's early listings and Compound's cToken whitelist are the governance-gated versions; Meridian's Ch 20 listing gate audits for the feature.

### EIP-777 — hooks, operators, and why it lost

EIP-777 (2017) was ERC-20's would-be successor. It added three things ERC-20 deliberately lacks:

- **`tokensToSend` / `tokensReceived` hooks** — a mandatory callback to the sender and recipient on every ERC-777 transfer. A contract recipient must register its hook through ERC-1820, and `tokensReceived(operator, from, to, amount, userData, operatorData)` must return the magic value `bytes32(keccak256("ERC777TokensRecipient"))` or the transfer **reverts** — transfers to contracts that do not acknowledge the hook are rejected.
- **An operator model** — `authorizeOperator` grants a third party the right to move the *full* balance via `operatorSend`, a far larger grant than an allowance, revocable only by `revokeOperator`.
- A native `send`, and a `granularity` notion.

The hooks are the problem: every transfer to a contract makes a mandatory external call into arbitrary code, *after* balances move (OZ v4's `_send` ordering: `tokensToSend` → move → `tokensReceived`). That is a reentrancy and DoS vector embedded in the asset itself, and it is incompatible with every protocol that assumes transfers are silent.

**The imBTC/Uniswap v1 incident (Aug 2019).** imBTC was an ERC-777 wrapped bitcoin. The attacker deployed a contract whose `tokensReceived` hook re-entered Uniswap v1's ETH–imBTC pool mid-swap. Uniswap v1 updated its reserve accounting *after* the external token transfer, so while the callback was executing the pool's state was stale and the attacker could swap back and forth, extracting more than they paid on each pass. The drain was roughly **$8.5M from the Uniswap v1 pool**, and roughly **$24M in total** once the same token was drained across Uniswap and Bancor pools. (Ch 14's grounding cites the Uniswap v1 figure; the total is the cross-pool number.) The fix class is exactly CEI — update state before the external call — and a reentrancy guard.

Why ERC-777 is rarely adopted in new DeFi infrastructure: the mandatory hooks broke composition with every protocol written against silent transfers; OpenZeppelin deprecated its ERC777 implementation in v4 and **removed it in v5** (the interfaces remain available; confirmed against the pinned v5.7 lib); and integrators may choose to ship *interaction blocklists* — a `token → blocked` mapping checked before any transfer, reverting `ERC777InteractionForbidden` when set. The lab demonstrates the attack shape with a simplified hook token and the CEI fix; the Production Example generalizes the blocklist into a full token-semantics registry.

### The defense taxonomy

| Token feature | Accounting trap | Safe integration pattern |
|---|---|---|
| Absolute `approve` (EIP-20) | Stale allowance = extended reach on reduce | `approve(0)→N` (bounds the second step only) / `forceApprove` (compatibility fallback) / relative helpers / permit with bounded value |
| ERC-2612 permit | Permit griefing: nonce consumed, user tx fails | Sign against current nonce; bounded value+deadline; resubmit fresh on revert |
| Fee-on-transfer | Credited ≠ transferred → insolvency | `balanceOf` delta measurement; or reject at listing |
| Mint/burn fee | Nominal ≠ delta on entry/exit | Delta accounting both sides; or reject |
| Rebasing (elastic supply) | Raw-unit ledger drifts; `totalAssets` jumps | Fractional/share accounting; 4626 wrapper; or reject |
| EIP-777 hooks | Callback reentrancy; mandatory external call | CEI + guard; interaction blocklist; or reject |

## Mathematical Foundations

### The allowance race, formalized

Let the allowance be an absolute variable `A` set by `approve`. The owner wants `A` reduced from `100` to `50`. With a single overwrite `approve(50)`, the spender can act between intent and execution:

```
reach = A_old + A_new = 100 + 50 = 150        (spend old, then stale set lands)
```

With a relative decrease `decreaseAllowance(50)` — one atomic read-modify-write — the only transaction is the decrease itself, and a spender who already spent the old 100 leaves `A = 0 < 50`, so the decrease **reverts** rather than minting a fresh allowance:

```
if A ≥ 50:  A' = A − 50        (one atomic read-modify-write)
else:       revert             (drained: current < delta)
reach ≤ A_old = 100
```

The asymmetric reach — `old + new` for an absolute setter, `old` for a relative one — is the entire mathematical content of the race. With permit, the intent is a signed pair `(value, nonce)`; a front-run cannot alter `value`, so the formal cost of permit griefing is the user's gas plus a nonce consumed by the attacker's *successful* submission (the victim's replay then reverts) — no allowance inflation.

### The fee-on-transfer solvency identity

Let a token charge `f(x)` on a transfer of `x`. Then

```
transferFrom(from, to, x)  ⇒  Δ balanceOf(to) = x − f(x)
```

An integrator that credits `c` per deposit must satisfy the solvency invariant `Σ credits ≤ real balance`. The naive credit `c = x` violates it the moment `f > 0` (shortfall `Σ f(x)`); the delta measurement enforces `c = x − f(x)` per operation, so the identity holds *by construction*.

### Gons and the rebase invariant

With `rate` fragments per gon (scaled by `BASE`):

```
balanceOf(a) = gons[a] · rate / BASE
```

A rebase by factor `k` sets `rate' = rate · k`, so every holder's *fraction* of the supply is invariant:

```
gons[a] / totalGons = balanceOf(a) / totalSupply          (unchanged by rebase)
```

because both numerator and denominator scale by `k`. That invariance is exactly why **fractional accounting works**: a share of the current balance is a share of a proportionally scaled pool. Raw-unit accounting instead fixes the *numerator in token units* (`totalTracked`), which does not scale — a positive rebase (`k > 1`) leaves `balance > tracked` (free value), a negative one leaves `balance < tracked` (insolvency). The lab measures the divergence via `surplus() = int(balance) − int(tracked)`.

One honest wrinkle pinned in the lab: `balanceOf` floors per account, so `Σ balanceOf ≤ totalSupply` with a gap of at most a fragment per account (the AMPL micro-dust). Conservation holds within that slack.

### The callback reentrancy condition

A callback-bearing token lets a transfer run arbitrary recipient code. The reentrancy condition is the ordering of the integrator's own state update relative to that call:

```
state update AFTER external transfer  ⇒  reentrant call observes stale state   (vulnerable)
state update BEFORE external transfer ⇒  reentrant call observes fresh state   (CEI, prevents this stale-state path)
```

The reward-pool lab makes the economics explicit: the pool owes 1, holds 5, and updates `rewards[msg.sender] = 0` *after* the transfer — so each reentrant `claim` sees an un-zeroed balance and the pool drains its full 5 for a debt of 1. Reordering to CEI makes the reentrant call read a zeroed balance, revert, and roll back the whole attack. CEI prevents this stale-state path specifically; additional external-call and cross-function reentrancy analysis may still be required (Ch 24).

## Engineering Perspective

For Meridian, this chapter is the design rationale behind Ch 14's deliberately boring token. MER is hookless, fee-free, and non-rebasing **so that every downstream integrator — sMER (Ch 23), the vault (Ch 20-22), the governor (Ch 25) — can assume transfers are silent and balances are stable.** A protocol token that charges a transfer fee poisons every accounting surface that holds it; MER's fee capture lives in the lending spread, not the token (Ch 14).

But Meridian's *markets* take arbitrary assets. The engineering answer is a **listing gate, not defensive heroics**: before a token becomes a market, the protocol audits its transfer semantics — fee-on-transfer (measure a test transfer), rebase (elastic-supply events/bytecode), hooks (`tokensReceived`/`operatorSend`), pausability, upgradeability — and either handles the feature with the patterns above or refuses the listing. The defense taxonomy table is the gate's checklist; the Production Example sketches the registry contract that encodes it.

The 2026 grounding keeps this honest. **Balancer V2's ComposableStablePool (~$128M, Nov 2025)** was a *rounding* failure in token accounting — the `conversionsNeverGain` family Ch 16 pinned — and it lived in a pool holding exotic tokens; token-accounting correctness is a live exploit class, not history. **Kelp DAO/Drift (~$285–292M, Apr 2026)** were admin-key incidents: the key that flips a token from `handled` to `rejected` is a trust root in the same league as the multisig. On L2s (post-Fusaka, PeerDAS/EIP-7594 live, BPO scaling), the *gas* of listing checks is cheaper, but the accounting rules are chain-agnostic — the same gate runs on every Meridian deployment (Ch 30/31).

## Mermaid Diagram

```mermaid
sequenceDiagram
    participant A as Alice (owner)
    participant B as Bob (spender)
    participant M as Mempool / front-runner
    participant T as LabToken (EIP-20)

    Note over A,T: THE RACE (single absolute approve)
    A->>T: approve(Bob, 100)
    A->>M: approve(Bob, 50)   // reduce intent: 100 -> 50
    M->>T: transferFrom(Alice, Bob, 100)  // front-run the OLD allowance
    T->>T: allowance 100 -> 0, Bob +100
    A->>T: approve(Bob, 50)   // stale intent lands
    M->>T: transferFrom(Alice, Bob, 50)   // NEW allowance spent too
    Note over T: Bob holds 150 vs Alice's intended 50

    Note over A,T: THE FIX (one relative tx)
    A->>T: decreaseAllowance(Bob, 50)     // single atomic read-modify-write
    Note over T: allowance 100 -> 50 in ONE SSTORE; no second tx to front-run
    B->>T: transferFrom(Alice, Bob, 100)  // fails: ERC20InsufficientAllowance

    Note over A,T: THE STRUCTURAL FIX (permit)
    A->>A: sign permit(50, nonce 0) off-chain
    Note over A,M: attacker front-runs the SAME signature
    M->>T: permit(50, v, r, s)   // succeeds, nonce 0 -> 1
    A->>T: permit(50, v, r, s)   // reverts ERC2612InvalidSigner
    Note over T: no funds lost, but Alice's tx fails and nonce is burned
```

## Code Walkthrough

The lab spans two source files plus a shared interface: `meridian/src/ITokenSecurityLab.sol` (the error catalog — `ZeroAmount`, `InsufficientBalance`, `ZeroAddress`, `HookNotAccepted`, `RebaseOutOfBounds` — declared on the interface per the Ch 2/14 canon), `meridian/src/TokenSecurityLab.sol` (the race, fee, and rebase contracts), and `meridian/src/Reentrancy777Lab.sol` (the simplified EIP-777 demo).

**Approval race.** `LabToken` is a plain OZ ERC20 — `approve` is the standard absolute setter, race-prone exactly as EIP-20 ships it. `LabTokenWithHelpers` adds `increaseAllowance`/`decreaseAllowance`, the OZ v4 pattern removed in v5, each a single `_approve` from the *current* allowance; the `decreaseAllowance` guard (`current < delta` → `InsufficientBalance`) is the line that bounds the race — a spender who drained the old 100 leaves `current = 0`, so the reduce reverts instead of minting a fresh allowance. The permit tests run against MER itself (Ch 14's `MeridianToken`), reusing the Ch 14 signing helpers, so the structural fix is demonstrated on the protocol's own token.

**Fee-on-transfer.** `FeeOnTransferToken` overrides `_update` to burn a 1% fee on real transfers (mint/burn paths stay fee-free). `NaiveFeeIntegrator.deposit` does `safeTransferFrom` then `credits[msg.sender] += amount` — the bug. `DeltaFeeIntegrator.deposit` reads `balanceOf(this)` before and after the pull and credits the received delta — the fix. Both expose the same `redeem`, so the only difference is what was credited, and the insolvency is visible in one line: `credits(alice) == 100` while `fee.balanceOf(vault) == 99`.

**Rebasing.** `RebasingToken` stores gons and a `rate`; `balanceOf(a) = gons[a]·rate/BASE`, and `rebase(bps)` moves only `rate` (`rate · (10000±bps)/10000`, guarded so a negative rebase cannot drive it to zero). `NaiveRebaseVault` tracks `totalTracked` in token units and pays 1:1 — the broken ledger whose `surplus()` goes positive after a positive rebase and negative after a negative one. `FractionalRebaseVault` reads `totalAssets()` from the live balance and mints/redeems shares proportionally — the Ch 16 answer, exact in the lab up to the per-account gons floor.

**EIP-777 (simplified, clearly labeled).** `HookToken` implements a full IERC20 surface plus two dangerous EIP-777-style features: a mandatory `tokensReceived` call on any transfer to a contract, and the magic-value check (`0x6a761202`) that rejects transfers to non-accepting recipients. `ReentrantRewardPool.claim` pays the reward *before* zeroing the claimable balance; `ReentrantAttacker.tokensReceived` re-enters `claim` while the balance is still un-zeroed, guarded only by "the pool still has tokens" so it stops when the pool is dry. `FixedRewardPool.claim` is the one-line CEI fix. This is not a full ERC-777 implementation (no operator model, no `tokensToSend`) — it preserves the two properties that matter for the incident, the callback ordering and the state-update-after-transfer bug.

## Production Example

**The token-semantics listing gate for Meridian markets (Ch 20).** The lab's contracts are the *proof* for a registry Ch 20 will own. The registry stores, per listed token, a `Semantics` struct derived at listing time: `feeOnTransfer` (set by transferring a dust amount through a test deposit and measuring the delta), `rebasing` (elastic-supply bytecode/logs, or a balance change with no transfer across one rebase interval), `erc777Hooks` (`tokensReceived`/`operatorSend`-shaped selectors, or the token is on a maintained blocklist), and the operational flags `pausable`/`upgradeable`/`hasFeeRecipient` that Ch 25's trust surface cares about. Listing-time classification is not permanent evidence: for `upgradeable` tokens, an implementation upgrade can change transfer semantics after approval, so the registry needs a post-listing monitoring or governance policy (the upgradeable-token case Ch 25 owns).

Every integration path checks the struct before touching the token: `if (sem.erc777Hooks) revert ERC777InteractionForbidden(token)`; `if (sem.feeOnTransfer) { ...delta-accounting only... }`; `if (sem.rebasing) { ...fractional accounting only, or reject... }`. The `token → blocked` mapping generalizes the post-imBTC ERC-777 interaction-blocker pattern — a per-token blocklist several routers adopted for hook-bearing assets — extended to the other trap classes. Real-world counterparts: Compound's `Comptroller.marketAssets` and Aave's reserve-listing governance are the whitelist gates that make "an unaudited token cannot become a market" structural; Maker's per-token adapters encode the same per-asset semantics.

The registry's own key is a trust root: whoever can set `erc777Hooks = true` or flip a market to `rejected` can freeze a listed asset. That is the Kelp DAO/Drift lesson — a listing key is an admin key, and it belongs in the Ch 25 timelock, not a deployer wallet.

## Foundry Lab

Materialized and **compile-verified in this run** (forge 1.7.1, solc 0.8.24, cancun, optimizer 200):

- **New artifacts:** `src/ITokenSecurityLab.sol`, `src/TokenSecurityLab.sol` (LabToken, LabTokenWithHelpers, FeeOnTransferToken, NaiveFeeIntegrator, DeltaFeeIntegrator, RebasingToken, NaiveRebaseVault, FractionalRebaseVault), `src/Reentrancy777Lab.sol` (HookToken, ReentrantRewardPool, FixedRewardPool, ReentrantAttacker, PassiveHookRecipient, WrongMagicRecipient), `test/TokenSecurityLab.t.sol` (20 tests incl. 1 fuzz + 2 gas probes), `test/Reentrancy777Lab.t.sol` (6 tests incl. 1 gas probe). All Ch 1-16 suites untouched and green.
- **Full repo suite: 246 passed / 0 failed / 6 skipped (252 total) across 24 suites** (Ch 16 baseline 220/0/6 across 22; +26 tests, +2 suites). The 6 skips remain the Ch 11 fork tests (RPC-gated).
- **Gas probes (loop-amplified min-deltas, warm-up first):** delta-accounting deposit **10,109** vs naive **8,154** (+1,955 — the price of two `balanceOf` reads); hook-token transfer to a contract **7,638** vs EOA **4,769** (+2,869 — the mandatory callback); gons `balanceOf` **1,514** vs plain ERC20 **1,157** (+357 — the extra SLOAD + `mulDiv`).
- **Real findings, all kept:** (1) **Ch 14 finding #3 recurred a fourth time** — `vm.prank(alice)` was consumed by the `fracRebase.shares(alice)` view call in the redeem argument, so `redeem` ran as the test contract with 0 shares (`InsufficientBalance(0, 4176)`); the share reads are hoisted before the prank. (2) The AMPL micro-dust is real: gons `balanceOf` floors per account, so `Σ balanceOf ≤ totalSupply` by up to a fragment per account — an "exact" conservation fuzz assertion failed by 1 wei; the bounded form is the honest invariant. (3) `decreaseAllowance` after a drain reverts rather than minting on top — the race-bound property, pinned as its own test. (4) The fixed-pool `vm.expectRevert` initially expected the wrong error because the reward was granted to the *first* attacker (whose pool is the naive one); the test now creates the attacker before granting.

## Security Analysis

**1. The approval race is an EIP-20 design fact, not an integration bug.** The absolute setter + separate spend transaction make `reach = old + new` on a reduce. The lab's race tests pin the asymmetry: single `approve` gives 150, `decreaseAllowance` at most 100 (and reverts after a drain), the two-step bounds the *new* step, permit pins the value by signature. The residual honesty: no on-chain sequence protects the *old* allowance from a spender watching a reduce — the front-run-of-zero-step test shows reach 150 again. The defenses raise the cost and remove the *automated* capture, not the watchful spender.

**2. Permit griefing is a DoS, not a theft.** The front-run consumes the nonce and wastes the user's gas; the allowance lands with the signed value either way. Its severity is UX and integrator-correctness (a UI that ignores a reverting permit misleads the user), and its fix is operational: sign against the current nonce, bound value/deadline, resubmit fresh on revert. Worth holding alongside Ch 15's finding that a *stale* signature cannot burn a nonce — the failed permit burns nothing; only a *successful* one does, which is exactly what the front-run forces.

**3. The EIP-777 callback is the reentrancy class Ch 1's CEI and Ch 24's full treatment exist for.** The reward-pool lab drains 5 for a debt of 1 because the state update follows the external transfer. imBTC/Uniswap v1 (Aug 2019, ~$8.5M pool / ~$24M cross-pool) is the canonical proof that this class is worth tens of millions on one pool. Two layers: the integrator's own CEI/guard ordering (the lab's `FixedRewardPool`), and the ecosystem's refusal — interaction blocklists that keep hook tokens out. Modern code should not need to be *clever* with ERC-777; it should refuse the asset.

**4. Token-accounting failures are the 2026 live class.** Balancer V2 ComposableStablePool (Nov 2025, ~$128M) was a rounding failure in token accounting inside a pool holding exotic tokens — the `conversionsNeverGain` family, not a reentrancy. The fee-on-transfer and rebase labs are the same *family*: an asset whose transfer semantics disagree with the integrator's ledger. The invariant `Σ credits ≤ balance` (fee) and the fractional share split (rebase) are the prophylactics; Ch 26 treats the rounding subclass in full.

**5. The trust surface is the listing key.** Every mechanism here is only as safe as the gate that admits assets. Kelp DAO/Drift (~$285–292M, Apr 2026) were admin-key incidents — the listing registry, the fee-recipient key, the blocklist owner are all privileged surfaces. Meridian's answer (Ch 20 listing gate + Ch 25 timelock) is to make "which tokens may be markets" a governed decision, not a deployer's.

## Common Mistakes

1. **Reducing an allowance with a single absolute `approve`.** The spender captures `old + new`; use two-step `approve(0)→N` (it bounds only the step after the zeroing has landed), `forceApprove`, or a relative helper.
2. **Assuming `safeApprove` is a fix.** It reverts on legitimate states (re-approving a max value) and is removed in v5; `forceApprove` is the successor.
3. **Believing permit ends the story.** Permit kills the race but not permit griefing (nonce burn, failed tx) and not exposure (a max-value/max-deadline signature is a standing drain).
4. **Crediting `amount` on a fee-on-transfer deposit.** The 1% fee makes the integrator insolvent on the first full deposit — the lab reverts on its own withdrawal; measure the delta per operation, never from a cumulative ledger a donation could pollute.
5. **Tracking raw token units through a rebase.** Positive rebase → free value (stuck or sweepable); negative rebase → insolvency. `totalAssets()` must read the live balance (Ch 16) or the vault must be share-based.
6. **Confusing a rebaser with a yield wrapper.** A wrapper keeps your `balanceOf` units fixed while the value per unit changes; a rebaser changes balances and supply through a protocol-defined scaling factor (its market price is a separate property). The accounting fix for one is wrong for the other.
7. **Integrating an EIP-777 token without a blocklist or guard, or updating state after the payout transfer.** The mandatory callback is a reentrancy and DoS surface (the imBTC drain is the proof); state-update-after-transfer is the reentrancy condition. Refuse the asset, or CEI + guard + exact callback ordering.
8. **Treating the listing gate as an engineering detail.** The key that admits or rejects assets is a trust root (Kelp DAO/Drift class); it belongs in the timelock.

## Gas Optimization

The safe patterns have a measured cost, pinned in this run (loop-amplified min-deltas, warm-up first):

- **Delta-accounting deposit: 10,109 vs naive 8,154 → +1,955 gas.** Two external `balanceOf` reads are the entire premium — the price of not being insolvent, paid once per deposit. No optimization removes it without reintroducing the trap (a cached "previous balance" is stale-cache territory, Ch 8, and breaks the moment a donation or direct transfer lands).
- **The EIP-777 mandatory callback: 7,638 vs 4,769 → +2,869 gas** for a transfer into a hook-bearing contract — an external CALL into the recipient's code *before* any of the integrator's own logic. This is why the efficient path is refusal, not measurement: the blocklist saves the integrator from paying this on every interaction.
- **Gons `balanceOf`: 1,514 vs 1,157 → +357 gas** — the elastic-supply tax on every read: one extra SLOAD (the rate) plus a full-precision `mulDiv`; fractional vaults pay it on `totalAssets()`.

Per the Ch 8 hierarchy (remove, cheapen, measure): the delta reads and the hook call are *correctness*, not fat — the only legitimate gas win is removing the interaction entirely (reject/blocklist the token), which is exactly what the listing gate does.

## Reading Production Source Code

1. **EIP-20** — read the `approve` function and its Note; the spec literally warns about the pattern this chapter exploits. Then read EIP-2612's `permit` and the nonce semantics that permit griefing touches.
2. **OpenZeppelin `SafeERC20.sol` (v5.7)** — `safeTransfer`/`safeTransferFrom` are the Ch 9 returndata gates; `forceApprove` is the two-step fallback for false-returning tokens. This is the file every Meridian integration inherits.
3. **OpenZeppelin v4 `ERC777.sol`** (in the lib's git history; removed in v5) — read `_send`: `tokensToSend` → move → `tokensReceived`, and the magic-value check. Seeing the exact ordering makes the reentrancy condition in this chapter's lab concrete. The v5 removal is the ecosystem's verdict.
4. **A real lending protocol's token gate** — Compound's `Comptroller` (`marketAssets`, `supportMarket`) and Aave's reserve-listing flow: how "an unaudited token cannot become a market" is made structural. Look for *who* can list, *what* semantics they check, and *what happens* when a listed token's behavior changes (the upgradeable-token case Ch 25 owns).
5. **Uniswap v2 pair's token handling** — `_safeTransfer`, the `balanceOf`-based reserve sync, and the `lock` modifier: v2's answer to the v1-class holes this chapter covers (reentrancy lock + state-from-balance, not cached state). Compare against v1's transfer-then-update ordering to see the fix family in the wild.

Ask of every token you integrate: *does the balance move by exactly what I asked, does it move while I am not looking, and does anyone else's code run in the middle of my transfer?* If the answer to the last is yes, the interaction is a security review, not a transfer.

## Exercises

1. Hand-trace the race in a table: for `test_approvalRace_staleApprove_grantsMoreThanIntended`, write `(allowance, bobBalance)` after each of the four transactions and confirm the reach is 150. Redo the table for the `decreaseAllowance` variant and confirm the reach is bounded by 100 — and state *which single line* in `LabTokenWithHelpers` enforces the bound.
2. Prove the permit-griefing digest mismatch: in `test_permit_griefing_frontRun_burnsNonce`, rebuild the permit digest with nonce 1, recover the signer with `ECDSA.recover`, and confirm it is not Alice. Explain why OZ v5.7's `permit` produces `ERC2612InvalidSigner` rather than `InvalidAccountNonce` (which line hashes the nonce into the struct?).
3. For a 1% fee-on-transfer token, compute the ledger after two deposits of 100 into `NaiveFeeIntegrator`, then show the second redeemer's failure. Repeat with `DeltaFeeIntegrator` and show the ledger stays exactly backed.
4. Take `NaiveRebaseVault` through a +50% rebase after two 100 deposits and compute `surplus()` at each step (deposit, rebase, redeem, redeem). Then re-derive why `FractionalRebaseVault` pays 150 per 100-share redemption and leaves no free value. The gons floor makes the naive surplus 102, not 100 — find where the extra 2 comes from.
5. Extend the hook token with a `tokensToSend`-style hook on the sender that fires *before* balances move. Does `test_naivePool_drainedByHook` still drain? Re-trace the ordering and state whether the extra hook helps or changes nothing (the vulnerable state-update-after-transfer line is the real bug).
6. Read OZ v4 `ERC777.sol` `_send` and write the minimum change to `ReentrantRewardPool.claim` that defeats `ReentrantAttacker` — then confirm the lab's `FixedRewardPool` is that change and `test_fixedPool_attackReverts_noDrain` pins it.

## Weekly Project

**The token-semantics gate — specced, not implemented (Ch 20 owns it):**

1. Write the `Semantics` struct and `TokenSemanticsRegistry` interface skeleton (LAB shape from the Production Example): per-token `feeOnTransfer`/`rebasing`/`erc777Hooks`/`pausable`/`upgradeable` flags, a `reject(token)`/`handle(token)` surface, and the `ERC777InteractionForbidden`-style error. Do **not** write the full registry — that is Ch 20's deliverable; this week is the contract the audit must satisfy.
2. Add `docs/token-security-patterns.md` to the pending weekly-docs debt list: the defense taxonomy table, the integration checklist, the measured gas table (delta +1,955, hook +2,869, gons `balanceOf` +357), and the listing-gate contract for Ch 20.
3. Confirm the lab suite is green: `forge test` → **246 passed / 0 failed / 6 skipped (252 total)** across 24 suites. The `.gas-snapshot` regenerated under the pinned CI seed.
4. Protocol contract count: **still 2** (MER, gMER). No protocol source changed; the lab is LAB ONLY.

## Deliverables

1. `src/ITokenSecurityLab.sol`, `src/TokenSecurityLab.sol`, `src/Reentrancy777Lab.sol` — the four-trap lab (race + relative/permit fixes, fee integrators naive/fixed, rebase vaults naive/fractional, simplified EIP-777 drain + CEI fix), compile-verified in-run.
2. `test/TokenSecurityLab.t.sol` + `test/Reentrancy777Lab.t.sol` — 26 tests all green; repo suite **246 passed / 0 failed / 6 skipped across 24 suites**.
3. Conventions locked: the derived integrator rules for approvals/permit; the fee delta-measurement pattern; the fractional share-of-balance fix for rebasers; the CEI ordering fix for hook tokens; the blocklist→registry generalization.
4. Gas profile: delta deposit 10,109 vs naive 8,154 (+1,955) · hook transfer 7,638 vs EOA 4,769 (+2,869) · gons `balanceOf` 1,514 vs ERC20 1,157 (+357).
5. The token-semantics listing gate specced for Ch 20 (Semantics struct + registry contract).

## Quiz

1. Why is `approve` race-prone and `decreaseAllowance` not? Give the `reach` arithmetic for a 100→50 reduce under both.
2. What does permit griefing actually take from the user, and what does it *not* take? What is the exact OZ v5.7 revert on the burned permit?
3. An integrator credits `amount` after a 1% fee-on-transfer deposit of 100. Show the insolvency and the one-line fix.
4. A vault holds a rebasing token and tracks deposits in token units. What happens on a +50% and a −50% rebase, and what is the fix?
5. What is the difference between a rebasing token and a yield-bearing wrapper, and why does the difference change the integration trap?
6. Why did imBTC drain Uniswap v1 (state ordering), and what two layers prevent the class today?
7. Why is the listing-gate key a trust root, and where does Meridian plan to hold it?

**Answers:** (1) `approve` is an absolute setter in its own transaction, so a spender captures the old value *and* the stale new value (reach 150); `decreaseAllowance` is an atomic read-modify-write in one transaction, so reach is bounded by the old value (100), and after a drain it reverts rather than minting on top. (2) It takes the user's gas and burns a nonce — their permit tx reverts `ERC2612InvalidSigner` because the struct hash now uses the current nonce. It does not take funds or change the signed value, and the spender keeps the allowance. (3) `credits[user] += amount` records 100 while the vault holds 99, so a full redeem cannot be paid; fix with `received = balanceOf(this) − before` after the pull. (4) +50% → the vault holds more than it owes (free value); −50% → it owes more than it holds (the last redeemer is insolvent); fix by reading `totalAssets()` from the live balance and paying pro-rata shares. (5) A share/exchange-rate wrapper (cToken, sMER) keeps your `balanceOf` units fixed while the value per unit changes; a rebaser changes supply and holder balances through a protocol-defined scaling factor, and its market price is a separate property (your `balanceOf` grows on a positive rebase). Tracking `balanceOf` over time is correct for the wrapper and wrong for the rebaser, because the rebaser's growth arrives as a balance change with no deposit. (6) Uniswap v1 updated reserves *after* the external token transfer, so the ERC-777 `tokensReceived` callback re-entered with stale state; today the layers are CEI/guard ordering in the integrator and interaction blocklists that keep hook tokens out. (7) The key that admits or rejects assets controls what value the protocol holds; Kelp DAO/Drift are the 2026 proof — Meridian plans to hold it in the Ch 25 timelock.

## Further Reading

- **EIP-20** (`approve` and its Note) and **EIP-2612** (`permit`, nonces) — the spec text behind the race and the structural fix.
- **EIP-777** (Final) — the hook/operator spec; read it alongside OpenZeppelin v4 `ERC777.sol` and the v5 removal. The imBTC/Uniswap v1 incident (Aug 2019, ~$8.5M pool / ~$24M cross-pool) is documented across the public post-mortems; Ch 24 generalizes the reentrancy class.
- **OpenZeppelin `SafeERC20.sol` (v5.7)** — the returndata gates (Ch 9) and `forceApprove`; and **`ERC4626.sol`** for the share-of-balance math the rebase fix reuses (Ch 16).
- **AMPL (Ampleforth)** — the gons/rate mechanics and the per-account floor (`Σ balanceOf ≤ totalSupply`) the lab pins.
- 2026 security grounding: **Balancer V2 ComposableStablePool (Nov 2025, ~$128M, token-accounting rounding — full treatment Ch 26)**; **Kelp DAO/Drift (Apr 2026, ~$285–292M, admin keys — the listing key is a trust root, Ch 25)**.
- Ch 14 (MER's design and the permit catalog), Ch 20 (the market-listing gate that consumes this chapter's taxonomy), Ch 24 (reentrancy), Ch 25 (the timelock that holds the listing key), Ch 26 (the rounding failure class).

## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/17_Token_Security_Patterns_REVIEW.md`):** approve(0)→N race limitation promoted to the formal taxonomy; decreaseAllowance modeled as revert-on-drain (not max-saturation); rebase reframed (scaling mechanism, market price separate — no stable-price claim); wrapper/rebase distinction qualified (aTokens rebase); ERC-777 wording scoped to hook semantics + OZ v4-deprecation/v5-removal (interfaces remain); permit griefing = nonce consumed by the successful front-run, stale signatures burn nothing; delta accounting framed subject to the token reentrancy/trust model; gons presented as one O(1) index-scaling instance; fractional accounting precondition stated; CEI scoped to the stale-state path; imBTC $8.5M pool / ~$24M cross-pool scopes separated; listing gate now includes post-listing monitoring for upgradeable tokens.
