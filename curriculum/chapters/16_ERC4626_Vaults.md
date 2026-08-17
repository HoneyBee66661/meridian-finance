# 16. ERC4626 Vaults

## Learning Objectives

By the end of this chapter you will be able to:

1. Explain what EIP-4626 standardizes and why the asset/share duality is the whole point; enumerate the core six functions (`asset`, `totalAssets`, `deposit`, `mint`, `withdraw`, `redeem`) and the `preview*`/`max*`/`convert*` surface that wraps them.
2. Derive the share-exchange equations from the vault invariant and the four rounding directions — deposit floors shares, withdraw ceilings shares, mint ceilings assets, redeem floors assets — and give the solvency argument for each.
3. Distinguish `preview*` (may simulate state) from `convert*` (pure math on current state) and state why preview values are display, never execution guarantees, under MEV.
4. Derive the first-depositor inflation/donation attack end-to-end with concrete numbers, and reproduce the OpenZeppelin virtual-offset mitigation with before/after arithmetic — including the honest caveat that the offset traps, rather than refunds, the attacked value.
5. Pin the `sMER` spec: the ERC4626 staking vault for staked MER, revenue accrual via share appreciation, interface shape, error catalog, rounding policy, the virtual-offset decision, and the `maxDeposit` policy. (The full `StakedMeridian.sol` implementation is Chapter 23.)
6. Measure the conversion math honestly: pinned floor/ceil directions, the ~100-gas cost of the virtual offset on a view conversion, and full-precision `mulDiv` behavior under huge operands.

## Prerequisites

- **Chapter 14** (ERC20 Deep Dive) — the ERC20 semantics the share token inherits, ERC-2612 permit (`sMER`'s `IERC20Permit`), and the error-catalog canon (`IERC20Errors` on I-prefix interfaces).
- **Chapter 12** (Fuzzing & Invariant Testing) — the ERC4626-style invariant set introduced there (`noFreeAssets`, `conversionsNeverGain`, `monotonicShares`) is this chapter's formal vocabulary; the `Mini4626` lab is the deliberately-vulnerable cousin of this chapter's `Naive4626Lab`, and its naive `assets * supply / tracked` conversion is the overflow bomb this chapter replaces with full-precision `mulDiv`.
- Supporting: **Ch 4** (rounding policy, `mulDiv`), **Ch 7/8** (gas schedule + measurement methodology: loop-amplified min-deltas, warm-up first, never `--gas-report`), **Ch 10** (parameter-exact `vm.expectRevert`), **Ch 15** (I-prefix interface + error-catalog-in-interface pattern). Locked conventions remain in force.

## Theory

### What EIP-4626 standardizes

EIP-4626 (finalized March 2023, after an unusually long review period) is the **tokenized vault standard**. A vault is a contract that holds one underlying asset and issues a *share* token representing a claim on a pro-rata slice of everything the vault holds. Before 4626, every yield aggregator, lending market, and staking wrapper reinvented this interface with a different name (`earn`, `stake`, `wrap`, `join`, `supply`). 4626's contribution is the *shape*: if every vault exposes the same deposit/withdraw surface with the same rounding semantics, then routers, dashboards, and aggregators can compose with any of them without per-protocol adapters.

The standard's opening line names the design goal directly: it is an "accounting and transfer mechanics standard for tokenized vaults." It deliberately does **not** specify how a vault generates yield — that is the vault's private business. It specifies only how assets convert to shares and back, how those conversions round, and how a caller discovers the limits and previews of a conversion.

### The asset/share duality

Every ERC4626 vault has two tokens with a fixed relationship:

- **Asset** — the underlying token held by the vault (for `sMER`, this is MER). Depositors give the vault assets and receive shares.
- **Share** — the vault's own ERC20 token, representing a claim on `totalAssets`. The vault accrues value by making `totalAssets` grow (yield, fees, donations) while the share supply stays fixed — so each share is worth more.

The exchange rate between them is not a stored number; it is *derived* from the vault's two accounting totals at every moment:

```
price = totalAssets() / totalSupply()
```

When protocol revenue is paid into `sMER` without minting new shares, `totalAssets` rises and the price per share rises: **stakers accrue revenue through share appreciation, not rebasing.** This is the mechanism the whole Meridian revenue story hangs on (Ch 23 wires the fee flow into the vault).

### The surface: six core functions plus the preview/max/convert wrappers

EIP-4626's external surface is the two accounting anchors plus four principal entry points — the "core six":

| Function | Direction | What it does |
|----------|-----------|--------------|
| `asset()` | read | The underlying token address. |
| `totalAssets()` | read | The total amount of underlying assets the vault "owns" — the accounting anchor for every conversion. |
| `deposit(assets, receiver)` | in | Pull `assets`, mint `shares` to `receiver`. Returns shares. |
| `mint(shares, receiver)` | in | Mint exactly `shares`, pull the required `assets`. Returns assets. |
| `withdraw(assets, receiver, owner)` | out | Pay `receiver` exactly `assets`, burn `owner`'s shares. Returns shares. |
| `redeem(shares, receiver, owner)` | out | Burn exactly `shares`, pay `receiver` the assets. Returns assets. |

Around these, four `preview*` functions (`previewDeposit`, `previewMint`, `previewWithdraw`, `previewRedeem`) report what a call *would* return at the current state; four `max*` functions (`maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`) report per-account limits; and two `convert*` functions (`convertToShares`, `convertToAssets`) expose the raw conversion math. That is sixteen standard vault functions, plus the share token's ERC20 surface — and every one of them exists to make one thing composable: **the round-trip between assets and shares, with a specified rounding direction.**

## Mathematical Foundations

### The vault invariant and the exchange equations

Let `A = totalAssets()` and `S = totalSupply()`. The vault invariant is: *every share is a claim on a proportional slice of the vault.* The exchange equations follow directly:

```
shares = assets × S / A     (assets → shares, floor)
assets = shares × A / S     (shares → assets, floor)
```

They describe the same exchange ratio, but they are not true inverses: rounding means applying one conversion after the other does not generally recover the exact original amount. At genesis (`A = 0`, `S = 0`) the ratio is undefined; the convention is 1:1 — the first deposit mints exactly as many shares as assets.

**Why rounding creates unallocated value.** Floor rounding leaves a remainder that is not represented by any share. Deposit 10 assets into a vault with `A = 11, S = 10`: `shares = floor(10 × 11 / 12) = floor(9.167) = 9`. The vault now holds `A = 21` but only `S = 19` shares exist, and `Σ convertToAssets(balanceOf_i) ≤ totalAssets` — the unallocated 1 asset stays inside `totalAssets` and increases the value attributable to existing shares: it is *dust*, free value the vault keeps. Dust is normally negligible (bounded by one share's worth per operation), but a donation can inflate it to catastrophic size — that is the attack below.

### Rounding directions and the solvency argument

EIP-4626 fixes one rounding direction per entry point, and the pattern is the same in all four: **the vault rounds its own way, so the rounding dust always accrues to the vault, never to the caller.**

| Entry point | Conversion | Rounding | Effect |
|-------------|-----------|----------|--------|
| `deposit` / `previewDeposit` | assets → shares | **floor** | You get fewer shares than the assets' exact worth; the vault keeps the difference. |
| `mint` / `previewMint` | shares → assets | **ceil** | You pay more assets than the shares' exact worth; the vault keeps the difference. |
| `withdraw` / `previewWithdraw` | assets → shares | **ceil** | You burn more shares than the assets' exact worth; the vault keeps the difference. |
| `redeem` / `previewRedeem` | shares → assets | **floor** | You receive fewer assets than the shares' exact worth; the vault keeps the difference. |

`convertToShares`/`convertToAssets` floor — they are the raw math; the entry points layer the policy on top.

The **solvency argument** is one line: the specified rounding directions prevent the vault from ever paying out more than the conversion permits — every share can be redeemed for *at most* its proportional slice, because the vault rounds down whatever it pays out and rounds up whatever it takes in. (With virtual offsets, the effective rate includes the virtual balances, but the same direction holds.) The lab pins the global form: `convertToAssets(totalSupply()) ≤ totalAssets()` holds at every step, so a full redemption of all shares can never drain more than the vault holds. The dust is the slack.

The pinned lab example (`Virtual4626Lab`, `A = 11, S = 10`):

```
previewDeposit(10)  = floor(10 × 11 / 12) = 9     # deposit 10 assets -> 9 shares
previewWithdraw(10) = ceil (10 × 11 / 12) = 10    # withdraw 10 assets -> burn 10 shares
previewMint(9)      = ceil (9 × 12 / 11) = 10     # mint 9 shares -> pay 10 assets
previewRedeem(9)    = floor(9 × 12 / 11) = 9      # redeem 9 shares -> get 9 assets
```

Minting 9 shares costs 10 assets (ceil) while redeeming the same 9 shares pays 9 (floor): the vault keeps a full share's worth of dust on the pair.

### preview vs convert

`convertToShares`/`convertToAssets` are **pure functions of current state** — deterministic, side-effect-free math that the EIP requires to exclude fees and slippage: the idealized, caller-independent exchange rate. `preview*` functions are *allowed* to be richer: they are operation-specific estimates that may include applicable fees and simulate state changes (a fee-on-deposit vault's `previewDeposit` can subtract the fee; `previewWithdraw` can account for pending yield). The standard's hard constraints are that previews **MUST NOT revert due to vault-specific user/global limits** — they may revert for other conditions that would also make the corresponding operation revert — and **MUST round exactly as the entry point they mirror**.

The critical caveat, which the standard's own wording and every MEV write-up hammer on: **a preview is a snapshot, not a guarantee.** Between the moment a user reads `previewDeposit(v)` and the moment their transaction executes, any state change — a donation, a yield harvest, another user's deposit — moves the price, so the actual shares can differ from the preview. The lab demonstrates the extreme case: a victim reads `previewDeposit(100,000) = 100,000` shares at price 1, a donation of 1,000,000 lands, and the actual deposit mints **99** shares. Previews are for display and router slippage checks; the final conditions are enforced by the entry points themselves. `max*` describes the limit permitted *at the current state* — it is a view, and the state can change before execution — so user-controlled slippage checks protect against unfavorable state changes in between. Never trust a preview read.

### The inflation/donation attack (full derivation)

The "first-depositor" or "inflation" attack was analyzed publicly by the t11s security team in 2022 and by OpenZeppelin's "A guide to the inflation attack" blog post the same year. It exploits exactly two things: a **tiny share supply** and the **floor rounding** that turns a normal deposit into zero shares.

**Setup.** A naive vault (pre-4.9 OpenZeppelin shape — the `Naive4626Lab`): `totalAssets()` is the vault's asset balance, conversions are floor/floor with no offset, no dead shares.

1. **t1 — seed.** The attacker deposits **1 wei**, minting 1 share at the genesis 1:1 rate. Now `S = 1, A = 1`, price = 1 wei/share.
2. **t2 — inflate.** The attacker *transfers* **1,000 ether (1e21 wei)** directly to the vault. No vault function is involved — `totalAssets()` reads the balance, so the plain transfer *is* the donation. Now `A = 1e21 + 1`, `S = 1`, price = 1e21 + 1 wei/share.
3. **t3 — the victim.** A victim deposits **1,000 ether**:

```
shares = floor(1e21 × 1 / (1e21 + 1)) = floor(0.9999…) = 0
```

The victim receives **zero shares**. Their 1,000 ether joins the vault, and they own nothing. The deposit did not revert — that is the vulnerability (a `ZeroShares` check, which the Ch 12 `Mini4626` adds, would have blocked *this* victim but is not universal). Now `A = 2e21 + 1`, `S = 1`.
4. **t4 — exit.** The attacker redeems their 1 share:

```
assets = 1 × (2e21 + 1) / 1 = 2e21 + 1
```

The attacker exits with **2,000 ether + 1 wei**. Their total contribution was 1 wei + 1,000 ether = `1e21 + 1`. **Profit = 1e21 = exactly the victim's deposit.**

**Why it is a rounding + `totalSupply == 0` problem.** The donation is "free assets" with no corresponding share. With `S = 1`, the attacker's single share claims 100% of the vault; the donation inflates the price so high that any *new* deposit floors to zero shares, so the victim's whole principal becomes unbacked dust that the one existing share captures on redemption. The two preconditions are (a) tiny supply and (b) floor-to-zero rounding. Fixing either fixes the attack.

### The virtual-offset mitigation

OpenZeppelin's v4.9+ `ERC4626` adds **configurable virtual assets and shares**. The `A / S` ratio from §Mathematical Foundations is the **raw** exchange rate — the `vA = vS = 0` case. With offsets, the **effective** conversion ratio is:

```
shares = assets × (S + vS) / (A + vA)
assets = shares × (A + vA) / (S + vS)
```

with `vA = 1` and `vS = 10^offset`. At the default `offset = 0`, `vS = 1, vA = 1`. The lab's `Virtual4626Lab` implements exactly this. Denominators are always ≥ 1, so the offset *is* the div-by-zero guard too.

**Same canonical numbers, `Virtual4626Lab`:**

1. **t1:** deposit 1 wei → `1 × (0+1)/(0+1) = 1` share. Same genesis.
2. **t2:** donate 1e21 → `A = 1e21 + 1`.
3. **t3:** victim deposits 1e21 → `shares = floor(1e21 × 2 / (1e21 + 2)) = 1`. **The victim mints 1 share, not 0.**
4. **t4:** attacker redeems 1 share. The state is now `A = 2e21 + 1`, `S = 2` — the victim's mint raised both — so `assets = floor(1 × (A + vA) / (S + vS)) = floor((2e21 + 2) / 3) = 666,666,666,666,666,666,667`. Against a contribution of `1e21 + 1`, that is a **net loss of ~333 ether**.

The offset breaks the economics two ways: the `+1` virtual assets dilutes the attacker's claim (their single share now splits the pot against the virtual share), and the victim's shares no longer floor to zero — the cost to zero the victim is now roughly double their deposit. The value the virtual shares absorb is the attacker's former profit.

**The honest caveat.** The offset makes the attack **non-profitable**, which is the point — no rational attacker runs it. It does *not* refund the victim: at the extreme skew of `S = 1`, the virtual shares trap part of the value (in the walkthrough, roughly a third of the pot becomes unrecoverable dust). That is the acknowledged drawback the OZ docstring calls out — *"the virtual shares do capture (a very small) part of the value being accrued to the vault"* — which is "very small" precisely because real vaults are not seeded with 1 wei. This is why the OZ CAUTION block pairs the offset with a second, orthogonal defense: **a non-trivial initial deposit.** The lab pins it: with a 1e18 wei seed, the same attack sequence leaves the attacker deep underwater and the victim recovering their deposit to within 1%.

### The minimum-liquidity dead-share alternative

The other classic mitigation is to mint `N` **dead shares** to `address(0)` at genesis (or lock the first depositor's shares). A permanent floor of `N` shares means the price can never be pushed arbitrarily high relative to any deposit, and a zero-share capture is impossible while `N` is large. Its problems: the dead shares' backing value is permanently unrecoverable (a real, growing cost), it must be initialized *before* any real deposit (ordering fragility — a naive deployment forgets and ships the attack), and it complicates accounting and audits. OpenZeppelin chose the virtual offset because it is automatic (no initialization ordering), does not require a manually initialized dead-share allocation, and — the deciding factor — the math makes the attack non-profitable rather than merely expensive. The tradeoff cuts both ways: like dead shares, the virtual balances can capture value, so under extreme skew the offset creates effective unrecoverable value of its own (the caveat above).

## Engineering Perspective

For Meridian, 4626 is not an abstraction exercise: `sMER` *is* the revenue surface. Three design properties deserve attention now and will recur in Ch 23.

**Revenue accrual is a donation.** Protocol fees are paid into the vault without minting shares, so `totalAssets` rises and the share price appreciates. That is precisely the "donation" primitive the inflation attack abuses — which is why the vault must be donation-hardened against *untrusted* deposits even though *protocol-authorized* accrual is the intended mechanism. The virtual offset does not distinguish donor from protocol; it simply makes value capture non-profitable for anyone.

**`totalAssets` is an accounting choice.** OZ reads `asset.balanceOf(address(this))`. That is simple and donation-sensitive by construction. A vault that tracks its own internal ledger (like Ch 12's `Mini4626`) must be careful that every external transfer is reflected — a mismatch between the ledger and the real balance is a `noFreeAssets` violation waiting to happen (the invariant detector from Ch 12).

**Composition hazards.** The EIP's own CAUTION lists two: never combine an exchange-rate vault with flash-minting (if a vault permits temporarily unbacked flash-minted shares, `totalSupply` can be manipulated intra-transaction, corrupting the rate), and never let `preview*` revert due to vault-specific limits (that breaks `maxWithdraw`-style composition and any router that reads previews unconditionally). The share-allowance split (`caller` vs `owner` in `withdraw`/`redeem`) is production plumbing the lab deliberately skips, but a production vault must implement it (OZ's `_withdraw` spends the allowance when `caller != owner`).

## Mermaid Diagram

```mermaid
sequenceDiagram
    participant A as Attacker
    participant B as Asset (MER)
    participant V as Vault (Naive4626Lab)
    participant D as Victim

    Note over A,V: PHASE 1 — seed the price (first depositor)
    A->>V: deposit(1 wei)
    V->>V: S=1, A=1, price = 1 wei/share

    Note over A,B,V: PHASE 2 — inflate (NO vault function)
    A->>B: transfer(1,000 ether) to V
    B->>V: balance += 1e21
    V->>V: A=1e21+1, S=1, price = 1e21+1 wei/share

    Note over V,D: PHASE 3 — the victim
    D->>V: deposit(1,000 ether)
    V->>V: shares = floor(1e21 * 1 / (1e21+1)) = 0
    Note right of V: D owns nothing; their 1,000 ether is now unbacked dust

    Note over A,V: PHASE 4 — exit
    A->>V: redeem(1 share)
    V-->>A: 1 * (2e21+1) / 1 = 2,000 ether + 1 wei
    Note right of V: Virtual4626Lab: same sequence -> victim gets 1 share,<br/>attacker exits with (2e21+2)/3 (a NET LOSS)
```

## Code Walkthrough

**`meridian/src/IVault4626Lab.sol`** — the shared lab surface: the four entry points, the four previews, the four `max*`, the two converts, `asset`/`totalAssets`/`totalSupply`/`balanceOf`, the `Deposit`/`Withdraw`/`Donated` events, and the **error catalog on the interface** per the Ch 2/14 canon: `ZeroAssets`, `ZeroShares`, `InsufficientShares(have, need)`, `UnauthorizedCaller(caller, owner)`, and the three `ExceededMax*` errors mirroring OZ's `ERC4626ExceededMax*` shape.

**`meridian/src/Vault4626Lab.sol`** — `Abstract4626Lab` implements the full surface with the rounding directions fixed exactly as §Mathematical Foundations prescribes: `previewDeposit` floors, `previewMint` ceilings, `previewWithdraw` ceilings, `previewRedeem` floors, and `deposit`/`mint`/`withdraw`/`redeem` delegate to their previews. `maxWithdraw` is derived from `maxRedeem` (`previewRedeem(maxRedeem(owner))`) — the EIP's own note that overriding only `maxWithdraw` has no effect. `totalAssets()` is `asset.balanceOf(address(this))`, so a plain transfer is a donation. Two deliberate simplifications, both documented: `deposit` does **not** revert on zero shares (the faithful pre-hardened behavior the attack needs — Ch 12's `Mini4626` added the revert), and the share token is a minimal balance ledger rather than a full ERC20.

The two concrete vaults override only the two conversion internals:

- `Naive4626Lab._convertToShares` — `assets × S / A` with a genesis guard (empty vault → 1:1) and a drained-vault guard (no assets → 0 shares). This is the pre-v4.9 OZ shape.
- `Virtual4626Lab._convertToShares` — `assets × (S + 1) / (A + 1)`, full-precision `Math.mulDiv`, no guards needed because the offset keeps denominators ≥ 1.

Both use `Math.mulDiv` — never the naive `a * b / c` that Ch 12's `Mini4626` uses and that this chapter's overflow test shows reverting `Panic 0x11` at scale.

**`meridian/test/Vault4626Lab.t.sol`** — 21 tests: four rounding-direction pins with exact numbers, the global solvency pin, a fuzz round-trip, the canonical attack on both vaults, the seeded-vault defense, preview-vs-convert, the `max*` surface, the non-owner negative test, a three-user solvency fuzz, the `mulDiv`-vs-naive overflow pair, and three log-only gas probes.

## Production Example

**`sMER` in the Meridian protocol — the spec pinned here (implementation Ch 23).** The staking vault takes MER in, issues `sMER` shares, and accrues protocol revenue through share appreciation. The spec, as locked:

- **Interface shape.** `IStakedMeridian` — an I-prefix interface inheriting `IERC20 + IERC20Permit + IERC4626`, plus `mer()` and the `Deposit`/`Withdraw` events re-declared on the interface (the Ch 15 lesson: events are interface surface). The Ch 14/15 override-list lessons apply to the `ERC20 + ERC20Permit + ERC4626` inheritance graph.
- **Error catalog.** The OZ v5 interface set — `IERC20Errors` (ERC-6093), `ERC2612ExpiredSignature`/`ERC2612InvalidSigner`, `ERC4626ExceededMaxDeposit`/`MaxMint`/`MaxWithdraw`/`MaxRedeem` — plus Meridian-specific errors (e.g. `InvalidConstructorAddress`), final at Ch 23.
- **Rounding policy.** OZ default, exactly as this chapter pins: deposit/previewDeposit floor, mint/previewMint ceil, withdraw/previewWithdraw ceil, redeem/previewRedeem floor.
- **Virtual-offset decision.** **Yes** — OZ v4.9+ offset (offset 0, virtualShares = virtualAssets = 1). `sMER` must address donation/inflation risk because its revenue mechanism intentionally increases assets without minting shares; the selected defense is the OpenZeppelin virtual-offset design, complemented by non-trivial initial liquidity (OZ CAUTION's defense-in-depth), set at deployment.
- **`maxDeposit` policy.** Default unlimited (`type(uint256).max`) — there is no deposit cap; MER supply is a governance decision (Ch 14) and the vault is not a faucet. The revenue side is a separate, privileged accrual path (Ch 23).
- **What is deferred.** All of the vault's actual yield wiring — which contracts pay fees in, how often accrual runs, any fee-on-exit — is Ch 23's `StakedMeridian.sol`. This chapter pins the *shape* the conversion math must have.

The production reference is OZ `ERC4626.sol` v5.7 directly: the `_deposit`/`_withdraw` split, the allowance spend in `_withdraw`, and the `SafeERC20` returndata discipline (Ch 9) all carry straight into Ch 23.

## Foundry Lab

Materialized and **compile-verified in this run** (forge 1.7.1, solc 0.8.24, cancun, optimizer 200):

- **New artifacts:** `src/IVault4626Lab.sol`, `src/Vault4626Lab.sol` (`Abstract4626Lab`, `Naive4626Lab`, `Virtual4626Lab`), `test/Vault4626Lab.t.sol` (21 tests incl. 2 fuzz + 3 gas probes). The existing Ch 12 `Mini4626`/`MiniToken` keep compiling untouched.
- **Full repo suite: 220 passed / 0 failed / 6 skipped (226 total) across 22 suites** (Ch 15 baseline 199/0/6 across 21; +21 tests, +1 suite). The 6 skips remain the Ch 11 fork tests. `.gas-snapshot` regenerated to **225 rows** under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`; the paired `--check` flags only the three known pre-existing fuzz rows (FuzzProbe/GasOpt/Yul μ-instability — Ch 14 finding #3, recurrence observed again in-run). The CI gate is therefore intentionally not fully green: `forge test` is clean, while `forge snapshot --check` carries three disclosed baseline exceptions until those rows are stabilized.
- **Gas probes (loop-amplified min-deltas, warm-up first):** naive `previewDeposit` **2,609** vs virtual `previewDeposit` **2,705** — in this lab the virtual conversion measured **+96 gas** relative to the naive version. Virtual vault `deposit` **10,358**, `redeem` **10,756**.
- **Real findings, all kept:** (1) A public state variable cannot satisfy an interface `function asset() returns (address)` when the variable is typed `IERC20` — the getter returns the contract type, and error 4822 fires; the OZ `_asset`-private + explicit-getter pattern is required. (2) `using Math for uint256` at the base-contract level is not visible in derived contracts here — each concrete vault declares its own `using` directive. (3) The canonical virtual-vault attack does **not** break even at offset 0 with `S = 1` — it is a strict loss (`(2e21+2)/3`), and the victim's full recovery only appears under the seeded-vault defense; both facts are now pinned as separate tests rather than one idealized story.

## Security Analysis

**1. The first-depositor inflation attack is the parent class.** t11s (2022) and the OZ blog made it canonical: tiny supply + floor-to-zero + a free-assets donation = a later depositor's principal captured. The lab reproduces it exactly (victim mints 0 shares, attacker profits the victim's deposit). Every "donate-to-inflate" finding since — including **Euler (Mar 2023, ~$197M)**, where share accounting on a lending protocol was attacked via a donate-to-self that the Ch 12 `noFreeAssets` invariant is the exact detector for — is the same shape with different plumbing.

**2. Rounding, not donations, is the wider family.** The Balancer V2 ComposableStablePool exploit (**Nov 2025, ~$128M**) was a *rounding* flaw in proportional-share minting — the `conversionsNeverGain` property, violated. This chapter's rounding-direction pins and solvency assertion are the prophylactic: a vault that can never pay out more than it takes in cannot have its conversions exploited for value. Ch 26 gives the full treatment.

**3. The virtual offset is a deterrent, not a lossless shield.** It makes the attack non-profitable (attacker exits at a loss in the canonical walkthrough) but absorbs value into the virtual shares at extreme skew, and it cannot stop a griefing attacker who simply doesn't care about profit. The defense-in-depth is the non-trivial initial deposit, which the lab pins recovers the victim to within 1%. A production vault that ships *only* the offset with a 1-wei genesis is still fragile.

**4. Preview is a front-running oracle.** A `previewDeposit` read is a public, manipulable number (the donation between read and execute mints 99 shares instead of 100,000 in the lab). Vaults and routers must treat previews as display + slippage bounds, never as on-chain guarantees; `max*` reports the currently permitted limit but is itself a view of mutable state, so the entry point enforces the final condition, with user slippage bounds guarding the read-to-execute gap.

**5. The trust surface is the accrual path.** All of the above protects against *untrusted* value entering the vault. The protocol's own revenue flow — who is allowed to deposit fees, and who triggers accrual — is a privileged surface, and 2026's grounding is blunt: **Kelp DAO/Drift (~$285–292M, Apr 2026)** were admin-key incidents. A perfectly rounding, donation-hardened vault is worthless if its revenue or withdrawal paths are governed by a key that can be phished. Ch 25 wires that trust chain; this chapter's job is only to make the vault safe against everyone else.

## Common Mistakes

1. **Using `a * b / c` instead of full-precision `mulDiv`.** `assets * totalSupply` overflows long before a vault is absurdly large; the lab pins the `Panic 0x11` (Ch 12's `Mini4626` still has the naive form, deliberately).
2. **Wrong rounding direction.** Deposit must floor shares, mint must ceil assets, withdraw must ceil shares, redeem must floor assets. Flip any one and the vault starts minting value (the Balancer V2 class).
3. **Trusting `preview*` as a guarantee.** It is a snapshot; a donation between read and execute moves the price (lab: 100,000 → 99 shares).
4. **Assuming a zero-share check saves you.** A `ZeroShares` revert blocks one manifestation of the attack; it does not replace exchange-rate hardening (the price floor / virtual offset) or user slippage protection — the vulnerable pre-hardened behavior mints 0 silently.
5. **Shipping a 1-wei genesis vault with only the offset.** The offset deters; the seeded initial deposit is what makes victims whole. Both, per OZ.
6. **Declaring `asset` as a public state variable typed `IERC20`** when the interface says `returns (address)` — error 4822; use the private `_asset` + explicit getter.
7. **Forgetting `maxWithdraw` derives from `maxRedeem`.** Overriding `maxWithdraw` alone has no effect (EIP note).
8. **Letting `preview*` revert.** It breaks routers and `maxWithdraw` composition; previews must never revert due to vault-specific limits — they may revert only for conditions that would also revert the mirrored operation.
9. **Combining with flash-minting shares.** If a vault permits temporarily unbacked flash-minted shares, `totalSupply` can be manipulated intra-transaction and corrupt exchange-rate assumptions (OZ CAUTION).
10. **Using `totalAssets()` that can disagree with the real balance.** A tracked-ledger vault (Mini4626-style) diverges from `asset.balanceOf(this)` on the first direct transfer — the `noFreeAssets` condition (Ch 12).

## Gas Optimization

The conversion math is the hot path. Measured on this host (loop-amplified min-deltas, warm address first):

- **The virtual offset is cheap in this benchmark:** naive `previewDeposit` **2,609** vs virtual **2,705** gas — **+96 gas** in this lab, because both are the same full-precision `mulDiv` with `+1` constant operands. The measured delta should not be generalized into an implementation-wide "no gas tax" claim.
- **Full entry points:** virtual `deposit` **10,358**, `redeem` **10,756**. The delta over the raw conversion is the `SafeERC20` transfer(s) + the balance/mint/burn writes — the Ch 9 returndata gate and the cold-touch discipline (Ch 7) are already baked in.

Three optimization notes, per the Ch 8 hierarchy (remove, cheapen, measure):

- **`mulDiv` is the floor, not a luxury.** The naive multiply is cheaper until it overflows; "cheaper" that reverts at scale is not an optimization. Ch 4's canon holds: full-precision `mulDiv`, always, in share math.
- **The observed +96-gas difference is small in this benchmark.** Its exact cause should not be inferred from the aggregate measurement alone — it could be constant arithmetic, compiler decisions, or measurement noise.
- **`maxWithdraw` caching is not worth it.** It is a view function; optimizing it is micro-gas with no transaction on the line. Keep the derivation from `maxRedeem`.

The Ch 13 snapshot gate now carries the 21 new rows; future optimizations must beat them by >20 gas under the pinned CI seed.

## Reading Production Source Code

1. **EIP-4626** — the spec itself: read the "Rounding to and from units" section and the Requirements table; it is the contract for everything above.
2. **OpenZeppelin `ERC4626.sol` (v5.7)** — the reference implementation: `_convertToShares`/`_convertToAssets` with the virtual offset, `_deposit`/`_withdraw` (transfer-then-mint, the CEI exception), the `_decimalsOffset()` hook, and the four `ERC4626ExceededMax*` errors. The CAUTION block is a security checklist in prose.
3. **OpenZeppelin `Math.sol` `mulDiv`** — the full-precision path: 512-bit intermediate, the two-step quotient/remainder recovery. This is what makes the naive-overflow test's counterpart safe.
4. **A real production vault adapter** — Yearn v3's `yVault` (which standardized on 4626) or a well-known 4626 wrapper. Look for: *is the virtual offset present or are there dead shares? Are all four rounding directions correct? Does `preview*` revert? What backs `totalAssets()` — a ledger or a balance? Is `maxDeposit` capped? Is there a fee-on-deposit hook and does its preview match its deposit?* The gap between what a vault *claims* and what its conversions *do* is where rounding exploits live.
5. **fei-protocol/ERC4626** (the reference audit companion and `ERC4626Router`) — the canonical discussion of the inflation attack and the router slippage pattern that protects users against preview drift.

Ask of every vault you read: *what is the share price, which way does every conversion round, can a donation or a rounding edge make it mint value, and who is allowed to add assets without minting?*

## Exercises

1. Trace the canonical attack by hand in a table: for `Naive4626Lab`, write `(A, S, price)` after each of t1 (deposit 1 wei), t2 (donate 1e21), t3 (victim deposits 1e21), t4 (attacker redeems 1 share). Confirm the attacker's profit equals the victim's deposit. Redo the table for `Virtual4626Lab` and confirm the attacker's loss and the victim's 1 share.
2. Prove the solvency inequality: show that with floor/ceil as specified, `deposit(v)` never mints shares worth more than `v`, and `redeem(s)` never pays more than `s` is worth — using the pinned `A = 11, S = 10` numbers from the chapter.
3. In the preview-vs-convert lab test, change the donation to land *between* a `maxRedeem` read and a `redeem` call. Does `maxRedeem` protect the user? What does and doesn't?
4. Derive why the virtual offset's attack cost is roughly double the victim's deposit: set `S = 1`, show that zeroing a victim's shares requires `V ≤ D/2`, and that the attacker's profit at that boundary is negative.
5. Implement the dead-share alternative in a copy of `Naive4626Lab`: mint 1e9 shares to `address(0)` in the constructor, re-run `test_inflationAttack_naive_victimDepositCaptured`, and explain what changed and what the dead shares cost the first real depositor.
6. Read OZ `ERC4626._withdraw`: trace where the allowance is spent when `caller != owner`, and state the CEI ordering relative to the burn and the transfer (the Ch 15 `depositFor` exception pattern).

## Weekly Project

**The `sMER` spec — pinned, not implemented:**

1. Write the `IStakedMeridian` interface skeleton: `IERC20 + IERC20Permit + IERC4626` + `mer()`, with the error catalog and events laid out per this chapter's spec section. Do **not** write `StakedMeridian.sol` — that is Ch 23's deliverable; this week is the contract the interface must satisfy.
2. Add `docs/erc4626-spec.md` to the pending weekly-docs debt list: rounding policy table, virtual-offset decision, `maxDeposit` policy, the revenue-accrual-via-share-appreciation mechanism, and the Ch 23 interface contract.
3. Confirm the lab suite is green: `forge test` → **220 passed / 0 failed / 6 skipped (226 total)**. The Ch 12 `Mini4626` still compiles and its invariant suite still passes — the two labs coexist as vulnerable/fixed cousins.
4. Protocol contract count: **still 2** (MER, gMER). `sMER` is specced here, implemented Ch 23.

## Deliverables

1. `src/IVault4626Lab.sol` + `src/Vault4626Lab.sol` — the lab vault pair (Naive + Virtual) sharing one interface; compile-verified in-run.
2. `test/Vault4626Lab.t.sol` — 21 tests all green; repo suite **220 passed / 0 failed / 6 skipped across 22 suites**; `.gas-snapshot` at 225 rows under the pinned CI seed.
3. Conventions locked: EIP-4626 rounding directions with exact pins; `preview*` ≠ guarantee; virtual-offset non-profitability with exact numbers; the offset measured +96 gas on a conversion in this lab.
4. Gas profile: naive preview 2,609 · virtual preview 2,705 · deposit 10,358 · redeem 10,756.
5. The `sMER` spec pinned (interface shape, error catalog, rounding, virtual offset, `maxDeposit`) for Ch 23.

## Quiz

1. List the four entry points and the rounding direction each uses — and the one-line solvency argument that makes them safe.
2. `convertToShares` and `previewDeposit` both return shares for an asset amount. What may differ between them, and why is that allowed?
3. Walk the canonical attack: what two preconditions make a first-depositor donation capture a later deposit, and which of the two does the virtual offset break?
4. With the virtual offset at `S = 1`, why is the attacker's exit a loss rather than a break-even, and what is the acknowledged tradeoff?
5. Why does `sMER`'s revenue mechanism make donation-hardening *necessary*, and why is the virtual offset the *selected* defense rather than the only option?
6. What does `maxWithdraw` derive from, and what happens if you override it alone?
7. In the lab, what does `convertToShares(2**250)` do on `Virtual4626Lab`, and why does the same input revert `Panic 0x11` on Ch 12's `Mini4626`?

**Answers:** (1) deposit floors shares, mint ceils assets, withdraw ceils shares, redeem floors assets — every entry rounds the vault's way, so the vault never pays out more than it takes in. (2) `convertToShares` is pure current-state math; `previewDeposit` may simulate state (fees, pending yield) but must mirror the entry point's rounding and never revert. (3) Tiny `totalSupply` (the 1-wei first deposit) and floor-to-zero rounding; the virtual offset breaks the floor-to-zero by keeping the victim's mint nonzero. (4) The attacker's single share splits the pot against the virtual shares, so proceeds `(2e21+2)/3` fall short of the `1e21+1` contributed; the tradeoff is that the virtual shares trap part of the value at extreme skew. (5) `sMER`'s revenue accrual *is* a donation, so the vault must be hardened against untrusted value capture for its own intended mechanism to be safe; the spec's selected defense is the OZ virtual offset, complemented by non-trivial initial liquidity. (6) `maxWithdraw(owner) = previewRedeem(maxRedeem(owner))`; overriding `maxWithdraw` alone has no effect. (7) `mulDiv` computes it in full precision; `Mini4626`'s naive `assets * supply / tracked` overflows the 256-bit product and reverts `Panic 0x11`.

## Further Reading

- EIP-4626 (Final, Mar 2023) — the spec; the rounding table and Requirements are the contract for every claim in this chapter.
- t11s, "Inflation attack on ERC-4626 vaults" (2022) and OpenZeppelin, "A guide to the inflation attack" (2022) — the two canonical analyses; the OZ CAUTION block in `ERC4626.sol` is the distilled version.
- OpenZeppelin `ERC4626.sol` (v5.7) and `Math.sol` — the reference implementation and the `mulDiv` full-precision path.
- Yearn v3 vaults / a well-known 4626 wrapper — production adapters to read with the §Reading checklist.
- 2026 security grounding: **Balancer V2 ComposableStablePool (Nov 2025, ~$128M, rounding)** — the conversionsNeverGain family, full treatment Ch 26; **Euler (Mar 2023, ~$197M, donate-to-self)**; **Kelp DAO/Drift (Apr 2026, ~$285–292M, admin keys)** — the trust surface Ch 25 owns.
- Ch 12 (the vulnerable `Mini4626` and the invariant detector), Ch 23 (the full `StakedMeridian.sol` implementation of the spec pinned here), Ch 26 (the rounding-failure class), Ch 25 (the accrual/execution trust chain).

## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/16_ERC4626_Vaults_REVIEW.md`):** function count corrected 15→16; `totalAssets` reframed (rounding creates unallocated value, not excluded dust); preview MUST NOT revert scoped to vault-specific limits; `max*` = estimates, entry point enforces; virtual-offset economics qualified (can capture value, not mandatory for sMER); CI snapshot/green status resolved.

## Ledger Update

- **ERRATA APPLIED (2026-08-15, review `errata/16_ERC4626_Vaults_REVIEW.md`):** function count corrected 15→16; `totalAssets` reframed (rounding creates unallocated value, not excluded dust); preview MUST NOT revert scoped to vault-specific limits; `max*` = estimates, entry point enforces; virtual-offset economics qualified (can capture value, not mandatory for sMER); CI snapshot/green status resolved.
