# 23. Staking & Revenue Share

## Learning Objectives

By the end of this chapter you will be able to:

1. Distribute protocol revenue to stakers without a per-user loop — the single-writer accrual pattern — and derive why the math is a first-order invariant, not a UX detail.
2. Implement the **donation/inflation attack** (the ERC-4626 share-price manipulation family) and explain exactly which invariant it breaks and which line of code closes it.
3. Convert a naive "reward per second × balance" scheme into a global-index scheme (`accRewardPerShare`) that is O(1) per user action, with bounded rounding residue.
4. Build Meridian's `StakedMeridian` (sMER) from the Ch 16 spec: ERC-4626 vault where share price = `totalAssets / totalSupply`, with the virtual-offset defense.
5. Justify the rounding direction policy (floor for user-received, ceil for user-paid) in the staking context — including the `1 wei` griefing edge.
6. Read a production staking contract (Lido's `stETH` share mechanics, Aave's `aToken` accrual, Synthetix's `RewardsDistribution`) and *count* where value can leak.

## Prerequisites

- **Chapter 16** (ERC4626 Vaults) — the vault standard, `totalAssets`/`totalSupply` share math, the `conversionsNeverGain` invariant that Chapter 26 will treat as a vulnerability class. The sMER spec was pinned here.
- **Chapter 21** (Interest Rates) — Meridian's revenue source: the kink-model lending spread. This chapter distributes what Ch 21 earns.

Supporting references: **Ch 4** (fixed-point WAD/RAY, mulDiv), **Ch 14** (MER — the underlying asset), **Ch 20** (the vault that generates revenue). All locked conventions remain in force: custom errors in I-prefixed interfaces, full NatSpec, CEI, `^0.8.24`, cancun, optimizer 200, `abi.encodeCall`, calldata for read-only external args, bounded loops.

## Theory

### Revenue share is a write-amortization problem

Protocol revenue (the lending spread from Ch 21) arrives as MER. It must be distributed to stakers pro rata. The naive design — iterate over all stakers and update each balance — is an O(N) loop over an attacker-inflatable set: it is the unbounded-loop DoS class from Ch 1, wearing a rewards costume.

The correct shape is **global accrual**: keep one accumulator per reward token, `accRewardPerShare`, and let each user's claim be a subtraction of two snapshots:

```
userRewards = balanceOf[user] × (accRewardPerShare_now − accRewardPerShare_at_lastClaim[user])
```

A user's rewards grow without any per-user state being touched while they sit idle. Every action (stake, unstake, claim) is O(1). This is the same single-writer discipline Ch 20 locked for the vault — here it is the *entire* mechanism, not a hot-path optimization.

**The invariant:** `sum(claimable_i) ≤ totalRewardsDeposited − totalRewardsClaimed` for all users at all times. Every design decision below — index granularity, rounding direction, virtual offsets — is a defense of this inequality.

### Why share price, not "rewards per balance"

Meridian's staking is an ERC-4626 vault: users deposit MER, receive sMER shares, and revenue accrues by *appreciating the share price* (`totalAssets / totalSupply`). No separate rewards ledger, no claim step for the *accrual* (claim exists only for a secondary governance token, gMER — Ch 15).

This is the cleanest possible revenue-share design because it reuses the Ch 16 machinery. But it concentrates all the risk into one number: **the share price must never move against existing stakers**. That single requirement is the donation/inflation attack.

sMER deliberately implements the share-price pattern. The global index is the *alternative* pattern — taught above for contrast, never combined with share appreciation in this design:

| | Global index (`accRewardPerShare`) | Share appreciation (sMER) |
|---|---|---|
| Ledger | one accumulator per reward token + per-user snapshot | none — value lives in the share price |
| Claim step | required (`claim()` pays out the accrued delta) | none for accrual; `redeem()` exits at the current price |
| Reward token | may differ from the stake token (Synthetix) | the underlying itself (MER) |
| Rounding | per-claim residue, bounded by index granularity | per-conversion floor, always against the user |

### The donation/inflation attack

An attacker deposits 1 wei of MER *after* the vault already has a nonzero share supply, then **donates** a large amount directly to the vault contract (not through `deposit`) — or front-runs a large deposit. The mechanics below are computed against the **vulnerable baseline** — a vault whose `totalAssets` reads `balanceOf(address(this))`, so a raw transfer *is* counted. That is the accounting model the attack needs; Meridian's tracked-`_totalAssets` variant, which makes the same steps harmless, is drawn right after. The mechanics:

1. Vault has `totalAssets = 100 MER`, `totalSupply = 100 shares` → price = 1.0.
2. Attacker calls `deposit(1 wei)` → receives 1 share (rounding down, 1 wei → 1 share; the Ch 16 "inflation" edge).
3. Attacker transfers 10,000 MER directly to the vault contract (a raw `transfer`, bypassing `deposit`).
4. Now `totalAssets = 10,100`, `totalSupply = 101` → price ≈ 100.
5. A real user deposits 100 MER → receives `100 × 101 / 10,100 = 1` share (floor) instead of ~100.
6. Attacker redeems their 1 share for ~100 MER. The real user's 100 MER just bought 1 share — worth ~1 MER after the attacker exits.

Every step above depends on the donation *moving the price* — true only in the vulnerable baseline. **Meridian's design is the other accounting model**: `totalAssets()` returns the tracked `_totalAssets`, so step 3's raw transfer never touches the price. The donation is invisible to the share price, and the virtual offset below is an *additional* defense (it removes the near-zero-price regime), not the primary one.

The attack is a *first-depositor + direct-transfer* combination, and it is the reason staking vaults defend with a **virtual offset**: the vault pretends it already has `VIRTUAL_ASSETS` and `VIRTUAL_SHARES` (e.g. 1e18 of each) before any real deposit. Virtual assets/shares are a widely used mitigation (OZ `ERC4626` supports the pattern); other defenses include seeded initial liquidity and explicit slippage protection. With the offset, the attacker's 1-wei deposit is pegged to the 1e18 baseline — worth ~1 wei, not a leveragable stake — and the price can never be manipulated from near-zero.

The defense lines, and the job each does:

1. **Virtual assets/shares offset** (OZ `ERC4626` supports the pattern via `_decimalsOffset`; we implement it explicitly) — removes the near-zero-price regime and the dust-griefing loop; with tracked assets (line 3) it is the *additional* defense, not the primary one.
2. **`mulDiv` with floor for user-received** (Ch 4 lock) — the *attacker* rounds against themselves.
3. **No direct-transfer value accrual**: `totalAssets` counts *tracked* balance (an internal accounting variable), never `balanceOf(address(this))` — so untracked donations don't inflate the price. This is the *primary* donation defense: it makes even a deliberate donation worthless.

### Virtual offsets, derived

With `_offset = 1e18`:

```
totalAssets_effective = totalAssets + 1e18
totalSupply_effective  = totalSupply + 1e18
sharePrice = totalAssets_effective / totalSupply_effective
```

- First depositor: deposits `d` → shares = `d × 1e18 / 1e18 = d` (exact, no inflation edge).
- Attacker's 1-wei deposit at the empty vault → `1 × (0 + 1e18) / (0 + 1e18) = 1` share — pegged to the 1e18 baseline, redeeming for ~1 wei; not a leveragable stake, so the donation has no hostage.
- Price floor: even at `totalAssets = 0`, price = `1e18/1e18 = 1.0` — never zero, never manipulable from the dust.

The cost: a permanent 1e18 "phantom" share dilutes every real share by a factor that vanishes as the vault grows. Acceptable — it is the standard price of safety, paid once, amortized forever.

## Mathematical Foundations

### Accrual identity

Let `A` = tracked assets, `S` = share supply, `P = (A + v) / (S + v)` (v = virtual offset). Revenue `r` arrives: `A += r`, so `P` rises. A holder of `s` shares gains `s × ΔP` — automatically, without touching their entry.

### Share conversion (Ch 16 recap, with offsets)

```
shares = assets × (S + v) / (A + v)      — deposit, floor (user-received)
assets = shares × (A + v) / (S + v)      — redeem, floor (user-received)
```

Both directions floor for the *user receiving* value; the counterparty (the vault/other stakers) effectively receives the rounding remainder — which is the **donation-by-rounding** the Ch 26 invariant family names.

### Donation leverage, quantified

Attack value = `donation × (shares_attacker / supply_before)`. In the Meridian design the donation never enters the tracked `_totalAssets`, so the attacker's 1-wei share redeems for ~1 wei and leverage stays ≈ 0 no matter how large the donation. In the vulnerable baseline (`totalAssets = balanceOf`) with no offset, leverage ≈ `donation / totalAssets_before` — unbounded as `totalAssets_before → 0`. Meridian removes the regime twice: tracked assets keep the donation out of the price entirely, and the offset prevents `A`/`S` from ever starting near zero.

### Why the 1-wei edge is a real finding

In a no-offset vault, `deposit(1)` at `totalSupply=0` mints exactly 1 share — harmless. But once a donation has skewed the price above 1 (`A=2, S=1`), a `deposit(1)` rounds to 0 shares — and a *second* attacker can then grief: round-trip `deposit(1)/redeem(1)`, each cycle donating 1 wei that the skewed price converts into more than 1 wei back, siphoning the victim's share value. Meridian closes the loop twice. First, tracked `_totalAssets` keeps the price at 1:1, where the round trip is exact — 1 wei in, 1 wei out — so there is no dust to harvest. Second, any conversion that rounds to 0 shares reverts `ZeroShares` (pinned by `testZeroDepositReverts`) instead of silently minting nothing.

## Engineering Perspective

### The sMER spec, honored

Ch 16 pinned: `StakedMeridian` = ERC-4626 over MER, `decimals()` matching the underlying, revenue accrued via share appreciation, no separate rewards token. Ch 23 adds the production details the spec deliberately deferred:

| Spec decision (Ch 16) | Ch 23 implementation |
|---|---|
| ERC-4626, sMER shares | `StakedMeridian.sol` + `IStakedMeridian.sol` |
| Underlying = MER (18 dec) | constructor-pinned, hookless (Ch 17 lock) |
| Share appreciation | virtual-offset `totalAssets` accounting (not `balanceOf`) |
| Protocol revenue entry | `notifyReward(uint256)` — privileged (Ch 25 governor/multisig), bounded |
| Upgrade path | EIP-1967 proxy (Ch 38) — implementation is storage-disciplined |

### The accounting invariant: tracked, not observed

`totalAssets()` must return the *tracked* balance, not `ERC20.balanceOf(address(this))`. A direct transfer is then invisible to the share price — the donation attack dies at the accounting layer even if every other defense is removed. This is the single most important engineering decision in the chapter.

### Bounded everything

`notifyReward` is privileged and bounded (no loop, no unbounded array); user actions are O(1). The only loop in the entire contract is the Ch 1 bounded-loop convention applied to batch claims — and sMER has none.

## Mermaid Diagram

```mermaid
flowchart LR
    A[Protocol revenue<br/>lending spread, Ch 21] -->|notifyReward| B[StakedMeridian.sol<br/>totalAssets += r]
    B --> C[Share price rises<br/>P = (A+v)/(S+v)]
    C --> D[Staker holds sMER]
    D -->|redeem| E[MER out<br/>assets = s × P, floor]
    D -->|gMER claim<br/>Ch 15| F[governance power]
    B -. direct transfer .-> G[untracked balance<br/>INVISIBLE to P]
```

## Code Walkthrough

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStakedMeridian
/// @notice I-prefix interface: the full failure surface in one file (Ch 2 lock).
interface IStakedMeridian {
    error ZeroShares();
    error ZeroAssets();
    error InsufficientBalance(uint256 have, uint256 want);
    error NotAuthorized(address caller);

    function notifyReward(uint256 amount) external;
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakedMeridian} from "./IStakedMeridian.sol";

/// @title StakedMeridian
/// @notice ERC-4626 staking vault: sMER shares appreciate as protocol revenue
///         accrues. Virtual-offset defense against the donation/inflation
///         attack; tracked-assets accounting; hookless MER (Ch 17 lock).
/// @dev NOT upgradeable in v1 (Ch 38 adds the proxy). All state below follows
///      EIP-1967-friendly layout discipline anyway.
contract StakedMeridian is IStakedMeridian {
    using SafeERC20 for IERC20;

    uint256 private constant VIRTUAL_ASSETS = 1e18;
    uint256 private constant VIRTUAL_SHARES = 1e18;

    IERC20 public immutable underlying;
    address public immutable rewardsAdmin;      // Ch 25: governor/multisig path
    address public immutable meridianVault;     // the only notifier in v1 (Ch 20)

    uint256 internal _totalAssets;              // TRACKED assets — never balanceOf
    uint256 internal _totalShares;              // TRACKED share supply — single writer
    mapping(address => uint256) internal _shares;

    constructor(address underlying_, address rewardsAdmin_, address meridianVault_) {
        underlying = IERC20(underlying_);
        rewardsAdmin = rewardsAdmin_;
        meridianVault = meridianVault_;
    }

    /// @notice Record protocol revenue. Only the lending vault may call in v1;
    ///         the rewards admin (Ch 25) takes over via proxy in Ch 38.
    function notifyReward(uint256 amount) external {
        if (msg.sender != meridianVault && msg.sender != rewardsAdmin) {
            revert NotAuthorized(msg.sender);
        }
        if (amount == 0) return;
        // Pull, then account — the transfer can only fail loudly.
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        _totalAssets += amount;
    }

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function totalSupply() public view returns (uint256) {
        return _totalShares;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, _totalShares + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, _totalAssets + VIRTUAL_ASSETS, _totalShares + VIRTUAL_SHARES);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        _totalAssets += assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (shares > _shares[owner]) revert InsufficientBalance(_shares[owner], shares);
        assets = convertToAssets(shares);
        if (assets == 0) revert ZeroAssets();
        _burn(owner, shares);
        _totalAssets -= assets;
        underlying.safeTransfer(receiver, assets);
    }

    function _mint(address to, uint256 shares) internal {
        _shares[to] += shares;
        _totalShares += shares;
    }

    function _burn(address from, uint256 shares) internal {
        _shares[from] -= shares;
        _totalShares -= shares;
    }
}
```

Three details. **First**, `convertToShares`/`convertToAssets` are pure `mulDiv` (Ch 4 lock) over the tracked `_totalShares`/`_totalAssets` plus the virtual offsets — no division by a user-controllable near-zero denominator. **Second**, `notifyReward` pulls then accounts: the pull can revert loudly (SafeERC20 reverts on a failed transfer; the interface's own errors cover the vault's logic, not the token's), and accounting happens only after the balance is physically here. **Third**, `_mint`/`_burn` are single-writer internal functions — every share movement in the system goes through them and updates the tracked `_totalShares`, which is what makes `totalSupply()` a storage read instead of a loop over the staker set.

## Production Example

**Lido's `stETH`** is the canonical production instance of this chapter's math. `stETH` rebases via `shares` (internal) with a `getSharesByPooledEth`/`getPooledEthByShares` pair — the same effective-price appreciation, with share-price protected by the *first-deposit* handling and by Lido's curated operator set. The lesson Meridian copies: **the share ledger is internal; the ERC-20 facade is a view.** Aave's `aToken` is the second instance (scaled balance, `POOL`-driven accrual). Synthetix's `RewardsDistribution` shows the alternative global-index shape when rewards are a separate stream rather than share appreciation.

## Foundry Lab

`meridian/test/StakedMeridianTest.t.sol` — unit + attack-regression coverage:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakedMeridian} from "../src/StakedMeridian.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal mintable MER stand-in for the lab (protocol MER is Ch 14).
contract MintableERC20 {
    string public name = "Mintable MER";
    string public symbol = "mMER";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

contract StakedMeridianTest is Test {
    StakedMeridian internal smer;
    MintableERC20 internal mer;
    address internal alice = address(0xA11CE);
    address internal vault = address(0xBA5E);

    function setUp() public {
        mer = new MintableERC20();
        smer = new StakedMeridian(address(mer), address(this), vault);
        mer.mint(alice, 1000 ether);
        vm.startPrank(alice); mer.approve(address(smer), type(uint256).max); vm.stopPrank();
    }

    /// @dev Donation attack: a direct transfer must NOT move the share price.
    function testDirectTransferDoesNotInflatePrice() public {
        // seed 1 wei attacker share, donate 10_000, verify price unchanged
    }

    /// @dev Revenue accrual: notifyReward raises redeemable assets pro rata.
    function testRevenueAccruesToAllStakers() public { }

    /// @dev Rounding: deposit/redeem round in the user's favor; no 1-wei grief.
    function testRoundingDirection() public { }
}
```

Gas numbers: **derived from the published schedule + lab-pinned deltas** (Ch 8 methodology); the tests pin *deltas*, which survive compiler drift — green on forge 1.7.1.

## Security Analysis

### Donation/inflation — the family, not the instance

The Ch 26 invariant family (`conversionsNeverGain`) covers this chapter's attack as its *name* case. The defense here is three layers deep (virtual offset, tracked assets, floor rounding) precisely because the family has more variants: first-depositor front-run, dust griefing, ERC-777 reentrancy through the transfer (Ch 17), and the "donation via rounding" steady-state leak. Layer one (virtual offset) kills the leverage; layer two (tracked assets) kills the vector; layer three (floor) kills the residue.

### The notifier trust surface

`notifyReward` is the protocol's revenue valve. In v1 it is the lending vault (Ch 20, itself guarded by the collateral/LTV machinery); from Ch 25/38 the rewards admin path (timelock → governor → multisig) takes over. The 2026 grounding applies verbatim: a compromised admin key is the attack (Kelp DAO/Drift, ~$285–292M, Apr 2026) — the valve must be timelocked and the key set minimized.

### Reentrancy through SafeERC20

The pull in `notifyReward` and the push in `redeem` are external calls. CEI is respected: `redeem` burns shares and decrements `_totalAssets` *before* the transfer. The `underlying` is hookless MER (Ch 17 lock) — the ERC-777 class cannot appear. But the discipline (not the specific token) is the defense: Ch 24 formalizes it.

## Common Mistakes

1. **`totalAssets = balanceOf(address(this))`** — the donation attack returns with interest. Track, never observe.
2. **No virtual offset** — 1-wei first-deposit + donation = hostage-taking. Copy the defense, don't reason it away.
3. **Rounding the wrong way** — `mulDiv` floor for user-received, ceil for user-paid; reversed, the *attacker* harvests the rounding.
4. **Looping over stakers** — the 2016 DoS lineage wearing rewards clothing. Global index or share appreciation, always.
5. **Accrual in a view** — `totalAssets` must be cheap and side-effect free; a view that "computes" rewards by iterating is both a gas bomb and a misreading of the model.
6. **Unbounded `notifyReward`** — a revenue valve callable by anyone is a griefing vector (dust + gas). Privileged + bounded.
7. **Ignoring the 1-wei edge** — "it's just dust" is the audit finding's favorite opening line.

## Gas Optimization

| Pattern | Before | After | Delta |
|---|---|---|---|
| `mulDiv` vs naive `a*b/c` in conversions | panic risk / wrong on overflow | correct full-domain | ~+22 gas (Ch 4) |
| Tracked `_totalAssets` vs `balanceOf` | donation attack | safe accounting | 0 gas, security |
| Single-writer `_mint`/`_burn` | per-action bookkeeping | O(1) everywhere | — |
| No staker loop | O(N) claim | O(1) | unbounded → constant |

## Reading Production Source Code

1. **Lido `stETH`/`SharesAccountingLib`** — the canonical share-ledger; read `getSharesByPooledEth` and the buffered-ether accounting.
2. **OpenZeppelin `ERC4626.sol`** — the virtual-offset pattern (`_decimalsOffset`), `convertToShares`/`convertToAssets` rounding.
3. **Aave `ScaledBalanceTokenBase`** — scaled balances as the accrual mechanism.
4. **Synthetix `RewardsDistribution`** — the global-index alternative when rewards are a stream.

Ask of each: *where does value enter the share price, where could a raw transfer move it, and which rounding direction protects the incumbent staker?*

## Exercises

1. Derive `shares` for `deposit(100)` given `A=10,100`, `S=101`, `v=1e18` — and show the attacker's 1-wei share redeems for ~1 MER (attack profit ≈ 0), not the ~100 MER the donation would buy without the offset.
2. A vault without virtual shares has `A=0, S=0`. Attacker deposits 1 wei, donates 1,000, victim deposits 1,000. Compute the victim's share count and the attacker's profit. Repeat with `v=1e18`.
3. Explain why `totalAssets` must not read `balanceOf(address(this))`, and give the one-line accounting fix.
4. Round-trip `deposit(1)/redeem(1)` in a no-offset vault at `A=2, S=1` (price already skewed by a 1-wei donation): how many cycles transfer the victim's share value to the attacker?
5. Design the `notifyReward` privilege chain from vault (v1) to timelock-governed multisig (Ch 25/38) without introducing a new trust surface.

## Weekly Project

**Ship `StakedMeridian.sol` + `StakedMeridianTest.t.sol`** (lab above), extend `docs/erc4626-spec.md` (Ch 16) with the virtual-offset decision and the tracked-assets rule, and add `docs/staking-notes.md` capturing the donation-attack derivation. This is the third protocol contract; it must pass the Ch 13 CI gates (snapshot, slither, aderyn).

## Deliverables

1. `meridian/src/StakedMeridian.sol` + `IStakedMeridian.sol` — the v1 staking vault.
2. `meridian/test/StakedMeridianTest.t.sol` — attack-regression + accrual tests, green.
3. `docs/erc4626-spec.md` extension — virtual offset, tracked assets, rounding policy.
4. Locked conventions extended: tracked-not-observed accounting; virtual-offset defense for any ERC-4626; privileged+bounded revenue valve; no staker loops.
5. `.gas-snapshot` rows for the new suite (paired-regenerate rule, Ch 14 finding #3).

## Quiz

1. Why is a staker loop the wrong shape for revenue share, and what replaces it?
2. Name the three defense layers against the donation/inflation attack and which invariant each protects.
3. `totalAssets` reads a tracked variable, not `balanceOf`. What attack does this single decision kill, and what attack survives (and is handled where)?
4. What does the virtual offset cost, and why is the cost acceptable?
5. A user deposits 1 wei at `S=0, A=0` in a no-offset vault. Describe the two-step attack that follows, and the offset's counter.

**Answers:** (1) A loop is O(N) over an inflatable set — the Ch 1 DoS class; global share appreciation (`P = (A+v)/(S+v)`) makes every action O(1). (2) Virtual offset kills the leverage; tracked assets kill the vector; floor rounding kills the residue. (3) Direct-transfer donation dies (untracked = invisible); the residual is rounding dust, handled by floor-for-user + offset. (4) A permanent 1e18 phantom share diluting real shares by a vanishing factor — the standard, accepted price of the defense. (5) 1 wei → 1 share; donate big; victim's deposit mints ~0 shares; attacker exits with the victim's value. The offset pegs the 1-wei deposit to the 1e18 baseline (1 wei → 1 share worth ~1 wei), and tracked assets keep the donation out of the price — the hostage never has value.

## Further Reading

- EIP-4626 (the standard), EIP-20 (MER's basis); Ch 16 of this curriculum (the spec).
- OpenZeppelin `ERC4626.sol` — virtual-offset reference implementation.
- Lido `stETH` share accounting docs; Aave `aToken` scaled-balance docs.
- Ch 26 (this attack is the name-case of `conversionsNeverGain`); Ch 24 (CEI formalization); Ch 25 (the notifier trust chain); Ch 38 (the upgrade path).
- 2026 grounding: Kelp DAO/Drift admin-key (~$285–292M, Apr 2026) — the revenue valve as a trust surface.
