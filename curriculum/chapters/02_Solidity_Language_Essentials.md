# Solidity Language Essentials

Solidity is not a runtime — it is a compiler front-end over the EVM you already understand. Every feature in this chapter is a compile-time construct that lowers to opcodes. Knowing that, every type boundary, visibility rule, and error convention becomes derivable rather than memorised.

### Contents

1. [Learning Objectives](#learning-objectives)
2. [Solidity is a Compiler Front-End](#solidity-is-a-compiler-front-end-not-a-runtime)
3. [Value Types](#value-types)
4. [Reference Types & Data Locations](#reference-types--data-locations)
5. [Visibility × Mutability Matrix](#visibility--mutability-matrix)
6. [Events — The Query Interface](#events--the-query-interface)
7. [Errors — Three Ways to Fail](#errors--three-ways-to-fail)
8. [Locked Conventions](#locked-conventions--meridian-style-canon)
9. [Version Rails & the Compiler as Auditor](#version-rails--the-compiler-as-your-first-auditor)
10. [Mathematical Foundations — Integer Boundaries](#mathematical-foundations--integer-boundaries--wrap-semantics)
11. [Code Walkthrough — ErrorProbe.sol](#code-walkthrough--errorprobesol)
12. [Production Reference — OZ v5 IERC20Errors](#production-reference--oz-v5-ierc20errors--reading-plan)
13. [Security Analysis](#security-analysis--language-level-vulnerability-classes)
14. [Gas Optimization](#gas-optimization)
15. [Common Mistakes](#common-mistakes)
16. [Exercises & Weekly Project](#exercises--weekly-project)
17. [Quiz](#quiz)
18. [Further Reading](#further-reading)

## Learning Objectives

By the end of this chapter you will be able to:

- **Obj 01** —  Explain Solidity's role as a compiler front-end over the EVM, and derive why its type system is built around the 256-bit word.
- **Obj 02** —  Classify every value type (`bool`, `uintN/intN`, `address`, `bytesN`, `enum`) and reference type (`array`, `struct`, `mapping`, `string/bytes`), and state which data locations each may occupy and what copies cost.
- **Obj 03** —  Apply the visibility (`external/public/internal/private`) and mutability (`view/pure/payable`) matrix correctly, including `receive()` and `fallback()` semantics.
- **Obj 04** —  Design events as a query interface — topics vs data, indexed limits, LOG gas model — using ERC-20's `Transfer` as the canonical example.
- **Obj 05** —  Derive why Meridian locks custom errors over `require` strings: gas at deployment, gas at runtime, typed revert payloads, and audit surface.
- **Obj 06** —  Read a production Solidity file (OZ v5 `ERC20.sol`) and identify every convention Meridian's style guide inherits from it.

## Solidity is a Compiler Front-End, Not a Runtime

There is no "Solidity virtual machine." Solidity compiles to EVM bytecode and the EVM (Chapter 01) is the only runtime that ever executes. This has a direct consequence for how you should read every language feature:

> **The derivation principle** —  
>  Every Solidity feature — types, visibility, modifiers, checked arithmetic, events, errors — is a **compile-time construct** that lowers to EVM opcodes. Its cost and security profile are therefore fully determined by how it lowers. If you know the opcode, you know the cost. If you know the cost, you can design around it.

| Solidity feature | Lowers to | Why it exists |
| --- | --- | --- |
| Type system | Compile-time checks; no runtime type tag | EVM is word-addressed and weakly typed at opcode level — types catch mistakes before they become `SSTORE`s to the wrong slot |
| Visibility & mutability | Code-generation gates (no runtime cost) | Prevent whole bug classes at zero runtime overhead — the compiler rejects `SSTORE` in a `view`, external calls in a `pure` |
| Events | `LOG0`–`LOG4` opcodes | Cheap, indexed, bloom-filterable — the external query interface for protocol state |
| Custom errors | `REVERT` + 4-byte selector + ABI args | Typed revert payloads; cheaper than strings; decodable by clients without parsing |
| Modifiers | Textual expansion — inlined into the function body | No call overhead; the `_` placeholder is replaced at compile time, not at runtime |

## Value Types

Value types are copied on assignment. They always fit in one EVM word (256 bits) and live on the stack or in storage slots. The type system is a direct encoding of two's-complement arithmetic over 256-bit words.

#### Integers

- val `uintN / intN` — N ∈ {8, 16, …, 256} in 8-bit steps. Default `uint256` is one EVM word — the cheapest arithmetic type.
- val Sub-256 types do **not** save gas in computation. The EVM has no 8-bit opcodes — the compiler sign/zero-extends to 256 bits, operates, then truncates. More instructions, not fewer.
- val Sub-256 types **do** save gas in storage packing (Chapter 06) — several small-type fields can share one storage slot.
- val Signed `intN` is two's complement: `int8 ∈ [−128, 127]`, `int256 ∈ [−2²⁵⁵, 2²⁵⁵−1]`.

#### Addresses & Fixed Bytes

- val `address` — 160-bit value in a 256-bit word. No arithmetic. Cannot receive value directly.
- val `address payable` — additionally permits `transfer` / `send` / `call{value:}`. Explicit cast since 0.8.0 — a compile-time rail against accidental value sends.
- val `bytes1`–`bytes32` — value types (unlike dynamic `bytes`). `bytes32` is the natural home of hashes — aligns with the 256-bit Keccak-256 word from Chapter 01.
- val `bool` — `uint8` in storage; 1 bit when packed.

#### Enums

- val Stored as `uint8` unless packed. Can represent up to 256 members.
- val Key property: **invalid states become unrepresentable**. A two-member `Status` enum cannot hold a third value — "invalid state" bugs become compile errors. Use enums aggressively to constrain protocol state machines.

#### Function Types

- val `function(params) visibility mutability returns(rets)` — first-class values.
- val Internal pointers: compile-time `JUMP` targets. External pointers: `(address, selector)` pairs invoked via `CALL`.
- val **Footgun:** a `public` state variable of function type is callable by anyone on-chain. Expose callbacks via `internal` storage + an explicit `external` caller.

## Reference Types & Data Locations

Reference types — `array`, `struct`, `mapping`, `string`, `bytes` — designate a region in a data location. They have no value semantics; copying them copies that region. The location determines persistence, cost, and what operations are permitted.

| Location | Persists | Cost model | Allowed types | Allowed for |
| --- | --- | --- | --- | --- |
| **storage** | Forever (across transactions) | SLOAD 100 warm / 2,100 cold
SSTORE 100 / 2,900 / 20,000 | Everything — including mappings | State variables |
| **memory** | Per call frame only | 3 gas/word + quadratic expansion (Ch 01) | Everything except mappings | Intermediate computation, return values |
| **calldata** | Per call (read-only) | 3 gas/word to read; zero copy cost | Everything except mappings | `external` function arguments only |

### Three rules to internalise

> **Rule 1 — Mappings live only in storage** —  
>  Mappings have no length, no iteration, and no existence for keys that were never written. They are implemented as pure key-hashing into storage slots — there is no contiguous structure to pass, return, or materialize in memory. If you need iteration, pair a mapping with an array of keys in storage.

> **Rule 2 — Copies are the cost** —  
>  `storage → memory`: copies the entire value. `calldata → memory`: copies the entire value. `storage → storage` for structs/arrays: creates an *alias*, not a copy — writing through the alias writes the original. This is the source of the "uninitialized storage pointer" vulnerability class (see §Security Analysis): a storage reference that is never assigned defaults to slot 0.

> **Rule 3 — calldata is free to read** —  
>  An `external` function reads dynamic arguments directly from transaction calldata with no memory copy. A 1,000-element `uint256[]` in calldata avoids approximately 4,953 gas of memory-expansion cost vs a `public memory` parameter. Default to `external` + `calldata` for large array arguments.

> **strings vs bytes32 — when each belongs** —  
>  `string` is UTF-8 encoded `bytes`: dynamic, heap-allocated, expensive to hash or compare. `bytes32` is a fixed-size value type: one word, stack-native, cheap. Protocol code stores bounded labels (asset symbols, role names) as `bytes32`. Use `string` only for unbounded human-readable content exposed to UIs.

## Visibility × Mutability Matrix

Every Solidity function has exactly one **visibility** (who can call it) and one **mutability** (what it may do to state). Together they form a compile-time capability system — violations are rejected, not just warned about.

| Mutability | `external` | `public` | `internal` | `private` |
| --- | --- | --- | --- | --- |
| state-changing (default) | ✓ | ✓ | ✓ | ✓ |
| view (reads state, no writes) | ✓ | ✓ | ✓ | ✓ |
| pure (no state access at all) | ✓ | ✓ | ✓ | ✓ |
| payable (receives ether) | ✓ | rare | ✗ | ✗ |

### Visibility — what each means

| Visibility | Who can call | Arg location | Meridian usage |
| --- | --- | --- | --- |
| `external` | Outside callers only; `this.f()` for self-call | calldata — cheapest for arrays | Default for all user-facing functions |
| `public` | Outside callers + internal calls | memory — args copied (costlier) | State variables only (auto-getter); avoid on functions |
| `internal` | This contract + derived contracts | N/A — lowers to `JUMP`, no ABI | **Default for all protocol helpers** (`_update`-style) |
| `private` | This contract only — not inherited | N/A — lowers to `JUMP` | Used sparingly; prefer `internal` |

### Mutability — what each promises

| Mutability | Compiler enforces | On-chain cost | Off-chain (eth_call) |
| --- | --- | --- | --- |
| `view` | No `SSTORE`, no events, no value transfers | Gas charged normally if called on-chain | Free — no gas consumed |
| `pure` | All of `view` + no `SLOAD`, no `block.*` | Gas charged normally if called on-chain | Free — no gas consumed |
| `payable` | Compiler removes the "no value" revert guard | Can receive ether; omitting reverts on value | N/A |

> **view and pure are free off-chain** —  
>  When a node executes a `view` or `pure` function via `eth_call` (no transaction — just a local simulation), no gas is consumed and nothing is broadcast. This is why front-ends and indexers call getters constantly without cost. The mutability annotation is the signal to the node that no state change will occur.

### receive() and fallback()

These are the only functions callable without knowing the contract's ABI — which makes them the classic reentrancy entry point:

| Function | When triggered | Constraint |
| --- | --- | --- |
| `receive() external payable` | Plain ether transfer with empty calldata | No calldata permitted; must be `payable` |
| `fallback() external [payable]` | Call with unknown selector; or value transfer when `receive` absent | Can optionally be `payable` |

> **Audit receive() and fallback() as named functions** —  
>  Any contract that receives ether has `receive()` as an entry point — reachable by any caller, including the attacker re-entering your `withdraw()`. Treat these with the same scrutiny as any `external` function. If they do more than emit an event, they are almost certainly a reentrancy surface.

## Events — The Query Interface

Events are not debugging tools. They are the **primary external query interface** for protocol state. Indexers (Chapter 37) reconstruct the entire history of a lending market from events alone. Design them accordingly.

### How events lower to opcodes

Every `emit` becomes a `LOG0`–`LOG4` opcode. Topic 0 is always the event's signature hash: `keccak256("Transfer(address,address,uint256)")`. Up to three additional parameters may be marked `indexed`, becoming topics 1–3. All remaining parameters go into the ABI-encoded data field.

### indexed vs data — spend topics deliberately

| Parameter treatment | Gas cost per 32-byte value | Filterable by indexers? | When to use |
| --- | --- | --- | --- |
| data (non-indexed) | ~260 gas (8 × 32 bytes) | ✗ Opaque to bloom filters | Values you read but never filter on (amounts, timestamps) |
| `indexed` topic | 375 gas | ✓ Bloom-filterable | Addresses, IDs — fields you query by in subgraph or logs API |

> **Canonical example — ERC-20 Transfer** —  
>  `event Transfer(address indexed from, address indexed to, uint256 value)` 
 
>  `from` and `to` are indexed because wallets and indexers constantly filter "all transfers involving address X." The `value` is data because no one usefully filters "all transfers of exactly 1,234 tokens." This single design choice makes ERC-20 event logs trivially queryable on every block explorer. 
 
>  Gas: `375 + 2×375 + 8×32 = 1,381 gas` (two indexed topics, one 32-byte data field) — compare with the two balance `SSTORE`s it describes: ~40,000 gas. The event is 97% cheaper than the storage it records.

### Event naming convention — always past tense

Events record something that already happened. Name them accordingly: `CollateralDeposited`, `LoanRepaid`, `ProbeAccepted` — not `DepositCollateral`, `RepayLoan`. When an indexer replays event logs, the stream should read as a ledger of completed actions.

## Errors — Three Ways to Fail

A `REVERT` opcode can carry three different payload shapes. Understanding each is necessary for writing decodable reverts, integrating with clients, and making the cost-justified design choice Meridian locks as a convention.

`require(cond, "message")`

Reverts with `Error(string)`, selector `0x08c379a0`. The string is embedded in deployed bytecode.

`error NotAuthorized(address caller);`
`revert NotAuthorized(msg.sender);`

Reverts with 4-byte selector + ABI-encoded args (≥ Solidity 0.8.4).

Internal failures: overflow, div/0, array OOB, failed `assert`.

Reverts with `Panic(uint256)`, selector `0x4e487b71`.

### Why Panic codes matter to integrators

Clients that only catch `Error(string)` will silently miss a `Panic(0x11)` overflow and vice versa. Typed custom errors eliminate this ambiguity at the source: every revert has a unique, named, decodable selector. A client can `switch` on the 4-byte selector and handle each case explicitly — no string matching, no selector collisions with the generic `Error`/`Panic` variants.

### Auditability — errors as a catalog

A custom error is declared once in an interface and can fail from multiple call sites. An auditor can grep the entire error catalog in one file and trace every call site that raises each error — the failure surface of the contract is visible at a glance. A `require` string is per-call-site, opaque, and often duplicated with slight variations that obscure which condition is actually being checked.

## Locked Conventions — Meridian Style Canon

The following conventions are locked as of Chapter 02 and apply to every contract in the Meridian protocol, starting with `MeridianToken.sol` in Chapter 14. They are checkable by a reviewer with a yes/no question.

- **Custom errors only.** No `require` strings in protocol code. Each error carries typed params with the offending values: `error NotAuthorized(address caller)`, `error AboveBound(uint256 bound, uint256 received)`.
- **Errors live in `I`-prefixed interfaces.** A contract's entire failure surface is visible in one place — the model is OZ v5's `IERC20Errors`. Every function, event, AND error is declared in the interface.
- **Panic codes for true invariants only.** Use `assert` to guard conditions that should be mathematically impossible — not user-input validation. User-input validation uses named custom errors.
- **Past-tense, indexed events.** Name: `CollateralDeposited`, not `DepositCollateral`. Index addresses and IDs. Leave amounts and values in data.
- **immutables over storage for deploy-time constants.** Addresses, bounds, configuration set in the constructor and never changed live in `immutable` variables — 3 gas to read vs 2,100 cold SLOAD.
- **`external` as default visibility for user-facing functions.** Use `public` only for state variable auto-getters. Use `internal` for all protocol-internal helpers.
- **CEI order throughout.** Check conditions, then mutate state (Effects), then make external calls (Interactions). Events are emitted after all state mutations — they are the final record of a committed change.
- **Pinned compiler: `^0.8.24`.** Locked in CI (Chapter 13). PUSH0 requires Cancun-compatible deployment target.

## Version Rails — The Compiler as Your First Auditor

Each major Solidity release added compiler-enforced constraints that eliminated an entire bug class. Knowing the version history means knowing what the compiler holds for you — and what it still cannot see.

| Version | Rail added | Bug class it eliminated |
| --- | --- | --- |
| `0.5.0` | Mandatory visibility; state-variable shadowing is an error | Implicit `public` on functions; shadowed `owner`-style names causing privilege bugs |
| `0.8.0` | Checked arithmetic by default (`+`, `-`, `*` revert on overflow) | The 2018 "batchOverflow" ERC-20 attacks (BeautyChain, SmartMesh) — unchecked sums wrapped past 2²⁵⁶ and minted arbitrary tokens |
| `0.8.4` | Custom errors | Opaque require strings; non-decodable revert payloads |
| `0.8.20` | `PUSH0` opcode support | Cheaper zero-push; requires Cancun-compatible deployment target |
| `0.8.24` | Transient storage (`tstore`/`tload`), Cancun support | Enables EIP-1153 reentrancy guards without storage gas cost |

> **Loose pragmas are a CI failure** —  
>  `pragma solidity >=0.8.0` lets your CI pick any compiler from 0.8.0 to 0.8.24+. Code compiled under different versions can have different codegen: custom errors require ≥0.8.4, `PUSH0` requires ≥0.8.20 + Cancun target. A contract that passes audit under one version can behave differently under another. Meridian pins `^0.8.24` and the exact `solc` binary in CI (Chapter 13).

### unchecked — when Meridian uses it

The `unchecked` block disables overflow checks for all arithmetic inside it — saving ~20–30 gas per operation by removing the `Panic(0x11)` guard. Meridian uses `unchecked` only where Chapter 04's rounding analysis proves the operation cannot overflow given the preceding constraints. Never use it as a blanket performance shortcut.

## Mathematical Foundations — Integer Boundaries & Wrap Semantics

| Type | Min | Max | Bit width |
| --- | --- | --- | --- |
| `uint8` | 0 | 255 | 8 |
| `uint16` | 0 | 65,535 | 16 |
| `uint128` | 0 | ~3.40 × 10³⁸ | 128 |
| `uint256` | 0 | ~1.16 × 10⁷⁷ | 256 |
| `int8` | −128 | 127 | 8 |
| `int256` | −2²⁵⁵ | 2²⁵⁵ − 1 | 256 |

### Two facts that drive every protocol decision

> **Fact 1 — Wrapping is modular arithmetic (in unchecked mode)** —  
>  In `unchecked` mode, addition on `uintN` computes `(a + b) mod 2ᴺ`. This is exactly the 2018 batchOverflow exploit: `amount * n` wrapped past 2²⁵⁶ − 1 and "became" a small number that passed the supply cap check — minting tokens from nothing. Checked mode (Solidity ≥0.8.0 default) turns that silent wrap into `Panic(0x11)`.

> **Fact 2 — Sub-256 promotion is implicit and strict** —  
>  `uint8 x = 255; x + 1` in checked mode reverts. The addition is promoted to 256-bit space (`255 + 1 = 256`), then the overflow check fires on the promoted value before truncation back to 8 bits. This is stricter than C's behavior (which truncates first) and is the assumption Chapter 04's rounding analysis builds on.

Deeper math — rounding direction, fixed-point, 512-bit `mulDiv` — arrives in Chapter 04. This chapter requires only that you know the boundaries and wrap semantics.

## Code Walkthrough — ErrorProbe.sol

`ErrorProbe` is a pedagogical measurement contract — not protocol code — written to the Meridian style guide in miniature. Its purpose is to make the locked conventions concrete and gas-measurable before the first protocol contract appears.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IErrorProbe
/// @notice I-prefix convention: the entire external surface —
///         functions, events, AND errors — declared in one interface.
///         Cf. OZ v5 IERC20Errors. An auditor reads one file to know
///         every way this contract can fail.
interface IErrorProbe {

    /// @notice Raised when a probed value exceeds the configured bound.
    ///         Both values are attached — the client renders "42 > 100"
    ///         without parsing a string.
    /// @param bound     The configured maximum.
    /// @param received  The rejected value.
    error AboveBound(uint256 bound, uint256 received);

    /// @notice Emitted when a probed value is accepted.
    ///         Past-tense name — reads as history in an event log.
    ///         caller indexed: filtered on. value in data: not filtered on.
    event ProbeAccepted(address indexed caller, uint256 value);

    function bound() external view returns (uint256);
    function probe(uint256 value) external;
    /// @notice Exists ONLY for lab measurement — violates the locked convention.
    ///         Never copy this pattern into protocol code.
    function probeLegacy(uint256 value) external;
}
```

```solidity
/// @title ErrorProbe
/// @notice Pedagogical measurement contract for Chapter 2.
///         NOT part of the Meridian protocol.
/// @dev Conventions demonstrated: I-prefix interface, immutable config,
///      typed custom errors, past-tense indexed events, CEI ordering.
contract ErrorProbe is IErrorProbe {

    /// @dev immutable: set once in the constructor, embedded in bytecode.
    ///      Reads as PUSH32 (~3 gas) instead of SLOAD (2,100 cold).
    ///      Chapter 1's "immutables over storage" convention, instantiated.
    uint256 public immutable bound;

    constructor(uint256 bound_) {
        bound = bound_;
    }

    /// @inheritdoc IErrorProbe
    function probe(uint256 value) external {
        // CHECK first (CEI): typed error with both values attached.
        // Nothing has been written yet — revert costs are minimal.
        if (value > bound) revert AboveBound(bound, value);

        // EFFECT (CEI): the only state change is the log.
        // Past-tense name; caller indexed; value in data.
        emit ProbeAccepted(msg.sender, value);
        // No external INTERACTION needed here — events are the final record.
    }

    /// @inheritdoc IErrorProbe
    /// @dev Deliberate anti-pattern for gas measurement.
    ///      String is embedded in bytecode; reverts as Error(string)
    ///      (61 bytes) instead of 4-byte custom selector (36 bytes).
    function probeLegacy(uint256 value) external {
        require(value <= bound, "ErrorProbe: value above bound");
        emit ProbeAccepted(msg.sender, value);
    }
}
```

#### Reading this as an auditor

| Code element | Convention demonstrated | Cost avoided |
| --- | --- | --- |
| `interface IErrorProbe` with `error AboveBound` | I-prefix interface; full failure surface in one file | No per-call-site string duplication; auditor reads one declaration |
| `revert AboveBound(bound, value)` | Typed custom error; check is first statement (CEI) | ~7,200 gas deploy savings vs 40-char string; typed payload for clients |
| `public immutable bound` | Immutables over storage for deploy-time constants | 2,100 → 3 gas per cold read |
| `event ProbeAccepted(address indexed caller, uint256 value)` | Past-tense name; address indexed; amount in data | Correct field in bloom filter; no wasted topic budget on value |
| `probeLegacy` kept deliberately | Anti-pattern preserved for lab measurement only | Lab can quantify the cost difference concretely |

## Production Reference — OZ v5 IERC20Errors & Reading Plan

OpenZeppelin Contracts v5 is the reference implementation for this chapter's conventions. Version 5 removed all `require` strings from core token logic and moved the entire failure surface into a typed error interface:

```solidity
interface IERC20Errors {
    // Every revert in ERC20.sol is one of these. Typed, decodable, catalogable.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
}
```

Notice: every error carries the values that caused the failure. A client receives `ERC20InsufficientBalance(user, 50, 100)` and can render "Your balance of 50 USDC is below the 100 USDC required" without any string parsing.

### Production reading plan — three contracts, one lens

For each contract below, extract the three surfaces separately: function selectors, event topics, and error selectors. That extraction is the core skill Chapter 39's full-system audit will demand.

| Contract | What to look for | Chapter connection |
| --- | --- | --- |
| **OZ v5 ERC20.sol + IERC20Errors.sol** | Error-catalog pattern; `_update` internal centralizing state changes; `Transfer`/`Approval` event discipline; zero `require` strings | Closest relative of Meridian's conventions; directly inherited by `MeridianToken.sol` (Ch 14) |
| **Uniswap V3 UniswapV3Pool.sol** | Terse custom errors (`LOK`); a lock modifier that uses a storage flag instead of an OZ guard; heavy `indexed` usage; no external calls in the modifier itself | Shows minimal-error + heavy-event style; informs Ch 24's reentrancy discussion |
| **Aave V3 Pool.sol** | Mixed style: typed errors beside legacy `require` strings. Count which reverts are typed vs opaque, and articulate why the mix is worse than either extreme for integrators | Migration path case study — what not to do, and why a uniform convention matters |

### Foundry Lab — ErrorProbe.t.sol (4 test categories)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ErrorProbe, IErrorProbe} from "../src/ErrorProbe.sol";

contract ErrorProbeTest is Test {
    ErrorProbe internal probe;
    uint256 constant BOUND = 100;

    function setUp() public { probe = new ErrorProbe(BOUND); }

    // ── Category 1: Revert shape tests ────────────────────────────────
    function test_RevertSelector() public {
        // Selector only — fast check for integrators
        vm.expectRevert(IErrorProbe.AboveBound.selector);
        probe.probe(BOUND + 1);
    }

    function test_RevertPayload() public {
        // Full ABI payload — proves both values are attached
        vm.expectRevert(abi.encodeWithSelector(
            IErrorProbe.AboveBound.selector, BOUND, BOUND + 1
        ));
        probe.probe(BOUND + 1);
    }

    // ── Category 2: Event tests ───────────────────────────────────────
    function test_EventIndexedCaller() public {
        vm.expectEmit(true, false, false, true);
        emit IErrorProbe.ProbeAccepted(address(this), BOUND);
        probe.probe(BOUND);
    }

    // ── Category 3: Gas measurement ───────────────────────────────────
    function test_GasCustomVsString() public {
        uint256 customGas = gasleft();
        try probe.probe(BOUND + 1) {} catch {}
        customGas -= gasleft();

        uint256 legacyGas = gasleft();
        try probe.probeLegacy(BOUND + 1) {} catch {}
        legacyGas -= gasleft();

        // Custom error revert must cost less than string revert
        assertLt(customGas, legacyGas, "custom error must be cheaper");
        emit log_named_uint("custom revert gas", customGas);
        emit log_named_uint("string revert gas", legacyGas);
    }

    // ── Category 4: Fuzz — typed error is the invariant oracle ───────
    function testFuzz_AboveBoundPayloadMatchesFuzzedValue(uint256 value) public {
        vm.assume(value > BOUND);
        vm.expectRevert(abi.encodeWithSelector(
            IErrorProbe.AboveBound.selector, BOUND, value
        ));
        probe.probe(value);
        // The typed error carries the exact fuzzed value — string cannot do this.
    }
}

// Run: forge test -vvv --match-path test/ErrorProbeTest.t.sol
```

> **What each test category proves** —  
> **Revert-shape tests:** clients can match on selector alone or on the full ABI payload — both patterns are valid depending on whether the offending values matter.
 
> **Event tests:** the indexed field (`caller`) is the first topic after the signature hash — confirming the right field is bloom-filterable.
 
> **Gas test:** the convention's cost claim becomes measurable rather than theoretical. Run once; the number is in your lab report.
 
> **Fuzz test:** the typed error is used as an invariant oracle — the payload must carry the exact fuzzed value. No string-based revert can prove this.

## Security Analysis — Language-Level Vulnerability Classes

These vulnerabilities arise from Solidity language semantics — not application logic. The 2026 posture: these are hygiene failures, fixed by the conventions already locked. Audit attention should go to systemic classes (bridge failures, privileged-operator compromise — Chapters 25–27), not to these.

**Reentrancy via receive() / fallback()** —   `receive()` is called before your post-call code resumes. The classic DAO 2016 exploit: `withdraw()` transfers ETH → attacker's `receive()` re-enters `withdraw()` → balance not yet reduced → double withdrawal.  
**Fix:** CEI — deduct balance before the external call. Reentrancy guards only where CEI is insufficient (Ch 24). EIP-1153 `tstore` for cheap transient locks (Ch 24).

**tx.origin Authorization** —   Recap from Chapter 01. A phishing contract calls the victim on the user's behalf; `tx.origin == victim` passes while `msg.sender` would correctly identify the attacker.  
**Fix:** Always authorize with `msg.sender`. Locked since Chapter 01. Never `tx.origin`.

**Uninitialized Storage Pointers** —   Declaring `MyStruct storage s;` without assigning it means `s` points to slot 0 — the first declared state variable. Writing `s.field = x` silently corrupts that variable. Survives compilation with no warning. Documented by Trail of Bits (2018).  
**Fix:** Never declare an unassigned storage reference. Use `memory` for temporaries or explicitly assign: `MyStruct storage s = _structs[id];`

**Revert-in-Loop DoS (Revert Bombing)** —   A loop calling an external function reverts entirely if one element fails — a non-compliant token or a deliberately reverting contract bricks the whole transaction. Affects batch operations, distributions, and liquidation engines.  
**Fix:** Bounded loops (Ch 01 convention). `try/catch` per item where partial success is acceptable. Never iterate over user-controlled-length arrays.

**Variable Shadowing** —   A local or inherited name shadows a state variable. Since 0.5.0, state-variable shadowing is a compilation error; local shadowing is a warning. Shadowed `owner`-style names have caused real privilege escalation bugs.  
**Fix:** Treat all warnings as findings in CI. Prefix private state with `_` (Meridian convention) — makes shadowing visually obvious.

**External Calls Inside Modifiers** —   A modifier is textual expansion — an external call in a modifier executes before the function body and is a reentrancy surface that is invisible at the call site. Anyone reading `onlyOwner` does not expect an external call to happen.  
**Fix:** Meridian modifiers are pure checks (`msg.sender` comparisons, storage reads). No external calls, no `CALL` opcodes, no side effects.

## Gas Optimization

All figures are representative (solc 0.8.24, default optimizer). The Foundry Lab reproduces them on your machine.

### 1. Custom error vs require string (quantified)

| Dimension | require string (40 chars) | Custom error | Saving |
| --- | --- | --- | --- |
| Code deposit (deploy) | ~8,000 gas / 40 bytes | ~800 gas / 4 bytes | ~7,200 gas, −36 bytes per message |
| 30 messages (typical protocol) | ~216,000 gas, ~1.1 KB | ~24,000 gas, 120 bytes | ~192,000 gas, ~1 KB of EIP-170 budget |
| Runtime revert (per call) | ~70 gas more (ABI-encodes Error(string) into memory) | Baseline | ~70 gas/revert — compounds in loops and fuzz campaigns |

### 2. external + calldata vs public + memory

```solidity
// public copies args to memory
function sumArray(
    uint256[] memory arr
) public pure returns (uint256) {
    // 1,000-elem copy: ~4,953 gas
    ...
}
```

```solidity
// external reads calldata in-place
function sumArray(
    uint256[] calldata arr
) external pure returns (uint256) {
    // No copy: ~0 gas on the copy alone
    ...
}
```

↓ ~4,953 → ~0 gas for the memory copy (1,000-element array)

### 3. immutable vs storage read

| How the value is stored | Gas to read | How it works |
| --- | --- | --- |
| `immutable` | 3 gas (PUSH32) | Baked into bytecode at deploy time |
| Storage (cold) | 2,100 gas (SLOAD) | Read from world state on first access this tx |
| Storage (warm) | 100 gas (SLOAD) | Slot already in access list this tx |

### 4. indexed vs data — the +115 gas question

A 32-byte value as non-indexed data costs ~260 gas. As an `indexed` topic it costs 375 gas — a net +115 gas for the privilege of bloom-filterability. Spend it only on fields that indexers actually query: addresses and IDs. Never index amounts or timestamps.

## Common Mistakes

- **`public` when `external` suffices.** `public` copies arguments to memory; `external` reads from calldata. For a large array, this is thousands of gas per call. Default to `external` for all user-facing functions.
- **No `indexed` on filterable fields.** Indexers can only filter on topics. An event with zero indexed params requires full log replay to find a specific address. Index addresses and IDs.
- **Event names not past tense.** `AcceptProbe` vs `ProbeAccepted` — the convention exists so event logs read as history, not as intent. Every event in Meridian is past tense.
- **Stack-too-deep error.** The compiler limits live stack slots to approximately 16. This is not a bug — it is a compiler constraint. Fixes: scope blocks `{}`, extract into structs, reduce return values, move work to internal helpers.
- **Sub-256 surprises in `unchecked` blocks.** `uint8(255) + 1` wraps to 0 in `unchecked`. If you use `unchecked` (Chapter 04 only, with proof), verify all intermediate values fit the type.
- **External calls in modifiers.** Invisible reentrancy surface. Meridian modifiers perform only `msg.sender` comparisons and storage reads — no `CALL` opcodes.
- **Loose `pragma`.** `pragma solidity >=0.8.0` allows any compiler ≥0.8.0. Different compilers produce different bytecode. Pin `^0.8.24`.
- **Missing events on state changes.** Every state-changing function must end in an event. Auditors file missing events as a finding; indexers are blind without them.
- **Storage reads inside loops.** Each iteration is a separate `SLOAD`. Cache the value once before the loop in a `memory` variable — then iterate.

## Exercises & Weekly Project

### Conceptual exercises

- **Translate:** Rewrite `ErrorProbe.probe` using `require` with a 60-character message. Predict the bytecode-size delta and deployment gas delta, then measure both in the lab. Document any discrepancy.
- **Design:** Write an `I`-prefixed interface for a `withdraw(uint256 amount)` function with three failure modes: insufficient balance, protocol paused, and amount zero. Include typed custom errors and the past-tense event.
- **Trace:** For `event Transfer(address indexed from, address indexed to, uint256 value)`, compute the full LOG gas cost using the formula above. Compare with the two balance `SSTORE`s the event describes. Express as a ratio.
- **Reason:** Why is a `mapping` illegal in `memory`? What would iteration over a memory mapping require that the EVM cannot provide at reasonable cost?
- **Audit:** List every convention violated by `probeLegacy` and compute the concrete cost (gas or bytes) of each violation. Use the numbers from the Gas Optimization section.

### Weekly Project — Meridian Style Guide + Error-Gas Evidence

> **Project 1.2 — extends Project 1.1** —  
> This project produces the three documents the rest of the curriculum references for convention compliance.

1. Write `docs/style-guide.md` — Chapters 01–02's locked conventions as a yes/no checklist. Every rule must be mechanically checkable: a reviewer answers yes or no with no judgment calls.
2. Draft `docs/error-catalog.md` — provisional error catalog for upcoming protocol contracts (`MeridianToken` Ch 14, `MeridianVault` Ch 20). For each error: name, typed params, invariant guarded. Chapter 14 finalizes the token errors.
3. Extend `docs/gas-model.md` (Project 1.1) with the error-convention table: measured custom-vs-string revert gas, deployment-size delta, indexed-vs-data math from the lab.
4. Commit on the `v0.1.0` milestone branch. Tag stays; Chapter 05 closes the module.

### Style guide checklist (start here)

- Custom errors only — no `require` strings in protocol code
- Every error declared in an `I`-prefixed interface
- Every error carries typed params with the offending values
- `assert` only for true mathematical invariants
- All events past tense
- All filterable fields (addresses, IDs) marked `indexed`
- Deploy-time constants declared `immutable`
- User-facing functions: `external` + `calldata` for array args
- Protocol-internal helpers: `internal` (not `private`)
- State mutations before external calls (CEI)
- Events after all state mutations
- Pinned pragma: `^0.8.24`
- No storage reads inside loops — cache first
- No external calls in modifiers

> **Success criteria** —  
> The checklist is mechanically checkable (each item is a yes/no). Error names follow the convention. The gas table in `docs/gas-model.md` reproduces the Gas Optimization numbers within 10%.

## Quiz

Tap a question to reveal the answer.

- **Q.** Why does uint8 arithmetic not save gas, and where do small types actually pay off? 
  **A.** The EVM has only 256-bit opcodes. The compiler sign/zero-extends a uint8 to 256 bits, performs the operation, then truncates — emitting more instructions than a uint256 operation would require. There is no gas saving in computation. Small types pay off only when packed into one storage slot (Chapter 06): multiple uint8 fields sharing a single 32-byte slot reduce SSTORE counts from N to 1.
- **Q.** What is the LOG gas formula, and what does indexed buy you over data? 
  **A.** LOG gas = 375 + 375 × topics + 8 × data_bytes + memory expansion. An indexed parameter moves a field into a topic at 375 gas instead of encoding it into data at ~260 gas (8 bytes × 32) — a net +115 gas premium. What you buy: bloom-filterability. Indexers and nodes can efficiently find events matching a specific topic value without replaying every log. Index what you query by; leave values you only read in data.
- **Q.** What exactly does revert AboveBound(bound, value) emit, and why is it better than a require string? 
  **A.** It emits the 4-byte selector of AboveBound(uint256,uint256) followed by the two ABI-encoded uint256 arguments — a total of 68 bytes. The client receives typed, decodable data and can render "value 101 exceeds bound 100" without any string parsing. Comparison: a 40-character require string costs ~8,000 gas at deployment (200 gas/byte × 40) and 40 bytes of the 24 KB EIP-170 budget; the custom error costs ~800 gas and 4 bytes. At runtime, the string path ABI-encodes Error(string) into memory before REVERT; the custom path pushes 4 bytes — approximately 70 gas cheaper per revert.
- **Q.** What are the three revert payload shapes in Solidity 0.8.24? 
  **A.** 1. Error(string) — selector 0x08c379a0 — produced by require(cond, "message"). The string is embedded in bytecode. 2. Custom errors — 4-byte selector derived from the error signature + ABI-encoded typed arguments. Available since 0.8.4. 3. Panic(uint256) — selector 0x4e487b71 — produced by internal failures: 0x11 arithmetic overflow, 0x12 division by zero, 0x01 failed assert, 0x32 array out of bounds. Clients must handle all three selectors separately to avoid silently missing error types.
- **Q.** What does an uninitialized storage pointer write to, and what is the rule that prevents it? 
  **A.** An uninitialized storage reference defaults to slot 0 — the first declared state variable in the contract. Writing through it silently corrupts that variable. This compiles without error or warning. The prevention rule: never declare a storage reference without assigning it to a specific slot. Use memory for temporaries. When you need a storage pointer, assign it immediately: MyStruct storage s = _structs[id];
- **Q.** What is the difference between external and public visibility in gas terms? 
  **A.** external functions read their arguments directly from calldata — no copy, no memory allocation. public functions copy their arguments to memory at the start of the function. For scalar types (uint256, address) the difference is small (~30–100 gas). For large dynamic types — a 1,000-element uint256[] array — the public memory copy costs approximately 4,953 gas from memory expansion alone, while the external calldata path costs ~0 for the copy. Always default to external for user-facing functions with array or bytes arguments.

## Further Reading

- Docs **Solidity docs — "Errors and the Revert Statement"** — canonical spec of all three revert payload shapes and custom error ABI encoding.
- Docs **Solidity docs — "Types"** — full type system specification including storage layout rules for value and reference types.
- Release **Solidity 0.8.4 release notes** — custom errors introduced. Read the motivation section for the exact gas accounting.
- Library **OpenZeppelin Contracts v5 — IERC20Errors.sol** — the error-catalog pattern Meridian copies. Read alongside ERC20.sol to see every error in use.
- EIP-170 **EIP-170** — 24 KB deployed code size limit. The budget that require strings bill against; the reason code size is tracked per convention.
- Security **Trail of Bits — "Uninitialized Storage Pointers" (2018)** — canonical write-up of the slot-0 corruption class. Short; worth reading in full.
- Tool **evm.codes — LOG / REVERT / PANIC pages** — opcode-level gas costs and stack effects. Verifies every number in this chapter.
- Reference **Consensys Diligence — "Ethereum Smart Contract Best Practices"** — the pre-0.8 manual version of what the compiler now enforces; useful for reading older contracts.
- Case study **Aave V3 Pool.sol** — mixed custom errors + require strings. Read as a negative example: count the typed vs opaque reverts and articulate why the mix is worse than either extreme.
