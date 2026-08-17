# 7. Gas Mechanics

## Learning Objectives

By the end of this chapter you will be able to:

1. Explain what gas actually meters — an opcode-level execution budget charged by the interpreter before each instruction runs, from the 21,000 intrinsic to the last memory-expansion word — and why that abstraction exists at all.
2. Reconstruct the state-access cost ladder from the 2016 DoS attacks through EIP-150 and EIP-1884 to **EIP-2929's cold/warm model** (2,100/100), and recite which addresses and slots start warm in every transaction.
3. Compute the cost of *any* `SSTORE` from the `(original, current, new)` triple: set, reset, clear, restore, the 4,800 clear refund, the restore refund, and the **EIP-3529 refund cap** `gas_used/5`.
4. Decide when an **EIP-2930 access list** pays for itself — including the honest truth that a listed read nets only ~+100 and a written slot ~+200 (single touch; later touches of the same slot are warm with or without the list), so the real win is the stable estimate, not raw gas.
5. Derive the **EIP-1559** base-fee update, the priority fee, and the burn from block fullness, and read `eth_feeHistory` like a fee-market dashboard.
6. Audit a transaction like a gas accountant: cold-access waste, refund dependence, unbounded loops, and calldata-heavy payloads that now hit the **EIP-7623** floor.

## Prerequisites

- **Chapter 1** (The EVM Execution Model) — intrinsic gas (21,000), the 63/64 rule (EIP-150), memory expansion `3w + w²/512`, refund cap `gas_used/5` (EIP-3529) were all defined there. This chapter prices them and adds the fee market around them.
- **Chapter 6** (Storage Layout & Packing) — the slot model EIP-2929's accessed-sets operate on; the 2,100/100/22,100 numbers cited there are derived *here*.

## Theory

### What gas actually meters

Gas is the EVM's answer to the halting problem: a universal meter that makes every computation cost something, so no program can run forever. The Yellow Paper defines each opcode's cost function — fixed costs plus dynamic components (memory expansion, hashed words, cold state access) — and the interpreter **deducts the charge before executing the instruction**. Run out mid-instruction and the whole call frame reverts; every state change in that frame is rolled back, which is exactly why out-of-gas is a *safety* property, not just a billing one.

The bill has three phases, and keeping them separate is the key to reading it:

1. **Intrinsic gas** — paid up front for the transaction itself: 21,000 base, plus 4 gas per zero byte and 16 per non-zero byte of calldata.
2. **Execution gas** — every opcode as it runs: arithmetic, memory, `SLOAD`/`SSTORE`, `CALL`s, logs (375 + 375/topic + 8/byte), code deposit (200 gas per deployed byte — a separate charge from EIP-170's 24,576-byte runtime-code cap).
3. **Refunds** — credited *after* execution, capped, applied to the gas used before the fee is computed (EIP-3529: never more than `gas_used/5`).

Two structural rules frame everything below. First, **EIP-150's all-but-one-64th rule**: when a call requests more gas than the cap, the EVM forwards at most `remaining − remaining/64` of the caller's gas to the callee — the callee may consume less and return the rest, but it can never receive more than 63/64 of what the caller had left. This is the DoS defense that replaced unbounded call depth. Second, **cold vs warm**: since EIP-2929 (Berlin, April 2021), the EVM tracks every account and storage slot touched in the current transaction; the first touch of an address costs 2,600 (account) or a slot 2,100, and every later touch in the same transaction costs 100. Cold/warm state access is one of the dominant components of many state-heavy DeFi transactions — a lending vault touching collateral, debt, oracle, and two tokens per user operation can spend a large share of its budget on *first touches*.

### The state-access ladder: from the 2016 DoS attacks to EIP-2929

Cold/warm pricing is the endpoint of a decade of cost rebalancing driven by attacks. In **September–October 2016**, an attacker exploited the fact that state-reading opcodes were priced for register access, not disk I/O: transactions hammering `EXTCODESIZE` on thousands of distinct accounts (later refined to `SLOAD`-heavy calls) made miners take *minutes* per block — the **Shanghai DoS attacks** (named for the Shanghai block range they targeted). Miners hard-coded lower gas limits; Geth and Parity rushed patches; and the emergency **EIP-150 fork (Tangerine Whistle, October 2016)** raised `EXTCODESIZE` 20→700, `BALANCE` 20→400, `SLOAD` 50→200, `CALL` 40→700, and introduced the 63/64 rule. The earlier **state-bloat DoS (August 2016)** — ~19 million empty accounts created by spam transactions — was answered by **EIP-158/161 (Spurious Dragon, November 2016)**, which cleared the empty accounts and charged 25,000 gas for creating a new account. The ladder continued: **EIP-1884 (Istanbul, 2019)** raised `SLOAD` 200→800 and `BALANCE` 400→700, and **EIP-2929 (Berlin, 2021)** finally made the model explicit with the accessed-sets and the 2,100/100 split. **EIP-3651 (Shanghai, 2023)** warmed the coinbase so fee-recipient payouts skip the cold charge (~2,500 gas saved per payout for proposers and builders).

The warm set at transaction start, per EIP-2929: the sender, the recipient, and the precompiles at `0x01`–`0x09`. Everything else — every contract you call for the first time, every storage slot you first read or write — pays the cold surcharge once, then joins the warm set for the rest of the transaction. That is the entire economics of access lists, below.

### SSTORE: the full state machine

`SSTORE` is priced by a three-value state machine — the slot's value at the *start of the transaction* (`original`), its value *now* (`current`), and the value being written (`new`). Post-EIP-3529 (London, 2021), warm, with the EIP-2929 cold surcharge (+2,100 on first touch, paid once per slot per transaction):

| Case (warm) | Cost | Refund (at tx end) |
|---|---|---|
| `new == current` (no-op) | 100 | — |
| Clean: `original == current`, `original == 0` (set) | 20,000 | — |
| Clean: `original == current != 0`, `new != original` (reset) | 2,900 | — |
| Clean reset with `new == 0` (clear) | 2,900 | +4,800 |
| Dirty: `original != current` | 2,900 | — |
| Dirty clear: `original != 0 && new == 0` | 2,900 | +4,800 |
| Dirty re-create: `original != 0`, slot cleared this tx (`current == 0`), `new != 0` | 2,900 | −4,800 (claws back the clear refund) |
| Restore: `new == original` (dirty) | 2,900 | +2,800 (`SSTORE_RESET_GAS − SLOAD_GAS`) |

Cold variants: set 22,100, reset/clear 5,000, no-op 2,200. The **4,800 clear refund** (reduced from 15,000 by EIP-3529) is the reason "zeroing storage is cheap" — but the refund is credited at transaction end and **capped at `gas_used/5`**, so it only fully lands inside a transaction that already spends ≥ 24,000 gas. A transaction that *only* clears one slot spends 2,900 and gets a refund capped at 580 — a fact invisible to `gasleft()` and the source of endless measurement confusion. Two edge cases: writing zero again to a slot already cleared this tx is a 100-gas no-op that adds no refund (the 4,800 was granted at the first clear), while re-creating it (writing nonzero after a clear) charges 2,900 and claws the 4,800 back. EIP-3529 also removed the SELFDESTRUCT refund (24,000) entirely; EIP-6780 (Cancun) then restricted full deletion to contracts created in the *same transaction* — otherwise the opcode only transfers the balance, leaving code, storage, and account intact (locked in Ch 5).

### Access lists (EIP-2930)

An **access list** is a type-0x01 transaction field: a list of `(address, [storageKeys])` that the EVM pre-loads into the warm sets at transaction start. Cost: **2,400 per address, 1,900 per storage key**. What does it buy? Every listed key's first touch is warm instead of cold:

- Read a listed slot once: saves 2,000 (2,100 − 100), pays 1,900 → **+100 gas net**.
- Write a listed slot once: saves 2,100 (the cold surcharge on the `SSTORE`), pays 1,900 → **+200 gas net**.
- Call a listed address once: saves 2,500 (2,600 − 100), pays 2,400 → **+100 gas net**.
- Touching a listed key repeatedly does *not* compound the saving: later touches are warm (100) with or without the list, so the list's entire benefit lands on the first touch — collected once per listed key.

The honest engineering take: for a single-touch path an access list is nearly break-even. It wins in three real situations: (1) **hot paths that touch many distinct accounts and slots in one transaction** (batch operations, multicall-style flows) — the per-key saving is small but multiplies across every distinct touch; (2) **writes** — a borrow that writes the user's debt slot saves 200 gas net and, more importantly, makes the write's cost *deterministic*; (3) **gas estimation and meta-transactions** — a listed transaction has no cold/warm variance for the listed addresses and slots, so that component of its gas bill is a stable number (branching, calldata, and memory still vary), which matters enormously for ERC-4337 bundlers (Ch 33) and for wallets that must predict fees. Clients expose `eth_createAccessList` (Geth, Nethermind, Erigon) to build lists automatically from a simulated trace; production protocols ship curated lists for their canonical paths.

### The fee market: EIP-1559

Since London (August 2021), transaction pricing is two-part. The **base fee** is set by the protocol from the previous block's fullness and is **burned**; the **priority fee** (tip) is whatever the sender offers above it and goes to the proposer. A type-0x02 transaction declares `max_fee_per_gas` and `max_priority_fee_per_gas`; the effective tip is `min(max_priority_fee_per_gas, max_fee_per_gas − base_fee)`, and inclusion requires `max_fee_per_gas ≥ base_fee + effective tip`. The base fee updates per block:

```
base_fee_{n+1} = base_fee_n + base_fee_n × (gas_used_n − target) / target / 8
```

with `target = block_limit / elasticity = 30,000,000 / 2 = 15,000,000`. A full block pushes the base fee up by the maximum step, ~12.5% (1/8); an empty block drops it by the same maximum; half-full keeps it flat. The protocol computes in integer arithmetic, so the real step is `floor(base_fee/8)` — 12.5% is the ideal, not a floating-point rule. The mechanism makes fees *predictable* (wallets estimate from `eth_feeHistory`, which returns the `baseFeePerGas` series, `gasUsedRatio`, and reward percentiles), makes spikes self-limiting, and burns ETH — by mid-2024 the cumulative burn had passed ~4.3M ETH (ultrasound.money). The tip is the only honest proposer revenue absent MEV — a thread Ch 34 pulls hard.

### Refunds: the abused meter

The refund mechanism exists to reward state *cleanup* (net gas metering, EIP-2200 lineage), and it was immediately weaponized. **Gas tokens** — GasToken.io (2017), then 1inch's CHI (2020) — minted "gas" by writing storage when gas was cheap (SSTORE set, 20,000) and burned it when gas was expensive (clear: 5,000 cost − 15,000 pre-London refund), arbitraging the *price* of gas across time. EIP-3529 killed the business by cutting the clear refund to 4,800 and the cap to `gas_used/5` — a set+clear round trip spends 22,900 gas, earns 19,900 refund in principle (the restore-to-original refund, `SSTORE_SET_GAS − SLOAD_GAS`), but the cap allows only 22,900/5 = 4,580, so the net bill is 18,320 and the margin collapses. Protocol constants first: clear refund 4,800, restore refund 2,800 (19,900 when restoring to zero), maximum total refund `gas_used/5`. The lesson is a locked Meridian convention: **logic never depends on refunds**; the refund is a bonus, the cap is a security parameter, and a contract that *needs* its refund to be solvent is a contract that breaks the day the schedule changes.

### Beyond execution: blob gas and the calldata floor

Since Dencun (March 2024), the block has a **second fee market**: blob gas. Blob-carrying transactions (type 0x03, EIP-4844) pay a blob base fee in its own market — minimum 1 wei per blob-gas unit, 131,072 blob-gas per blob, update fraction 3,338,477 — with the target at 3 blobs and max 6 at launch. **EIP-7691 (Prague, March 2025)** raised the target to 6 and max to 9; post-Fusaka, **PeerDAS (EIP-7594)** and blob-parameter-only (BPO) scaling raise them further (Ch 30's territory). The point here: blobs are the *sanctioned cheap data channel*, and calldata is no longer allowed to imitate them. **EIP-7623 (Prague)** floors the gas of calldata-heavy transactions: it defines `tokens = zeroBytes + 4 × nonzeroBytes` and charges `max(standard intrinsic + execution cost, 21,000 + 10 × tokens)`. The floor therefore prices zero bytes at 10 gas and non-zero bytes at 40 gas — *not* a flat 10 per byte — and it binds whenever the standard cost falls below the floor, e.g. when zero bytes dominate. A 100 KB all-zero payload went from ~430,600 gas to ~1,045,000. Two smaller metering internals worth knowing: **EIP-3860 (Shanghai)** prices initcode at 2 gas per 32-byte word with a 49,152-byte cap (closing the cheap-huge-`CREATE` gap), and **EIP-1153 (Cancun)** gives us `TLOAD`/`TSTORE` at 100 gas each, cleared per transaction, no refunds — the transient-storage primitive Ch 24 uses for reentrancy guards.

**Fork-aware gas (post-Fusaka mainnet, December 2025):** the block gas limit is ~60M, and a separate **per-transaction gas cap of 2²⁴ = 16,777,216** (EIP-7825, Fusaka) bounds what a single transaction can consume — directly relevant to the gas-bomb discussion below. EIP-7702 type-0x04 set-code transactions are live since Pectra, and EIP-7623's calldata floor is active. Glamsterdam (H2-2026) is roadmap, not mainnet. Gas schedules are fork-dependent: every number in this chapter is pinned to the post-Fusaka schedule, and measurements should always be re-pinned to the fork they run on.

## Mathematical Foundations

### The base-fee rule, dissected

Take `base_fee = 40 gwei` and a block exactly full (30,000,000 gas used): `40 + 40 × (30M − 15M)/15M/8 = 40 + 40/8 = 45 gwei` — the maximum ~12.5% step (40 divides by 8 exactly, so the integer arithmetic lands precisely here). An empty block: `40 − 40/8 = 35 gwei`. Half-full: flat. The denominator 8 *is* the 12.5% cap, and the elasticity multiplier 2 is why the target sits at half the limit: the market has a full block of headroom above target before fees max out, which keeps inclusion possible even when demand doubles. For the sender the arithmetic is: `fee = (base_fee + effective_tip) × gas_used`, where `gas_used` is post-refund. A wallet estimating from `eth_feeHistory` applies a conservative heuristic: take the current base fee, project it upward by ~12.5% per full block of wait (the protocol's maximum adjustment, integer-rounded), add the priority-fee percentile it wants to compete at, and cap at `max_fee_per_gas` — which is why "base fee + 2× priority, capped at max_fee" is the standard recipe.

### Access-list break-even, in numbers

A Meridian-style borrow touches, cold: the vault address, the token address, the oracle address, ~6–10 storage slots (user collateral, user debt, market state, oracle last answer, interest-model parameters), and 2–4 `SSTORE`s. Without a list: ~3 × 2,600 (cold accounts) + ~10 × 2,100 (cold slots) + ~3 × 2,900 (`SSTORE` base costs) ≈ 7,800 + 21,000 + 8,700 ≈ **37,500 gas**. With a curated list (3 addresses, 10 keys, 3 of them written), the list costs `3 × 2,400 + 10 × 1,900 = 26,200`, the cold surcharges disappear, and the same `SSTORE` base costs still apply: 26,200 + 3 × 100 (warm accounts) + 7 × 100 (warm reads) + 3 × 2,900 (unchanged `SSTORE` base) ≈ **35,900 gas**. The list therefore saves 37,500 − 35,900 = **1,600 gas** — per touch: 3 accounts at (2,500 − 2,400) = +100 each, 7 read keys at (2,000 − 1,900) = +100 each, 3 written keys at (2,100 − 1,900) = +200 each. An access list removes cold *surcharges*; it never removes the underlying `SSTORE` cost. The win is real but modest in raw gas — the decisive benefit is the stable estimate. The break-even rule of thumb: list every address you will call and every slot you will touch — each nets its saving exactly once (+100 read, +200 write, no matter how often it is touched); the single-touch read is nearly a wash, the write is +200, and predictability is priceless.

### Memory expansion and the quadratic term

Memory's *cumulative* cost is `C_mem(w) = 3w + floor(w²/512)` where `w` is the number of 32-byte words, charged on the *highest word reached*: 1 word = 3 gas, 32 words = 96 + 1,024/512 = 98, 128 words = 384 + 16,384/512 = **416** — those are *totals*, not per-expansion charges. An expansion from `w_old` to `w_new` words costs the *difference* `C_mem(w_new) − C_mem(w_old)`: expanding from 32 to 128 words charges 416 − 98 = **318 gas**, not 416. The quadratic term is the DoS guard: memory is cheap to grow but superlinear, so a contract can't force a caller to expand gigabytes for a few gas. The corollary for Meridian: batch operations should stream through small buffers rather than allocate one big one — the quadratic term punishes exactly that pattern.

### The refund cap, where it bites

Set then clear a slot in one transaction: 20,000 + 2,900 = 22,900 used, 19,900 refunded in principle (restoring the slot to its original zero — `SSTORE_SET_GAS − SLOAD_GAS`) — but the cap allows only 22,900/5 = **4,580**, so the net bill is 18,320. Clear the same slot in a small transaction of its own: 2,900 used, cap allows 580, net 2,320 — the "4,800 refund" never materializes. Anyone quoting refunds without checking the cap is quoting a fantasy; the cap binds almost always, because refunds are sized (4,800) to matter only inside transactions that spend multiples of them.

## Engineering Perspective

### Reading a gas report like a budget

A `forge test --gas-report` (or a block explorer's trace) is an income statement: cold `SLOAD`s are the rent, `SSTORE`s the payroll, `CALL`s the taxes. The audit move is to sort by *cold touches* — each one is 2,100/2,600 of pure overhead that packing (Ch 6), caching, or an access list can eliminate. Meridian's standing rule, reaffirmed from Ch 1: **every loop on a critical path has a predictable upper bound that fits the transaction's gas budget** (max-batch, pagination, cursor, fixed iteration limits) — a loop whose bound is attacker-controlled is a gas bomb waiting for a hostile input, and a `gasleft()` cliff for the caller.

### Access lists as a production tool for Meridian

The borrow/repay path is the protocol's hot path, and it is a *fixed, known* set of touches: the vault, the ERC20, the oracle, the user's collateral and debt slots, the market's utilization state. That is exactly the shape of a curated access list. The Ch 20 vault work will ship `docs/gas-budget.md` with the canonical borrow-path list and a CI check that the deployed list covers every cold touch in a trace. Until the vault exists, this chapter locks the *discipline*: know your cold touches by heart, list the repeats, write the writes.

### The refund mindset

Design as if EIP-3529's cap were the whole story (it is): zeroing slots is a *2,900-gas operation with a capped bonus*, never a profit center. Do not restructure logic to "earn refunds" — every refund is capped, every schedule can change, and Ch 26 will show an auditor treating refund-shaped logic as a red flag.

### Measurement discipline

Reaffirmed from Ch 1–2: `gasleft()`-based measurements must use loop-amplified min-delta and **never** `--gas-report` mode (which distorts `gasleft()`); refunds are credited at transaction end and are **invisible to `gasleft()`** — measure refund behavior via whole-transaction gas or not at all. Absolute numbers shift with compiler versions; deltas are stable; pin deltas, not absolutes.

## Code Walkthrough

Meridian's lab is `GasProbe.sol` — pedagogical, NOT protocol, per the standing convention. It exposes the four phenomena this chapter is about: cold vs warm reads, the SSTORE state machine, memory expansion, and warm reuse:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GasProbe
/// @notice Lab contract for gas mechanics: cold/warm access, the SSTORE
///         state machine, memory expansion. Pedagogical only — NOT protocol.
contract GasProbe {
    mapping(uint256 => uint256) public slots;
    uint256 public probe; // hot scalar slot for SSTORE state-machine probes

    /// @notice Write a mapping slot. First touch in a tx = cold (22,100 or 5,000).
    function setSlot(uint256 k, uint256 v) external { slots[k] = v; }

    /// @notice Read a mapping slot. First touch in a tx = cold (2,100), then warm (100).
    function getSlot(uint256 k) external view returns (uint256) { return slots[k]; }

    /// @notice SSTORE set: 0 -> nonzero. Warm cost 20,000.
    function sstoreSet() external { probe = 1; }

    /// @notice SSTORE reset: nonzero -> nonzero. Warm cost 2,900.
    function sstoreReset() external { probe = 2; }

    /// @notice SSTORE clear: nonzero -> 0. Warm cost 2,900; refund 4,800 capped at gas_used/5.
    function sstoreClear() external { probe = 0; }

    /// @notice Dirty restore: set, then restore original in one tx (refund 2,800, capped).
    function sstoreDirtyRestore() external { probe = 2; probe = 1; }

    /// @notice Clear then re-set in one tx — the 4,800 clear refund is granted, then clawed back (net zero).
    function sstoreClearThenSet() external { probe = 0; probe = 1; }

    /// @notice Touch the same slot twice — second read is warm (100 vs 2,100).
    function touchTwice(uint256 k) external view returns (uint256 a, uint256 b) {
        a = slots[k];
        b = slots[k];
    }

    /// @notice Force memory expansion to `words` 32-byte words and touch the last one.
    function growMemory(uint256 words) external pure returns (uint256 acc) {
        if (words == 0) return 0;

        bytes memory buf = new bytes(words * 32);

        assembly ("memory-safe") {
            acc := mload(add(buf, add(0x20, mul(sub(words, 1), 0x20))))
        }
    }
}
```

The test pins *deltas*, not absolutes, and exploits Foundry's model where each test function is one transaction — so a second call inside the same test observes warm pricing:

```solidity
function testColdVsWarmRead() public {
    probe.setSlot(1, 42);              // warms slot 1 AND the probe address this tx
    uint256 g0 = gasleft();
    probe.getSlot(1);                  // warm: ~100 + call overhead
    uint256 warm = g0 - gasleft();
    uint256 g1 = gasleft();
    probe.getSlot(2);                  // cold: ~2,100 + overhead
    uint256 cold = g1 - gasleft();
    assertGt(cold, warm + 1500);       // the 2,000 delta dominates overhead
}

function testClearRefundIsInvisibleToGasleft() public {
    // gasleft() sees only the 2,900 charge; the 4,800 refund lands at tx end.
    probe.sstoreClear();
}
```

Three details to notice. First, `setSlot(1, 42)` before measuring warms the *address* and slot 1 — the cold read must use a never-touched slot. Second, the clear-refund test documents the trap rather than fighting it: `gasleft()` cannot see refunds, so the refund assertion belongs in a whole-transaction gas comparison (e.g., against a `--gas-report` run on a forge host, or a `test.toml` snapshot, Ch 13). Third, `growMemory` forces the quadratic term through an allocated buffer so the compiler cannot elide it.

## Production Example

**The Meridian borrow path, provisionally** (the vault lands in Ch 20; this is the gas anatomy it must meet). A borrow of `amount` against collateral touches, cold: the vault (`CALL` 2,600), the oracle (`CALL` 2,600 + ~3 `SLOAD`s for `latestRoundData` ≈ 6,300), the underlying ERC20 (`CALL` 2,600 + 2 `SLOAD`s + 2 `SSTORE`s for balances ≈ 2,100 + 20,000×2...), and ~6 vault slots (collateral, debt, market utilization, interest state, oracle feed id, last-update timestamp) ≈ 12,600 in reads plus ~3 `SSTORE`s (debt += amount is a warm reset if the user already owes: 2,900; the utilization bump and timestamp are warm updates: 2,900 each). The cold-access subtotal alone lands in the ~30–40k range — before any arithmetic — and the whole transaction lands on the order of ~200k gas, dominated by the ERC20's two `SSTORE`s and the oracle's `SLOAD`s.

The Ch 20 work item, locked now: the borrow path gets a **curated access list** — vault, oracle, token addresses; user collateral + debt slots; market state; oracle last-answer slot — and `docs/gas-budget.md` will publish the before/after trace. The expected win in raw gas is modest — a few thousand at most across the path's ~19 distinct cold touches, per the per-key arithmetic above — plus, more importantly, a *deterministic* gas number: the same borrow costs the same whether the user has traded recently or not. Determinism is the feature; the saved gas is the bonus.

## Security Analysis

### Gas prices are security parameters (2016)

The Shanghai DoS attacks are the canonical proof that opcode pricing is *security*, not accounting: `EXTCODESIZE` at 20 gas let one attacker stall the whole network for two weeks, and the fix (EIP-150) was an emergency hard fork that repriced the opcodes and added the 63/64 rule. Every cost table in this chapter is a security parameter with an incident behind it: EIP-1884 (Istanbul) repriced `SLOAD` again after it proved too cheap; EIP-2929 formalized the model; EIP-7623 closed the calldata-vs-blob arbitrage. When you review a contract, ask *"what does this cost the caller, and what would an attacker do with a million of them?"* — that is the 2016 question.

### Refund farming (EIP-3529)

The gas-token era (GasToken.io, CHI) showed that any refund is a subsidy that can be arbitraged across gas price *and* time. EIP-3529's cap (`gas_used/5`) is the standing answer: refunds may never exceed 20% of the bill, so no refund-shaped strategy can dominate the base economics. Meridian's locked convention — no logic depends on refunds — is the contract-level version of the same defense.

### The 63/64 griefing class

EIP-150's rule cuts both ways: it caps what a callee can burn, but it also means forwarding `gasleft()` exactly gives the callee only 63/64 — and a callee that needs the full amount reverts, griefing the caller's whole transaction. The defenses are boring and locked: never forward exact gas, leave headroom, use `try/catch` around untrusted calls, and keep loops bounded so a hostile input can't inflate callee gas demand. The same bounded-loops rule neutralizes the classic **gas-bomb**: a contract iterating an attacker-controlled array until the block gas limit.

### The calldata dump (EIP-7623)

Before Prague, storing data in calldata was a way to bypass blob infrastructure at 4–16 gas/byte; EIP-7623's floor (`tokens = zeroBytes + 4·nonzeroBytes`, bill `max(standard cost, 21,000 + 10 × tokens)` — zero bytes 10 gas, non-zero 40) closes the arbitrage and pushes data to blobs — where PeerDAS and BPO scaling (Ch 30) make the economics sane. For Meridian's integrators the lesson is operational: calldata-heavy transactions (bulk claims, merkle-proof dumps) got ~2.4× more expensive for zero-heavy payloads in 2025, and fee estimation must use the post-floor schedule.

## Exercises

1. Compute the net gas of `sstoreSet()` followed by `sstoreClear()` in one warm transaction, applying the EIP-3529 cap. Then recompute clearing a slot in a transaction that spends 100,000 gas — where does the 4,800 refund actually land?
2. A transaction calls three contracts, reads eight cold slots (two of them twice), and writes two slots. Build the EIP-2930 access list and compute the net saving versus no list.
3. Base fee is 40 gwei. Block 1 is 100% full, block 2 is 0% full. Derive the base fee after each block.
4. `gasleft()` is 100,000 and you `call` with `gas: gasleft()`. How much gas does the callee receive under EIP-150?
5. A calldata-heavy transaction carries 80,000 bytes, 90% zero. Compute its intrinsic gas before and after EIP-7623.

## Weekly Project

**Meridian's gas discipline — the budget the vault will be measured against.** Three deliverables:

1. `meridian/src/GasProbe.sol` + `meridian/test/GasProbeTest.t.sol` — the lab above: cold-vs-warm deltas, the SSTORE state machine, the refund-invisibility trap, memory expansion. Lab green on forge 1.7.1; numbers pin the published EIP-2929/EIP-3529 schedule.
2. `docs/gas-budget.md` — the provisional borrow-path anatomy (the Production Example table, expanded), the curated access-list strategy, the `eth_createAccessList` workflow, and the EIP-1559 fee-estimation recipe (`eth_feeHistory` + 12.5% headroom).
3. A **gas conventions checklist** appended to `docs/gas-budget.md`: no refund-dependent logic; bounded loops; cold touches known per hot path; access lists for deterministic gas; deltas-not-absolutes measurement.

This gives Ch 20's `MeridianVault` a pre-written budget to meet and Ch 13's `forge snapshot` CI gate a baseline to enforce.

## Deliverables

1. `meridian/src/GasProbe.sol` + `meridian/test/GasProbeTest.t.sol` — the gas lab (deltas only; refunds measured at tx level).
2. `docs/gas-budget.md` — borrow-path gas anatomy, access-list strategy, fee estimation recipe, gas conventions checklist.
3. Locked conventions: refund-independence, bounded loops, cold-touch discipline, access-list determinism.
4. Gas table (published schedule, lab-pinned via `GasProbeTest`): the SSTORE state machine, cold/warm ladder, EIP-1559 formula, EIP-7623 floor, blob-gas constants.

## Quiz

1. Why did the 2016 Shanghai DoS attacks happen, and which two mechanisms in EIP-150 answered them?
2. Give the warm and cold costs for: set, reset, clear, no-op `SSTORE`. What caps the 4,800 clear refund?
3. When is an EIP-2930 access list a net win, and when is it a wash?
4. Derive the EIP-1559 base fee after a full block, starting from 40 gwei. What is the maximum per-block change, and why is it exactly 1/8?
5. Why can `gasleft()` never observe a refund, and what does that imply for gas measurement methodology?

**Answers:** (1) State-reading opcodes (`EXTCODESIZE`, `SLOAD`) were priced for register access, so an attacker could force miners to do minutes of disk-heavy work per block; EIP-150 raised the costs and added the 63/64 rule so no callee can spend more than 63/64 of a caller's gas. (2) Set 20,000 warm / 22,100 cold; reset 2,900 / 5,000; clear 2,900 / 5,000 with a 4,800 refund; no-op 100 / 2,200. The refund is capped at `gas_used/5` (EIP-3529), so it fully lands only when the transaction spends ≥ 24,000 gas. (3) Net win per listed slot: +100 on a read, +200 on a write (single touch — later touches are warm with or without the list, so there is no repeat-touch bonus); determinism is the decisive property. (4) 45 gwei; the change is `base × (gas_used − target)/target/8`, maxing at 1/8 = 12.5% per block, because the denominator 8 is the cap. (5) Refunds are credited after execution, at transaction end, against the gas used; `gasleft()` only sees the upfront charges. Measure refund behavior with whole-transaction gas or `--gas-report`/snapshot comparisons, never `gasleft()` deltas — and never `--gas-report` for `gasleft()`-based assertions at all.

## Further Reading

- EIP-150, EIP-158/161, EIP-1884, EIP-2929, EIP-2930, EIP-1559, EIP-3529, EIP-3651, EIP-3860, EIP-4844, EIP-7623, EIP-7691 — the full metering/fee lineage.
- Ethereum Yellow Paper §9 (gas costs) — the authoritative cost functions; EIP-2200 for the SSTORE state machine and refund rules.
- EIP-1153 (transient storage) — the 100-gas per-tx primitive Ch 24 builds on.
- 2016 post-mortems: "The Ethereum DoS attacks" (Parity/Geth blog posts, Sep–Oct 2016); GasToken.io and 1inch CHI writeups for the pre-EIP-3529 refund era.
- `eth_feeHistory` and `eth_createAccessList` RPC docs (Geth/Nethermind/Erigon).
- ultrasound.money — cumulative EIP-1559 burn tracking.

## Ledger Update

**Ch 7 — Gas Mechanics (2026-08-12)** — full entry appended to `ledger/CONTINUITY_LEDGER.md`.

- Locked gas conventions (canon): **no refund-dependent logic** (EIP-3529 cap `gas_used/5` — refunds credited at tx end, invisible to `gasleft()`); bounded loops reaffirmed from Ch 1; **cold-touch discipline** — know every cold `SLOAD`/`SSTORE`/`CALL` per hot path; **access lists for deterministic gas** on the borrow/repay path (curated list: vault, oracle, token addresses + user collateral/debt + market state + oracle last-answer slots), the list design deferred to Ch 20's vault with the strategy doc now; measurement = loop-amplified min-delta deltas only, never `--gas-report` for `gasleft()`-based tests (Ch 2 methodology reaffirmed).
- Numbers locked (published schedule; lab-pinned via `GasProbeTest`): cold `SLOAD` 2,100 vs warm 100; cold account 2,600 vs 100; SSTORE set 20,000/22,100, reset 2,900/5,000, clear 2,900/5,000 + 4,800 refund capped at `gas_used/5`, restore refund `SSTORE_RESET_GAS − SLOAD_GAS` = 2,800, no-op 100/2,200; access list 2,400/address + 1,900/key (net +100 read, +200 write — single touch, no repeat-touch bonus); EIP-1559 base-fee update `base × (gas_used − target)/target/8` (±12.5%/block, target 50%); EIP-7623 calldata floor `tokens = zeroBytes + 4·nonzeroBytes`, bill `max(standard, 21,000 + 10 × tokens)` (zero byte 10, nonzero 40); blob gas 131,072/blob, EIP-7691 target 6/max 9 (Prague); EIP-3860 initcode 2 gas/word, 49,152 cap; EIP-1153 `TLOAD`/`TSTORE` 100.
- Glossary additions: base fee, priority fee (tip), effective gas price, access list (EIP-2930), refund cap (`gas_used/5`), blob gas, calldata-heavy floor (EIP-7623), gas token.
- Grounding incidents: **Shanghai DoS attacks (Sep–Oct 2016)** → EIP-150 (cost raises + 63/64); **state-bloat DoS (Aug 2016)** → EIP-158/161 (~19M empty accounts cleared, 25,000 new-account charge); **gas tokens (GasToken.io 2017, CHI 2020)** killed by EIP-3529 (London 2021).
- Repo: `meridian/src/GasProbe.sol` + `meridian/test/GasProbeTest.t.sol` (lab, NOT protocol) — materialized and green (forge 1.7.1).
- **ERRATA APPLIED (2026-08-14, review `errata/07_Gas_Mechanics_REVIEW.md`):** EIP-2930 worked example now includes unchanged `SSTORE` base costs (net saving 1,600 gas; per-touch +100 read/+200 write, no repeat-touch bonus); EIP-7623 corrected to `tokens = zeroBytes + 4·nonzeroBytes` with bill `max(standard, 21,000 + 10 × tokens)` (zero 10 / nonzero 40); memory expansion reframed as cumulative `C_mem(w) = 3w + floor(w²/512)` with delta-costed expansion; `growMemory()` fixed (touches last allocated word, `sub(words,1)`); added post-Fusaka per-tx cap 2²⁴ = 16,777,216 (EIP-7825) and fork-pinned schedule box; bounded-loops rule refined to predictable-upper-bound framing.
- **ERRATA APPLIED (2026-08-15, review `errata/07_Gas_Mechanics_REVIEW.md`):** access-list savings stated per-key, collected once (no repeat-touch bonus); EIP-1559 step relabeled ~12.5% maximum with integer rounding, wallet 12.5% projection labeled a heuristic; GasToken set+clear refund corrected (19,900 in principle, cap 4,580, net 18,320); SSTORE re-create row corrected (claws back 4,800) and re-clear no-op noted; SELFDESTRUCT/EIP-6780 deletion scope clarified.
- Drift: none. Module boundary: none (M2 ends Ch 9 — next boundary audit at Ch 9).
