# The EVM Execution Model

Every gas estimate you will ever write, every invariant you will ever prove, and every vulnerability you will ever fix reduces to a handful of machine-level rules. This chapter derives those rules from first principles — so the numbers are never memorised, they are *understood*.

### Contents

1. [Learning Objectives](#learning-objectives)
2. [Theory — Architecture & Design Decisions](#theory--architecture--design-decisions)
3. [Data Locations — Stack, Memory, Storage](#data-locations--stack-memory-storage)
4. [Execution Lifecycle & Call Frames](#execution-lifecycle--call-frames)
5. [Revert Semantics](#revert-semantics--the-most-important-rule)
6. [Gas Accounting — The Equations](#gas-accounting--the-equations)
7. [Code Walkthrough — EVM in Miniature](#code-walkthrough--evm-in-miniature)
8. [Production Reference — UniswapV2Pair](#production-reference--uniswapv2pairupdate)
9. [Security Analysis — Vulnerability Classes](#security-analysis--vulnerability-classes-from-evm-semantics)
10. [Gas Optimization Patterns](#gas-optimization-patterns)
11. [Common Mistakes](#common-mistakes)
12. Exercises & Lab
13. [Quiz](#quiz)
14. [Further Reading](#further-reading)

## Learning Objectives

By the end of this chapter you will be able to:

- **Obj 01** —  Explain the EVM's architecture — 256-bit words, stack-based, register-less, gas-bounded — and derive *why* each design choice was made.
- **Obj 02** —  Trace a transaction's complete lifecycle: calldata → call frame → stack/memory/storage → revert-or-commit, identifying every gas charge along the way.
- **Obj 03** —  Derive why Solidity emits the bytecode it does from EVM semantics: stack depth, memory expansion, storage slot layout.
- **Obj 04** —  Distinguish the three data locations (stack, memory, storage) and state the exact gas cost model and persistence guarantees of each.
- **Obj 05** —  Explain revert semantics: partial-state rollback, gas-retention rules, and the distinction between `require`-style reverts and out-of-gas exceptions.
- **Obj 06** —  Connect EVM primitives to Meridian Finance: why a lending market's accounting must be designed with the EVM's cost model and revert semantics in mind.

## Theory — Architecture & Design Decisions

The Ethereum Virtual Machine is a **256-bit, stack-based, register-less** virtual machine, bounded by gas rather than a halting-problem oracle. Each adjective encodes a deliberate trade-off. A protocol engineer who cannot derive those trade-offs will misprice contracts for years.

### Why 256-bit words?

Two reasons compound each other. First, Keccak-256 — Ethereum's universal hash — produces 256-bit outputs. Addresses are the low 160 bits of a Keccak hash; storage keys are full 256-bit hashes. If the machine used 64-bit words, every hash operation would require multi-word gymnastics. The EVM chose to make the hash output the machine's native word, eliminating that overhead entirely.

Second, ether is denominated in wei (1 ether = 10^18 wei). A 256-bit unsigned integer holds values up to ~1.15 × 10^77, which accommodates any realistic wei balance with orders of magnitude to spare. The consequence for gas reasoning: **the unit of computation is the 256-bit word, not the byte.** Every arithmetic opcode, every stack slot, every storage key occupies one full word.

### Why stack-based and register-less?

A stack machine has no register-allocation problem. The compiler emits push/pop/op sequences; the interpreter tracks a stack of up to 1,024 slots; the semantics are trivially specified and trivially verified. For a consensus-critical VM that must be independently reimplemented in many languages (Go, Rust, Java, C++…), a *minimal, unambiguous specification* is a security property in itself. Every divergence between client implementations is a potential consensus split.

The cost: stack machines produce more instructions than register machines. Solidity must use `DUP` and `SWAP` opcodes extensively to reposition values, and its optimizer spends real effort on stack-to-memory and stack-to-storage scheduling. This is an intentional trade-off: implementer simplicity over compiler efficiency.

### Why a 1,024 stack depth limit?

Without a cap, a transaction could push unboundedly, forcing block producers to allocate unbounded memory — a denial-of-service vector. The cap converts the attack into a bounded resource. In practice, Solidity's optimizer keeps live stack usage in the dozens. The risk materialises with deep recursion: an attacker who can force recursive calls can trigger a **stack-overflow exception** — a named vulnerability class we revisit in the Security Analysis section.

### Why does gas exist at all?

> **The most elegant idea in Ethereum** —  
>  Gas is *not* primarily a fee mechanism. It is a **liveness mechanism**. The EVM is Turing-complete, so the halting problem applies: there is no general algorithm that can determine in advance whether a program terminates. Rather than solving an unsolvable problem, Ethereum charges for each computational step. A transaction carries a gas limit; execution halts when the limit is exhausted. The halting problem is converted into an accounting problem.

### The execution environment

Every call frame exposes a well-defined set of environment variables:

| Variable | Value | Security note |
| --- | --- | --- |
| `tx.origin` | The EOA that signed the top-level transaction | Never use for authorization — see §Security |
| `msg.sender` | The immediate caller (EOA or contract) | Correct authorization variable |
| `msg.value` | Wei sent with this call | Zero for non-payable calls |
| `msg.data` | Calldata: ABI-encoded selector + arguments | Untrusted — validate before use |
| `address(this)` | The executing contract's address |  |
| `block.*` | Number, timestamp, basefee, blobbasefee | Timestamp can be manipulated ±12 s |
| `gasleft()` | Remaining gas at this point in execution | Decreases with each opcode |

> **tx.origin vs msg.sender — the most common authorization mistake** —  
>  `tx.origin` is the original EOA that initiated the transaction chain. `msg.sender` is whoever called *this specific frame*. Any contract that authorizes based on `tx.origin` is vulnerable to phishing via an intermediary contract — the attacker tricks the user into calling a malicious contract which then calls the victim on their behalf, while `tx.origin` still passes. 
 
> **Meridian convention, locked from Day 1: authorize with `msg.sender`, never `tx.origin`.**

## Data Locations — Stack, Memory, Storage

| Location | Scope | Gas cost | Contents |
| --- | --- | --- | --- |
| **Stack** | Per call frame | ~3 gas/op | Live operands for arithmetic and logic opcodes |
| **Memory** | Per call frame — erased on return | 3 gas/word + quadratic expansion | ABI encoding scratch space, return data, temporary arrays |
| **Storage** | Persists across all transactions forever | SSTORE: 20,000 / 2,900 / 100 gas | Contract state variables |

### Storage: the most expensive operation in the EVM

The storage cost model deserves careful study because it drives nearly every Solidity best practice:

| Operation | Cost (gas) | EIP basis | Explanation |
| --- | --- | --- | --- |
| Cold slot read (`SLOAD`) | 2,100 | EIP-2929 | First access to this slot in the transaction |
| Warm slot read (`SLOAD`) | 100 | EIP-2929 | Slot already in access list this tx |
| Fresh non-zero write (`SSTORE`) | 20,000 + 2,100 | EIP-2200, EIP-2929 | Cold access + set new non-zero value |
| Clear slot (write 0) | 2,900 + 2,100 | EIP-2200 | Cold access + clear; grants refund (capped at gas_used/5) |
| Rewrite same value | 100 | EIP-2929 | Warm slot, no change to world state |

> **Design rule: Storage writes are a scarce resource** —  
>  A fresh `SSTORE` costs ~22,100 gas. Every Solidity best practice — packing variables into single slots, using `immutable` for deploy-time constants, caching storage reads in memory variables, batching state changes into one slot write — is a direct response to this number. Design your state layout the way a database engineer designs index layouts.

### Memory: ephemeral and quadratic

Memory is per-frame scratch space. The first 64 bytes cost nothing extra. Beyond that, the expansion cost follows a quadratic curve, intentionally designed to make unbounded memory growth prohibitively expensive at scale:

$$ C_mem(w) = 3·w + w² / 512 \quad where w = words allocated so far $$

This is applied *incrementally* on each growth event. The quadratic term is small at low word counts but grows steeply — a loop that writes 1,024 words of fresh memory will cost approximately 5,120 gas in expansion alone, before any computation. Unbounded loops over memory are a gas-griefing vector.

### Stack: free but depth-capped

Stack operations (`PUSH`, `POP`, `DUP`, `SWAP`) are nearly free (~3 gas each) but the stack is hard-capped at 1,024 slots. Exceeding this limit causes an immediate `STACK_OVERFLOW` exception. For a lending protocol this means: no user-supplied input may control recursion depth — a user who can force deep recursion can trigger overflow and effectively brick a function.

## Execution Lifecycle & Call Frames

Carries: `to`, `value`, `data`, `gasLimit`, `nonce`, signature.

Non-zero calldata bytes cost 16 gas each; zero bytes cost 4 gas. If `gasLimit` is insufficient even for intrinsic gas, the transaction is rejected before execution begins.

Fresh stack (0 items), fresh memory (empty), gas budget = `gasLimit − intrinsic`. Execution begins at the contract's first bytecode byte.

Each opcode deducts its gas cost from the running total. If gas reaches zero: **out-of-gas exception** — the entire transaction reverts and all gas is consumed. If execution reaches `STOP` or `RETURN`: frame exits normally.

Creates a fresh child frame with its own stack and memory. The callee receives at most **63/64 of the caller's remaining gas** (EIP-150 — the "63/64 rule"). The callee's memory is discarded on return; only storage persists.

On normal exit: storage changes persist, remaining gas is refunded to the sender. On `REVERT`: storage changes in this frame (and all nested frames) are rolled back atomically; remaining gas up to the revert point is returned.

> **The 63/64 gas rule (EIP-150)** —  
>  A callee can only receive 63/64 of the caller's remaining gas. This means a malicious callee can deliberately burn its entire allotment — forcing the caller's post-call logic to run with a budget that is 1/64 smaller than expected. Known as a **griefing attack**: the attacker spends little, but the caller's function may fail with an out-of-gas error.

### Call frame isolation

Call frame isolation is the property that makes DeFi composability safe. Each frame has its own stack and memory. A contract can call an untrusted external contract; the worst outcomes are:

- The callee reverts (the call fails, your code handles the return value).
- The callee writes to its own storage (you observe this via return values or events).

What cannot happen: the callee corrupts the caller's memory or stack. There is no shared-memory attack surface between frames — only storage, and only the storage of whichever contract is currently executing.

> **DELEGATECALL is the important exception** —  
>  `DELEGATECALL` executes the callee's code in the *caller's* storage context. The callee reads and writes the caller's storage slots. This is the mechanism behind proxy patterns — and the source of most proxy-related storage-collision exploits. Treat `DELEGATECALL` targets as fully trusted code with root access to your state.

## Revert Semantics — The Most Important Rule

When execution hits `REVERT` (from `require`, `revert()`, or an uncaught arithmetic exception), the EVM performs four actions simultaneously:

All storage and balance changes made in this call frame *and every nested frame below it* are undone. The world state is restored to exactly what it was before this call began.

Gas consumed up to the revert point is charged. Gas remaining at the revert point is **returned to the caller**. A `revert` does not burn the full gas limit — only an out-of-gas exception does.

The error string or custom error ABI payload is placed in the return buffer. The caller can decode it with `try/catch`.

If the caller does not catch the revert, the caller's frame also reverts. This propagates all the way to the top: if the top-level frame reverts, the entire transaction reverts atomically. Nothing is committed — not the storage, not the ether transfers.

> **Revert as control flow — why Meridian uses it this way** —  
>  Because a revert atomically undoes everything, production DeFi code uses `revert` not just as an error signal but as a **control-flow primitive**. The pattern: compute everything, validate everything, *then* mutate storage and emit events. If any validation fails, nothing has changed. This makes the protocol's state machine formally auditable: an auditor can prove no function leaves partial state by inspecting the order of storage mutations relative to reverts. 
 
>  **Meridian example:** `withdraw()` first computes debt delta, validates collateral ratio, then reduces balance in storage, then calls the token transfer. If the token transfer reverts, the balance reduction reverts with it. No partial accounting is ever committed.

### Out-of-gas vs. revert — a critical asymmetry

An **out-of-gas (OOG)** exception behaves like a revert (state rolls back) but consumes the *entire remaining gas*. This distinguishes it from a normal `REVERT`, which only charges through the point of failure. In nested calls, OOG in a callee that received 63/64 of remaining gas can leave the caller's code running with a dangerously small budget.

## Gas Accounting — The Equations

### Worked example: the cost of one storage write

| Component | Gas | Reason |
| --- | --- | --- |
| Intrinsic base | 21,000 | Every transaction, always |
| Calldata (selector + 32-byte arg) | ~900 | ≈ 4 non-zero bytes × 16 + overhead |
| Cold `SLOAD` of slot key | 2,100 | First access to this slot this transaction (EIP-2929) |
| Fresh non-zero `SSTORE` | 20,000 | Writing a new non-zero value (EIP-2200) |
| **Total (approximate)** | **~44,000** |  |

Same function called a second time in the same transaction (warm slot, same value):

| Component | Gas |
| --- | --- |
| Intrinsic | 21,000 |
| Calldata | ~900 |
| Warm `SLOAD` | 100 |
| Warm `SSTORE`, unchanged value | 100 |
| **Total (approximate)** | **~22,100** |

> **The 2× principle** —  
>  The difference between a cold write and a warm no-op is ~22,000 gas — essentially one full intrinsic cost. This single ratio drives: caching storage reads in local memory variables, packing multiple state fields into one slot, and avoiding redundant writes. Every gas optimization you will ever write traces back to this comparison.

## Code Walkthrough — EVM in Miniature

The following contract models EVM data-layer semantics in isolation: storage persistence, atomicity on revert, and call-frame isolation. It is pedagogical only — not for production. Read it as an executable specification of the three properties that Meridian's lending engine relies on.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pedagogical model of the EVM's three data-layer properties:
///   1. Storage persists across calls.
///   2. Revert rolls back all storage changes atomically.
///   3. Call frames are memory-isolated from each other.
/// @dev Not for production.
contract EvmMiniature {

    /// @dev Simulates the EVM's 256-bit key → 256-bit value persistent store.
    mapping(uint256 => uint256) private _storage;

    /// @notice Emitted on every slot write — mirrors the SSTORE opcode
    ///         which costs 20,000 gas for a fresh non-zero value.
    event SlotWritten(uint256 indexed slot, uint256 value);

    /// @notice Models SSTORE. Writing zero (clear) costs 2,900 gas;
    ///         writing non-zero costs 20,000 gas. (EIP-2200 / EIP-2929)
    /// @param slot  256-bit storage key.
    /// @param value Value to store; 0 clears the slot.
    function sstore(uint256 slot, uint256 value) external {
        _storage[slot] = value;
        emit SlotWritten(slot, value);
    }

    /// @notice Models SLOAD.
    ///         Returns 0 for slots that have never been written (EVM default).
    /// @param slot  256-bit storage key.
    /// @return value The stored value.
    function sload(uint256 slot) external view returns (uint256 value) {
        return _storage[slot];
    }

    /// @notice Demonstrates revert atomicity.
    ///         If fail == true, the write to slot 0 is rolled back.
    ///         The caller observes slot 0 unchanged — as if the write never happened.
    ///         This is the property Meridian's withdraw() depends on.
    /// @param fail If true, the transaction reverts after the write.
    function revertIsAtomic(bool fail) external {
        _storage[0] = 42;
        if (fail) revert("atomicity demo");
        // Only reaches here if fail == false.
        // _storage[0] == 42 is committed to world state.
    }

    /// @notice Demonstrates call-frame memory isolation.
    ///         The callee executes in its own memory space.
    ///         If the callee reverts, require() propagates the revert upward.
    /// @param target Contract with a poke() function that writes its own storage.
    function callIsolated(address target) external {
        (bool ok, ) = target.call(abi.encodeWithSignature("poke()"));
        require(ok, "call failed");
    }
}
```

#### Compiler trace — what the bytecode actually does

| Solidity construct | EVM translation | Gas note |
| --- | --- | --- |
| `_storage[slot] = value` | `keccak256(abi.encode(slot, 0))` → 256-bit key → `SSTORE` | Cold: 2,100 access + 20,000 write |
| `emit SlotWritten(slot, value)` | `LOG1` opcode + ABI-encoded topics + data | 375 + 375×topics + 8/byte data |
| `revert("atomicity demo")` | `REVERT` with ABI-encoded string payload | Rolls back pending `SSTORE` at zero extra cost |
| `target.call(...)` | `CALL` opcode; forwards all remaining gas | New frame; callee memory discarded on return |

## Production Reference — UniswapV2Pair._update

The canonical production exemplar for EVM execution discipline is Uniswap V2's `UniswapV2Pair.sol`. The `_update` function is celebrated precisely for what it *avoids* — every omission is a gas or security decision:

```solidity
function _update(
    uint balance0, uint balance1,
    uint112 _reserve0, uint112 _reserve1
) private {
    // [1] Bounds check before any storage write.
    //     uint112 max = 2^112 - 1. EVM wraps silently without this.
    require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'UniswapV2: OVERFLOW');

    uint32 blockTimestamp = uint32(block.timestamp % 2**32);
    uint32 timeElapsed = blockTimestamp - blockTimestampLast;

    // [2] TWAP oracle accumulation — intentional SSTORE on every swap.
    //     += on a storage variable compiles to SLOAD + ADD + SSTORE.
    if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
        price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
        price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
    }

    // [3] Minimal writes: exactly two SSTORE operations per _update call.
    //     reserve0/reserve1 packed into adjacent 112-bit fields in one slot.
    reserve0 = uint112(balance0);
    reserve1 = uint112(balance1);
    blockTimestampLast = blockTimestamp;

    // [4] Event emission after all state changes — never before.
    emit Sync(reserve0, reserve1);
}
```

| Design choice | EVM rationale |
| --- | --- |
| Only 2 `SSTORE`s per call | Each fresh write costs ~22,100 gas; minimising writes is the primary gas lever |
| `uint112` bounds check before write | EVM arithmetic wraps silently under Solidity <0.8; explicit bounds prevent state corruption |
| TWAP `+=` on storage | Intentional write-per-swap to make time-weighted price accumulation possible |
| No external calls | Eliminates reentrancy surface entirely — the two token transfers are handled in the calling `swap()` function, not here |
| Event emitted last | Standard check-effects-interactions: events are the final record of a committed state change |

> **Meridian's MeridianVault.sol follows the same discipline** —  
>  Module 5 will implement the vault with identical constraints: minimal storage writes, explicit bounds on all user-facing inputs, external token calls last, events after all state mutations.

### Foundry Lab — EvmMiniatureTest.t.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EvmMiniature} from "../src/EvmMiniature.sol";

contract EvmMiniatureTest is Test {
    EvmMiniature internal mini;

    function setUp() public {
        mini = new EvmMiniature();
    }

    /// [UNIT] Storage persists: write a value, read it back.
    function test_SstoreSloadRoundtrip() public {
        mini.sstore(7, 1234);
        assertEq(mini.sload(7), 1234);
    }

    /// [UNIT] Clearing a slot reads back zero (the EVM default).
    function test_ClearSlot() public {
        mini.sstore(9, 99);
        mini.sstore(9, 0);
        assertEq(mini.sload(9), 0);
    }

    /// [FUZZ] Any slot/value pair round-trips correctly.
    ///        This becomes the template for Meridian's invariant suite.
    function testFuzz_Roundtrip(uint256 slot, uint256 value) public {
        mini.sstore(slot, value);
        assertEq(mini.sload(slot), value);
    }

    /// [INVARIANT] A reverting call leaves no partial state.
    ///             slot 0 must retain its pre-call value after revert.
    function test_RevertIsAtomic() public {
        mini.sstore(0, 1);
        vm.expectRevert(bytes("atomicity demo"));
        mini.revertIsAtomic(true);
        assertEq(mini.sload(0), 1, "partial state must not persist after revert");
    }

    /// [GAS] Measures the write vs. clear cost asymmetry.
    ///       Expected: setUsed ≫ clearUsed (~22,100 vs ~5,000 including overhead).
    function test_GasCostAsymmetry() public {
        uint256 setGas = gasleft();
        mini.sstore(42, 1);
        uint256 setUsed = setGas - gasleft();

        uint256 clearGas = gasleft();
        mini.sstore(42, 0);
        uint256 clearUsed = clearGas - gasleft();

        assertGt(setUsed, clearUsed, "non-zero write must cost more than clear");
        emit log_named_uint("gas: set (approx)", setUsed);
        emit log_named_uint("gas: clear (approx)", clearUsed);
    }
}

// Run: forge test -vvv --match-path test/EvmMiniatureTest.t.sol
```

> **What each test proves** —  
> **Roundtrip / ClearSlot:** storage persists across calls and clears to zero.
 
> **testFuzz_Roundtrip:** the invariant holds for all (slot, value) pairs — this is the seed of Meridian's invariant test suite.
 
> **test_RevertIsAtomic:** no partial state survives a revert — the property the entire DeFi composability model depends on.
 
> **test_GasCostAsymmetry:** theory becomes measurable. Expect set ≈ 22,100 gas; clear ≈ 5,000 gas including warm-slot overhead.

## Security Analysis — Vulnerability Classes from EVM Semantics

These vulnerabilities exist because of how the EVM is built — not because of application logic. Understanding their mechanical cause is the only reliable defence.

**tx.origin Authorization (Phishing via Middle Contract)** —   `tx.origin` is the original EOA. If a contract authorizes with `tx.origin == owner`, a phishing contract can call it on the user's behalf and pass the check — the user never authorized the target contract directly.  **Attack path:** User EOA → PhishingContract → VictimContract (tx.origin == User ✓) 
**Fix:** Always use `msg.sender`. Never `tx.origin` for authorization.

**Reentrancy (The Reason CEI Exists)** —   A call hands control to an external contract before the caller resumes. An attacker contract can re-enter the caller mid-execution, before balance deductions are written.   **Classic path:** `withdraw()` transfers ETH → attacker's `receive()` re-enters `withdraw()` → balance still pre-deduction → double-withdraw.  
**Fix:** Check-Effects-Interactions — update state before external calls. Treated exhaustively in Chapter 24.

**Call-Depth / Stack-Depth Griefing** —   The EVM caps call depth at 1,024. Before EIP-150, deep call stacks were a reliable DoS vector. Today the residual risk is `STACK_TOO_DEEP` in compiled code with many nested scopes, and recursion driven by user-supplied input.  
**Fix:** No recursion on user-controlled depth. Prefer explicit iteration with bounded loop counts.

**Unbounded Loop / OOG Griefing** —   A function that iterates over a user-controlled-length array can be forced out-of-gas, bricking it for everyone. The attacker loses little; the protocol loses a critical function (liquidation, settlement, distribution).  
**Fix:** Bounded loops only. Use fixed-size batch windows (Meridian's LiquidationEngine pattern).

**DELEGATECALL Storage Collision** —   `DELEGATECALL` executes foreign code against the caller's storage. If the proxy and implementation have overlapping slot layouts, one contract's variable occupies another's slot — a silent state corruption that is extremely hard to debug.  
**Fix:** Use EIP-1967 storage slots for proxy admin state. Audit slot layouts before every upgrade.

**selfdestruct Deprecation (EIP-6780)** —   `selfdestruct` was deprecated in Cancun (Dencun, 2024). A contract can no longer be assumed to delete its bytecode via `selfdestruct` except within the same transaction it was created. Any logic depending on post-deploy `selfdestruct` is broken on current networks.  
**Fix:** Remove all `selfdestruct` logic. Use upgradeable patterns for lifecycle management.

## Gas Optimization Patterns

### Pattern 1 — Cache storage reads in memory

```solidity
function bad() external view returns (uint256) {
    // Two cold SLOADs: 2 × 2,100 = 4,200 gas
    return _totalDebt + _totalDebt / 100;
}
```

```solidity
function good() external view returns (uint256) {
    // One cold SLOAD: 2,100 gas
    uint256 debt = _totalDebt;
    return debt + debt / 100;
}
```

↓ 4,200 → 2,100 gas on cold reads (2× saving)

### Pattern 2 — Pack struct fields into one slot

A Solidity struct whose fields fit in 256 bits total occupies one storage slot. Writing the whole struct once costs one `SSTORE` (20,000 gas). Writing each field separately costs N × 20,000 gas. This is why Meridian's position structs pack `balance`, `index`, and flags into tightly packed slots.

| Approach | Storage writes | Gas cost |
| --- | --- | --- |
| Write 2 separate `uint128` fields | 2 × SSTORE | 40,000 gas |
| Pack both into one `uint256` slot | 1 × SSTORE | 20,000 gas |

### Pattern 3 — Use `immutable` for deploy-time constants

Variables declared `immutable` are baked into the contract's bytecode at deploy time. Reading one costs ~3 gas (a `PUSH` opcode) versus 2,100 gas for a cold `SLOAD`. Meridian uses `immutable` for oracle addresses, token addresses, and governance parameters that are fixed at deployment.

### Pattern 4 — Avoid `transfer` and `send`

Both forward only 2,300 gas — enough for an event log, not for any meaningful computation. Modern tokens (ERC-777, ERC-20 with hooks) will revert on transfer to a contract with this stipend. Use `call{value: amount}("")` with explicit reentrancy protection instead.

## Common Mistakes

- **`tx.origin` for authorization.** Works in tests because tests have no intermediary. Broken in production as soon as a middle contract is involved. Always `msg.sender`.
- **Ignoring the return value of `call`.** `(bool ok, ) = target.call(...);` — if you don't check `ok`, a failing callee silently continues your execution with wrong state. Meridian convention: always check the bool.
- **Storage writes inside loops.** 20,000 gas per fresh slot × N iterations = OOG or an unpayable gas bill. Restructure as batch operations or accumulators flushed after the loop.
- **Repeated cold storage reads instead of caching.** Five cold `SLOAD`s = 10,500 gas versus one read + four memory accesses ≈ 2,100 gas total. The optimizer catches some of this; explicit caching is predictable and auditable.
- **Assuming `transfer` / `send` are safe for arbitrary receivers.** The 2,300 gas stipend is sufficient for a log emit only. Use `.call{value:}("")` with a reentrancy guard.
- **Depending on `selfdestruct` behaviour.** EIP-6780 (Cancun, 2024) restricts `selfdestruct` to the deployment transaction. Post-deploy `selfdestruct` no longer clears bytecode. Any protocol logic depending on this is broken silently.
- **Assuming EIP-2929 warm/cold is irrelevant to reentrancy economics.** A second call to a warm contract costs less — this shifts the profitability threshold for reentrancy bots and affects the gas arithmetic of reentrancy guards.

## Exercises & Weekly Lab

### Conceptual exercises

- Derive why rewriting a storage slot to its current value costs only 100 gas. What must the EVM compare to determine this, and what invariant does it enforce about storage-write optimisation?
- Trace a transaction calling `EvmMiniature.sstore(1, 5)` from an EOA. List every gas charge in order: intrinsic base, calldata, cold access, write, log opcodes.
- Write both a `call`-based and a `transfer`-based ether-send function. When is each appropriate? Explain what happens if the recipient is a contract with non-trivial `receive()` logic under each approach.
- Explain why `revert` can be used as a control-flow primitive in production. Give a concrete Meridian scenario: describe the exact order of operations in a `withdraw()` call and show how revert ordering guarantees no partial state.
- A function contains `for (uint i = 0; i < n; i++) { _storage[i] = i; }` with user-supplied `n`. Estimate gas for `n = 1000` (show your arithmetic). Explain the griefing mechanism and the protocol fix.

### Weekly Project — EVM Cost Model Calculator

> **Project 1.1 · meridian/tools/** —  
> Build a Foundry-based cost measurement tool. The goal: produce a gas table that validates the theoretical numbers against real EVM execution.

1. Initialise repo: `forge init meridian --no-git` (creates `src/`, `test/`, `script/`).
2. Write `src/CostProbe.sol` — one function per operation: fresh SLOAD, warm SLOAD, fresh SSTORE, SSTORE-clear, LOG, memory expansion at 1/64/1024 words.
3. Write `test/CostProbe.t.sol` — wrap each call with `gasleft()` deltas; run `forge test -vvv --gas-report`.
4. Produce `docs/gas-model.md` — table of measured vs. theoretical costs (21,000 / 2,100 / 20,000 / 2,900 / 100) with discrepancy explanation.
5. Tag: `git tag v0.1.0` (module milestone convention).

> **Success criteria** —  
> All tests pass. Gas table within 5% of theoretical values. One-paragraph note in `docs/gas-model.md` explaining the difference between a `view` function's gas (not charged on-chain) and a state-changing function's gas (charged and burned).

## Quiz

Tap a question to reveal the answer.

- **Q.** Why does the EVM use 256-bit words rather than 64-bit? 
  **A.** Two compounding reasons: (1) Keccak-256 produces 256-bit outputs — addresses (160-bit subsets) and storage keys (full 256-bit hashes) fit exactly one word, eliminating multi-word gymnastics on every hash or storage access; (2) Ethereum's smallest denomination (wei) requires large integer ranges, and 256 bits provides orders of magnitude more headroom than needed. The word is the unit of all computation: stack slots, memory addressing, storage keys, arithmetic.
- **Q.** What is the gas cost breakdown for a fresh non-zero SSTORE? 
  **A.** A fresh write costs 2,100 gas (EIP-2929 cold slot access) + 20,000 gas (EIP-2200 set non-zero value) = 22,100 gas. Clearing a slot (writing zero) costs 2,100 + 2,900 = 5,000 gas and grants a refund, capped by EIP-3529 at gas_used / 5. Rewriting the same value to a warm slot costs only 100 gas.
- **Q.** What happens to storage changes when a transaction reverts? 
  **A.** They are rolled back atomically — every storage and balance change made in the reverting call frame and all nested frames below it is undone as if execution never reached those instructions. The only things retained are: (1) gas consumed up to the revert point, and (2) the revert reason payload in the return buffer. The full gas limit is NOT consumed on a normal revert; only an out-of-gas exception consumes all remaining gas.
- **Q.** Why is tx.origin authorization dangerous? 
  **A.** tx.origin is the original EOA that signed the top-level transaction — it does not change throughout the entire call chain. A phishing contract can call the victim contract on the user's behalf; the victim sees tx.origin == user and grants access even though the user never directly called the victim. The fix: always use msg.sender, which is the immediate caller and changes at each call boundary.
- **Q.** What is the 63/64 gas rule and what attack does it enable? 
  **A.** EIP-150 (Berlin) limits a callee to at most 63/64 of the caller's remaining gas. This prevents a callee from holding the entire gas supply. The attack it enables is griefing: a malicious callee can deliberately burn its entire 63/64 allotment, leaving the caller's post-call code to run on only ~1.5% of its expected budget — potentially causing an out-of-gas exception in code that assumed sufficient gas remained after the call.
- **Q.** What is the difference between DELEGATECALL and CALL in terms of storage access? 
  **A.** CALL creates a child frame where the callee reads and writes its own contract's storage. DELEGATECALL executes the callee's code but reads and writes the caller's storage — the callee's code runs as if it were part of the calling contract. This is used for proxy patterns but introduces storage collision risk: if the proxy and implementation use the same storage slots for different variables, one silently overwrites the other. EIP-1967 standardises slot offsets specifically to avoid this.

## Further Reading

- Spec **Ethereum Yellow Paper** (Gavin Wood) — canonical EVM specification. Read the "Execution Model" section first before any secondary source.
- EIP-150 **EIP-150** — gas cost changes and the 63/64 rule. The motivation section explains the DoS attacks it mitigated.
- EIP-2200 **EIP-2200** — SSTORE gas metering revisions. The current cost model derives from this; read alongside EIP-2929.
- EIP-2929 **EIP-2929** — cold/warm access lists (Berlin). Introduced the 2,100/100 SLOAD split that drives caching patterns.
- EIP-3529 **EIP-3529** — refund cap reduction (London). Eliminated gas-token arbitrage; cap set to gas_used/5.
- EIP-3860 **EIP-3860** — initcode word-cost metering (Shanghai). Affects contract deployment gas estimates.
- EIP-6780 **EIP-6780** — selfdestruct restriction (Cancun/Dencun). Critical for any protocol that assumed post-deploy selfdestruct.
- EIP-1967 **EIP-1967** — standard proxy storage slots. Prevents storage collisions in DELEGATECALL-based proxies.
- Tool **evm.codes** — interactive opcode reference with exact gas costs, stack effects, and EIP linkage. Bookmark it.
- Library **OpenZeppelin Contracts** — production Solidity embodying every rule in this chapter. Read ERC20.sol, SafeERC20.sol.
- Reference **Uniswap V2 Core** (UniswapV2Pair.sol, ~250 lines) — the minimal exemplar. Trace every storage access and require.
