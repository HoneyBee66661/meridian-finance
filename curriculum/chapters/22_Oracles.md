# Oracles

Chapter 21 priced *time*; this chapter prices *risk*. `OracleRegistry.sol` — protocol contract #5 — is the single place where Meridian decides what an asset is worth: Chainlink as the primary source, an on-chain TWAP as the fallback, and a deviation guard between them. It implements the `IMeridianOracle` surface that has been pinned since Ch 3 and extended in Ch 20 — `latestRoundData`, `consult`, `decimals`, and the per-asset `getPrice` that `MeridianVault.borrowCapacity` and `_healthFactor` actually consume. The vault (Ch 20) and the rate model (Ch 21) are *consumers* of prices; this chapter is where the manipulation-resistance choice lives, and it is deliberately a single decision point: one registry, one policy, one place to audit.

## Learning Objectives

1. Explain the Chainlink architecture — decentralized oracle network (DON) with off-chain consensus, on-chain aggregator (report verification/storage), stable proxy, median aggregation, heartbeat + deviation threshold — and read `latestRoundData` like an auditor.
2. Define the staleness contract: what `updatedAt`, `answeredInRound`, and `maxStaleness` mean, and what happens when a feed freezes (LUNA, May 2022).
3. Derive the Uniswap v2 cumulative-accumulator TWAP from first principles and prove, with numbers, how little a single-block flash loan can move a 30-minute window — and what sustained manipulation costs.
4. Classify the oracle manipulation surface against real incidents: flash-loan spot manipulation (bZx, Harvest, PancakeBunny), self-referential mark prices (Mango), share-price collateral (Cream, Warp), staleness under stress (LUNA).
5. Design `OracleRegistry`: per-asset feed config, the 18-dec WAD canonical base, the listing gate, staleness → TWAP fallback ordering, and the deviation guard.
6. Justify every privileged function sitting behind `DEFAULT_ADMIN_ROLE` (Ch 25 timelock) — a feed config key is an admin key.
7. Implement and verify the registry against the vault: borrow capacity and health factor driven by real registry prices, including the stale-feed liquidation scenario.
8. Measure the price of a price: `getPrice` gas anatomy vs the Ch 8 gas budget.

## Prerequisites

- **Chapter 20** (Lending Markets I) — `borrowCapacity` and `_healthFactor` as the price consumers; the vault error catalog; the `getPrice(address)` additive extension to `IMeridianOracle`.
- **Chapter 3** (ABI Encoding) — the Ch 3 ABI pins (`latestRoundData`, `consult`, `decimals`) that `OracleRegistry` must not break; `IMeridianOracle` is a Ch 3 Weekly Project artifact.
- **Chapter 17** (Token Security Patterns) — the listing gate: Meridian only lists plain ERC-20s, which keeps `balanceOf`-based accounting meaningful; the registry applies the same gate to *prices*.
- Supporting: **Ch 4** (WAD, rounding policy — the canonical-base normalization), **Ch 6** (storage packing, EIP-1967 — upgradeable-storage mechanics; the feed *proxy* is a stable address over swappable aggregators, not a generic EIP-1967 instance), **Ch 8** (gas budget — the price read is on the borrow path), **Ch 10** (parameter-exact `vm.expectRevert`), **Ch 14** (I-prefix error catalogs), **Ch 21** (the model that consumes utilization, never prices).
- Foreshadowed: **Ch 24–25** (the liquidation engine reads exactly `getPrice`; pause semantics when the registry reverts), **Ch 27** (bridge/trust-chain failures — the feed *config* is a trust root), **Ch 35** (OEV/MEV — oracle update auctions as a design response), **Ch 31** (L2 feed deployment post-Fusaka).

## Theory

### Why prices are the whole game

A lending protocol's collateral is only worth what its oracle says. Every manipulation-resistance property of the rest of the system — the vault's CEI ordering, the rate model's immutables, the rounding directions — is downstream of one number: the price. Get the price wrong and the rest is theater.

Three incidents make the stakes concrete:

- **Mango Markets (Oct 2022, ~$114M).** The attacker drove up the price of their own MNGO-PERP position on a thin order book, then borrowed ~$114M against the inflated mark price. The oracle was the perp's *own* mark price — a self-referential price derived from the very book being attacked. No feed to corrupt; the protocol priced itself.
- **Cream Finance (Oct 2021, ~$130M).** Collateral (Yearn vault shares) was valued at a share price the attacker could inflate with flash loans, then borrowed against at face value. The price was *derived from a manipulable share rate* — the Ch 21 failure class, now seen from the oracle side.
- **LUNA/USD, May 2022.** During the UST depeg, the LUNA feed's updates lagged the collapse; protocols kept pricing LUNA at values the market had already left behind. Borrowers extracted value against collateral that was, in reality, near worthless. Not manipulation — *staleness under stress*.

The design question this chapter answers: what does a price have to be, structurally, before a lending protocol may borrow against it? Meridian's answer, locked here: **a median of independent off-chain observations (Chainlink), with an on-chain time-weighted fallback that bounds any single block's influence, and a guard that refuses to trade when the two disagree.**

### Chainlink architecture

Chainlink Data Feeds are the de-facto standard for DeFi pricing (the mainnet ETH/USD proxy is `0x5f4e…8419`, ledger-pinned since Ch 11). The architecture that makes a feed trustworthy:

- **DON (decentralized oracle network)** — a set of independent node operators who each fetch the price from their own sources and submit observations off-chain.
- **On-chain aggregator** — the on-chain contract that verifies and stores the latest report. Modern feeds run **OCR (off-chain reporting)**: the DON's nodes observe their sources and reach consensus **off-chain**, then one node transmits the aggregated report — a median of the nodes' observations — to the aggregator, which verifies the report's signatures against the node set and stores the answer. The aggregation happens off-chain; the on-chain contract checks and records, it does not aggregate raw submissions itself.
- **Proxy** — integrators do not call the aggregator directly; they call a **stable proxy address** that forwards to the current aggregator and maintains the feed's phase/aggregator history, so an aggregator swap never changes the address integrators hardcode. This is Chainlink's own proxy/aggregator design, distinct from a generic EIP-1967 upgradeable — Ch 6's unstructured-slot pattern still explains how upgradeable storage works in general, but the feed proxy should not be taught as an EIP-1967 instance unless a specific deployment has been verified as one.
- **Update policy** — a feed updates when **either** of two conditions fires: a **deviation threshold** (price moved more than X%) or a **heartbeat** (a maximum silence period). Deviation threshold keeps the price fresh during moves; heartbeat guarantees a floor on liveness even when the price is flat. This is exactly the two-failure-mode design a lending protocol needs: a feed that only updates on deviation could go silent for days in a flat market. The trigger values are **feed- and network-specific** — the 0.5% deviation / 1-hour heartbeat pair is the Ethereum ETH/USD configuration as of this writing, not a universal constant — so governance pins the exact values per deployment (Meridian's per-asset `maxStaleness`, below).

The consumer-facing surface is `latestRoundData()`:

```solidity
function latestRoundData() external view returns (
    uint80 roundId,      // increments per update
    int256 answer,       // the median price, in the feed's base unit
    uint256 startedAt,   // when the round started
    uint256 updatedAt,   // when the round last updated — the heartbeat clock
    uint80 answeredInRound // which round produced this answer
);
```

USD pairs quote **8 decimals** (ETH at $2,000 reads `2000e8`). Two fields carry the audit signal: `updatedAt` (staleness) and `answeredInRound` (which round produced this answer). One legacy warning up front: in the modern OCR model `answeredInRound` is a compatibility field — the OCR aggregator sets it equal to the round ID, so a strict `answeredInRound >= roundId` check adds little on current feeds. The staleness section leads with the four universal `updatedAt`/`answer` conditions and treats the round check as v1's explicit implementation choice, not a universal requirement.

### Staleness: the heartbeat contract

A feed is only as good as its liveness. The registry treats the primary as healthy only if **all** of:

```
answer > 0
updatedAt != 0
updatedAt <= block.timestamp
block.timestamp - updatedAt <= maxStaleness     // per-asset, e.g. 1h
answeredInRound >= roundId                       // v1's legacy round-completeness check
```

The first four conditions are the **universal freshness test**, and each is a real failure mode: non-positive answers (feed glitch), `updatedAt == 0` (never updated), future timestamps (clock skew on the aggregator), and heartbeat expiry (feed frozen — the LUNA class). The fifth is the round-completeness check, and it carries the legacy caveat from above: on modern OCR feeds `answeredInRound` is set equal to the round ID, so the check is effectively vestigial there. Meridian v1 still enforces all five — `OracleRegistry.sol` pins `answeredInRound >= roundId`, and the test suite exercises the lagged-round case (`test_getPrice_laggedAnsweredInRound_usesTwap`) — which is an explicit implementation choice, safe but not a universal requirement: an integrator should add the round check only when the specific feed meaningfully supports it. Any single failure routes `getPrice` to the TWAP fallback. If there is no fallback, `getPrice` **reverts `FeedUnhealthy`** — an unpriced asset is an unhealthy asset, and the protocol's designed failure mode is *no borrowing and no liquidations* rather than borrowing and liquidating at a number nobody trusts.

### L2 extension: the Sequencer Uptime Feed

v1's posture is mainnet (Ch 31's L2 deployment is post-Fusaka roadmap), but the L2 failure mode differs in kind, not degree, and is worth locking now. On a rollup the sequencer is a single point of liveness: while it is down, *no* transactions settle — including the oracle updates that keep feeds fresh — yet the on-chain feed still reports a last-known price that may now be arbitrarily stale. `updatedAt` alone cannot distinguish "market is flat" from "the chain has been down for an hour."

Chainlink's L2 answer is the **Sequencer Uptime Feed**, a per-chain flag feed read alongside the data feed. The L2 `getPrice` precondition becomes:

```
sequencerUp == true       // uptime feed answer 1 = sequencer running
grace period elapsed      // configurable recovery window after the
                          // sequencer returns before prices are trusted
```

If the uptime feed reports the sequencer down — or the current time is still inside the configurable grace period after recovery — every primary feed is treated as unhealthy: `getPrice` routes to the TWAP fallback, or reverts `FeedUnhealthy` if there is no fallback. The grace period matters because the sequencer replays its backlog quickly on recovery: prices jump as the backlog lands, and borrowing or liquidating inside that window trades on a partially-replayed state. Chainlink's guidance is that L2 protocols *should* gate on the uptime feed before acting on prices; a lending protocol that ignores it can liquidate users against stale L2 prices immediately after an outage. This gate is an **L2 deployment extension** — v1's mainnet registry has no sequencer to watch (the repo's `getPrice` is the mainnet form), and the gate lands with the Ch 31 L2 feed wiring as part of the per-chain feed configuration.

### TWAP fallback: derivation

The fallback is an on-chain **time-weighted average price** from an AMM pair (Uniswap v2-style cumulative accumulator; the `consult(address,uint256)` surface pinned in Ch 3 is the v2-periphery shape). The derivation:

**The accumulator.** The pair keeps `price0CumulativeLast`, updated on the first interaction of each block:

```
price0CumulativeLast += price0 * (block.timestamp - lastTimestamp)
```

where `price0 = reserve1 / reserve0` is the spot price *before* that interaction's swap. The accumulator is the integral of spot price over time.

**The TWAP.** Over a window `[t0, t1]`:

```
TWAP = (price0Cumulative(t1) - price0Cumulative(t0)) / (t1 - t0)
```

This is the **arithmetic mean of per-block spot prices, weighted by block duration** — exactly what "time-weighted" means.

**Why a single-block flash loan cannot move it much.** To change the TWAP over a window, an attacker must change the *integral* of price over that window. A flash loan touches one block: at 12-second slots, one block out of a 30-minute window is `1/150` of the window. A flash price of 2× real (an extreme 100% distortion) contributes at most `(1/150) × 100% ≈ 0.67%` error to the TWAP. To bias the TWAP by a meaningful 5%, the attacker must hold a distorted price for ~7.5 blocks (90 seconds at 2×) — and at 2× distortion, the capital required to move a liquid pair's price that far, held for 90 seconds, is the attack's real cost. **TWAP resistance is a capital-and-time argument, not a cryptographic one:** a single-block manipulation has bounded influence, while sustained manipulation requires capital and time proportional to the window. The window is the knob: longer window = more manipulation-resistant but lags the true price (bad during fast moves — liquidations execute late); shorter window = fresher but less resistant. Meridian's default is **30 minutes**, governance-adjustable per deployment (Ch 25 timelock).

**Uniswap v3 nuance.** v2's accumulator sums `price × time` — the arithmetic time-weighted mean derived above. v3 instead accumulates the *log* of each tick's price over time: `observe(secondsAgo)` interpolates between adjacent observations in that log space, and the result is the **geometric mean** of price (exp of the time-weighted log-price sum). The geometric mean is less skewed by a single large move than the arithmetic mean — the price series' multiplicative structure is preserved. The registry's `consult` surface is agnostic to which implementation the market uses; the listing contract requires the market to return a window-valid price in a declared decimal scale.

### The manipulation surface, classified

Every incident in this chapter is one of four classes, and each class maps to a locked design decision:

**Class 1: flash-loan spot manipulation.** Attackers borrow huge capital for one transaction to move a spot or AMM-derived price, then trade against the mispriced protocol. **bZx (Feb 2020, ~$1M across two attacks)** — the first major flash-loan oracle exploit: a price divergence between Kyber and Uniswap let the attacker borrow against mispriced ETH. **Harvest Finance (Oct 2020, ~$33.8M)** — a flash loan moved the Curve USDC/USDT pool price the farm's strategy priced itself against. **PancakeBunny (May 2021)** — a flash loan pumped BUNNY on PancakeSwap, letting the attacker mint ~7M BUNNY and dump it (~96% crash; reported losses in the tens of millions). **Warp Finance (Dec 2020, ~$7.7M)** — Uniswap v2 *LP token* prices were computed from live reserves, which a flash loan could swing. *Meridian's answer:* the primary price is Chainlink (off-chain median, not any on-chain spot), and the fallback is time-weighted — neither is a single-block spot read.

**Class 2: self-referential prices.** The protocol prices an asset using a market the attacker controls. **Mango (Oct 2022, ~$114M)** — the oracle was the perp's own mark price, driven by the attacker's orders on a thin book. *Meridian's answer:* prices come from the registry's configured sources, never from a Meridian-internal market or a book the attacker trades against.

**Class 3: derived share prices.** Collateral priced at a share rate that itself depends on manipulable inputs. **Cream (Oct 2021, ~$130M)** — Yearn vault shares; **Warp (Dec 2020)** — LP shares. *Meridian's answer:* the Ch 17 listing gate (no rebase, no hooks, plain ERC-20) plus the registry's rule that a listed asset's price comes from its own feed, never from a share-derived rate.

**Class 4: staleness under stress.** The feed is honest but frozen. **LUNA/USD (May 2022)** — the feed lagged the collapse, and protocols priced collateral at stale values. *Meridian's answer:* the heartbeat contract above — `maxStaleness` per asset, TWAP fallback, and `FeedUnhealthy` revert when neither source is trustworthy.

A fifth class is *not* an oracle bug but an oracle *key*: **compromised feed configuration.** The **Kelp DAO/Drift (Apr 2026, ~$285–292M)** admin-key class, carried from Ch 8–21, applies directly: whoever can call `setFeed` can set any price. A feed config key is an admin key — which is why the registry's privileged surface is exactly `DEFAULT_ADMIN_ROLE`, held by the Ch 25 timelock in production.

### OracleRegistry design (protocol contract #5)

The registry is a per-asset price resolution service. For each listed asset it stores a `FeedConfig` — packed into three slots per Ch 6 (feed + twapMarket share a slot; maxStaleness one; deviationGuardBps + twapDecimals one):

```solidity
struct FeedConfig {
    IChainlinkFeed feed;        // primary
    address twapMarket;         // fallback (ITwapSource), 0 = none
    uint256 maxStaleness;       // heartbeat expiry, seconds
    uint256 deviationGuardBps;  // 0 = disabled
    uint8 twapDecimals;         // scale of the market's consult() output
}
```

**The canonical base — a design decision the vault's arithmetic forces.** Ch 20's `borrowCapacity` computes:

```solidity
collValue = collateralAmount.mulDiv(getPrice(collateralToken), 10 ** collateralDecimals);
```

The vault divides the price by `10^tokenDecimals` — so `getPrice` must return **USD per whole token at 18 decimals (WAD)** for *every* asset, regardless of the feed's native scale. The `IMeridianOracle` NatSpec's informal example ("2000e8 for an 8-decimal feed") is superseded by the vault's math: an 8-decimal feed answering `2000e8` is normalized to `2000e18`. This is the same base Ch 4 locked for every Meridian amount, and it makes the health factor scale-consistent across a 6-decimal debt token and an 18-decimal collateral token with no per-market constants.

**Resolution order.** `getPrice(asset)`:

1. Not listed → `AssetNotListed(asset)`.
2. Read the primary; healthy per the heartbeat contract (all five conditions) → normalize to WAD.
3. Primary healthy **and** deviation guard enabled → also read the TWAP; if `|primary − twap| / max(primary, twap)` exceeds the guard in bps → **revert `DeviationGuardReverted`**. Reverting is the safe direction: liquidations pause on a suspect price instead of executing on one (pause semantics land with the engine, Ch 24–25).
4. Primary unhealthy → TWAP fallback (normalized); no market or zero price → `FeedUnhealthy(asset)`.

**The listing gate** (the Ch 17 gate applied to prices): non-zero asset and feed; `feed.decimals() ≤ 18` (validated with a live `decimals()` call — the feed must be a real aggregator, catching misconfigured addresses at listing time); `twapDecimals ≤ 18`; nonzero `maxStaleness`. Listing is a governance action, so the gate runs at listing, not per-read.

**Deliberate surface deviations, documented:** `latestRoundData()` (the no-arg Ch 3 ABI pin) is meaningless on a multi-asset registry — it reverts `UnsupportedForRegistry`; the per-asset surface is `getPrice`. `consult(market, secondsAgo)` is a passthrough to the market's own consult. `decimals()` returns 18 (the canonical base). v1 is plain storage like `MeridianVault` v1 (Ch 20); ERC-7201 namespacing applies when markets become proxies (Ch 38).

## Mathematical Foundations

**TWAP error bound under manipulation.** Let the true price be `p`, the attacker's distorted price `p' = (1 + d)·p` over a fraction `f` of the window `W` (in time, not blocks), and `p` otherwise. The TWAP is:

```
TWAP = f·(1+d)·p + (1−f)·p = p·(1 + f·d)
```

so the induced error is exactly `f·d`. With Meridian's 30-minute window on a 12-second chain, a single block is `f = 12/1800 = 1/150 ≈ 0.67%` of the window: even a 100% distortion (`d = 1`) for one block moves the TWAP by `0.67%`. The same bound shows the attack cost: biasing the TWAP by 5% requires `f·d = 0.05` — e.g. 25% distortion held for 20% of the window (6 minutes), during which the attacker must *both* hold the pair's price at `1.25p` *and* pay the trading cost of moving it there.

**Deviation guard math.** The guard compares the two independent sources: `dev = |primary − twap| · 10_000 / max(primary, twap)` in bps, relative to the larger so `dev ≤ 10_000` always. A feed that is technically fresh (within heartbeat) but diverges from the on-chain market consensus trips the guard — catching the "honest-but-wrong" failure (feed lagging a fast move, or a corrupted-but-updating aggregator) that staleness alone cannot see.

**Normalization.** `_normalize(raw, dec, 18)`: identity at 18; `raw · 10^(18−dec)` up-scale (exact); `raw / 10^(dec−18)` down-scale (floor — understating collateral is the conservative direction, Ch 4/16 policy). Because listing caps both feed and TWAP decimals at 18 and the target is 18, the down-scale branch is unreachable in practice — kept as a defensive invariant, documented as such.

## Production Example

**The `getPrice` hot path.** For a healthy primary with the guard disabled (the default), one `getPrice` costs: 3 packed-config SLOADs on first touch (cold 2,100 each — the mapping slot plus the two remaining config slots; the feed+market pair shares one slot, Ch 6 packing working for the gas budget) + one external `latestRoundData` call (cold account 2,600) + one warm `decimals()` call on the same feed + the normalization multiply. Measured in this chapter's lab (loop-amplified min-deltas, warm-up first, Ch 8/9 methodology):

```
getPrice primary healthy:     4,800 gas
getPrice TWAP fallback:       4,547 gas   (one external call, not two)
getPrice deviation guard on:  6,831 gas   (+2,031 for the extra consult)
```

The fallback is *cheaper* than the healthy primary because it makes one external call (consult) instead of two (latestRoundData + decimals) — a nice property: the degraded path costs less, not more. The vault's borrow path (Ch 20 snapshot row 221,988 with the SLOAD-only mock) pays two `getPrice` calls per interaction (collateral + debt), so the real registry adds roughly `2 × 4,800 ≈ 9,600` to the borrow path — the Ch 8 gas budget's oracle line, now measured, not estimated. Test-level rows: `test_getPrice_primaryHealthy_normalizesToWad` 55,443; the vault integration scenarios 3,377,572 / 3,361,504 (full deposit+borrow+health flows).

**Deployment wiring.** The vault is constructed with the registry as its `IMeridianOracle`; the registry is then governance-listed for the market's two assets (collateral feed + TWAP market + staleness + guard). Because the vault consumes only `getPrice`, the registry can change its internals (extra feeds, median-of-feeds, L2 feed addresses post-Fusaka — Ch 31) without touching the vault's ABI.

## Implementation

`src/OracleRegistry.sol` implements `IMeridianOracle` on OZ v5.7.0 `AccessControl`. Key surfaces:

- `setFeed(asset, feed, twapMarket, maxStaleness, deviationGuardBps, twapDecimals)` — `onlyRole(DEFAULT_ADMIN_ROLE)`; the listing gate; emits `FeedSet`.
- `setTwapWindow(uint256)` — `onlyRole`; default 30 minutes; emits `TwapWindowSet`.
- `getPrice(asset)` — the resolution order above; reverts `AssetNotListed` / `FeedUnhealthy` / `DeviationGuardReverted`.
- `consult(market, secondsAgo)` passthrough; `latestRoundData()` → `UnsupportedForRegistry`; `decimals()` → 18.
- Error catalog (I-prefix convention, Ch 2/14): `AssetNotListed`, `FeedUnhealthy`, `InvalidConstructorAddress`, `InvalidFeedDecimals`, `InvalidTwapDecimals`, `InvalidMaxStaleness`, `DeviationGuardReverted`, `UnsupportedForRegistry`.

The test suite (`test/OracleRegistry.t.sol`, 30 tests) pins: the staleness matrix (every unhealthy signal — heartbeat expiry, future timestamp, lagged round, negative/zero answer — routes to the TWAP), the normalization ladder (fuzz over all 19 decimal scales, 0–18), the deviation guard (revert, within-limit pass, disabled), governance negatives (Ch 10 convention), and two vault integration scenarios — borrow capacity computed from real registry prices, and a stale-feed price drop flipping a position liquidatable (the engine itself still reverts `LiquidationNotImplemented`, arriving Ch 24–25).

## Security Analysis

**What the design resists:** single-block flash manipulation (TWAP + off-chain median), frozen feeds (heartbeat + fallback), round incompleteness (`answeredInRound`), fresh-but-wrong feeds (deviation guard), and config compromise (role-gated, timelock-held). **Residual risks, acknowledged:** (1) *TWAP lag* — a genuine fast move under-prices collateral for up to the window; the guard's default-off posture means governance should enable it per volatile asset. (2) *Single primary feed per asset* — median-of-feeds is a future additive extension, not v1. (3) *TWAP market liquidity* — the fallback is only as honest as the pair's liquidity; the listing gate should require a deep, established pair (governance checklist item). (4) *The registry's own admin* — the 2026 trust surface is real: the timelock (Ch 25) is the control surface, and the multisig is its emergency fallback. (5) On L2s (Ch 31), feeds are DON-deployed per chain with different heartbeats — `maxStaleness` is per-market governance, not a constant, exactly so L2 deployment can tune it, and the Sequencer Uptime Feed gate (above) joins the L2 `getPrice` precondition.

## Weekly Project

- `docs/oracle-registry.md` — the registry spec: the heartbeat contract, the canonical-base derivation (why the vault's arithmetic forces WAD), the listing checklist (feed address verified, TWAP market deep + window-valid, guard enabled per volatile asset), the deviation-guard semantics (revert = pause), and the deployment wiring (vault constructed with registry; registry listed for both assets).
- `docs/gas-budget.md` extension — the measured oracle line (4,800 healthy / 4,547 fallback / 6,831 guard-on per `getPrice`; ~9,600 added to the two-price borrow path), replacing the Ch 8 estimate.
- On disk this run: `src/IChainlinkFeed.sol`, `src/ITwapSource.sol`, `src/OracleRegistry.sol`, `test/OracleRegistry.t.sol` — compile-verified, suite green, snapshot regenerated (numbers in the Ledger Update).

## Deliverables

1. `src/IChainlinkFeed.sol` + `src/ITwapSource.sol` — minimal local interfaces (no Chainlink package dependency; ABI-identical to the deployed aggregator proxies).
2. `src/OracleRegistry.sol` — the registry, implementing `IMeridianOracle`. **Protocol contract #5.**
3. `test/OracleRegistry.t.sol` — 30 tests: staleness matrix, normalization fuzz, deviation guard, governance negatives, interface pins, vault integration (borrow capacity + liquidation-flip), gas probes.
4. Full suite green: **454 passed / 0 failed / 0 skipped (454 total) across 31 suites** (Ch 21 baseline 424 across 30); `.gas-snapshot` regenerated under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234` (paired regenerate+check; only the 6 known pre-existing fuzz-μ rows flagged — Ch 14 finding #3 recurrence).
5. Size: `OracleRegistry` 4,350 B runtime / 20,226 B margin (EIP-170 healthy; Ch 13 `--sizes` gate watching).
6. Gas profile (measured): `getPrice` primary 4,800 · fallback 4,547 · guard-on 6,831.
7. Conventions locked: canonical base = 18-dec WAD USD per whole token (vault arithmetic authoritative over the interface NatSpec example); heartbeat contract (5 conditions); staleness → TWAP → `FeedUnhealthy`; deviation guard reverts (pause, safe direction); `latestRoundData()` unsupported on the registry; feed config = `DEFAULT_ADMIN_ROLE` (Ch 25 timelock).

## Quiz

1. Name the five conditions of the heartbeat contract and the incident class each one blocks.
2. Derive the TWAP error bound `f·d`. How many 12-second blocks is 1% of a 30-minute window, and what does that mean for a flash loan?
3. Why must `getPrice` return 18-dec WAD prices even when the feed quotes 8 decimals? Point at the vault line that forces it.
4. Classify: Mango, Cream, LUNA feed lag, Harvest — which manipulation class, and which registry feature answers each?
5. The deviation guard reverts instead of returning the primary. Why is reverting the safe direction?
6. Why is `answeredInRound < roundId` a staleness signal even when `updatedAt` looks fresh?
7. What does the registry do when the primary is stale and the TWAP market is unset? Why is that the designed failure mode?
8. Why does the TWAP fallback cost *less* gas than the healthy primary path?
9. `setFeed` is role-gated. Which 2026 incident class does that answer, and where does the role live in production?

**Answers:** (1) `answer > 0` (glitch), `updatedAt != 0` (never updated), `updatedAt <= block.timestamp` (clock skew), `updatedAt` within `maxStaleness` (frozen feed — LUNA class), `answeredInRound >= roundId` (round completeness — v1's legacy implementation choice; the first four are the universal freshness test). (2) TWAP = `p·(1 + f·d)`; 1% of 1800s = 18s = 1.5 blocks, so a single-block flash move contributes `(1/150)·d ≤ 0.67%` — under the rounding noise of the health factor, not a liquidation vector. (3) `borrowCapacity` divides `getPrice` by `10^tokenDecimals` (Ch 20 lines 205–211); only a uniform WAD base keeps the health factor scale-consistent across token decimals. (4) Mango — self-referential mark price → sources never derived from Meridian-internal books; Cream/Warp — derived share prices → listing gate + feed-per-asset; LUNA — staleness under stress → heartbeat + fallback; Harvest — flash-loan spot manipulation → off-chain median + time-weighted fallback. (5) A revert pauses borrowing and liquidations on that asset; executing on a suspect price lets liquidators (or the attacker) trade against a number nobody trusts. (6) `answeredInRound` records which round produced the answer; a lagging value means the current round hasn't completed — the aggregator may be mid-update or stalled, so the answer is not current even if `updatedAt` was recently bumped. Caveat: on modern OCR feeds the aggregator sets `answeredInRound` equal to the round ID, so the check is legacy — v1 keeps it as an explicit implementation choice, not a universal rule. (7) Reverts `FeedUnhealthy` — no borrowing, no liquidations on an unpriced asset; the designed failure mode per `IMeridianOracle` NatSpec. (8) The fallback makes one external call (consult) versus two (latestRoundData + decimals) — measured 4,547 vs 4,800. (9) The compromised-admin class (Kelp DAO/Drift, ~$285–292M, Apr 2026) — a feed config key is an admin key; the role is `DEFAULT_ADMIN_ROLE`, held by the Ch 25 timelock with the Safe multisig as emergency fallback.

## Further Reading

- **Chainlink Data Feed docs** — DON architecture, median aggregation, proxy/aggregator pattern, heartbeat + deviation-threshold update policy; the mainnet ETH/USD proxy `0x5f4e…8419`.
- **Uniswap v2 pair + periphery (`exampleOracleSimple`)** — the cumulative-accumulator TWAP derivation this chapter ports; v3's `observe`/geometric-mean observations as the modern variant.
- **Mango Markets post-mortem (Oct 2022, ~$114M)** — the self-referential mark-price class.
- **Cream Finance (Oct 2021, ~$130M)** and **Warp Finance (Dec 2020, ~$7.7M)** — derived share-price collateral.
- **Harvest Finance (Oct 2020, ~$33.8M)** and **bZx (Feb 2020)** — flash-loan spot-manipulation originals.
- **LUNA/USD (May 2022)** — feed staleness under stress.
- **Kelp DAO / Drift (Apr 2026, ~$285–292M, admin keys)** — feed config as privileged state; full treatment Ch 27.
- **Ch 20** (`MeridianVault` consumers), **Ch 24–25** (liquidation engine + timelock), **Ch 31** (L2 feeds), **Ch 35** (OEV).
