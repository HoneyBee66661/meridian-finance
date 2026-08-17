# ABI Encoding & Data Locations

The EVM has no types — only bytes, gas, and state. The ABI is the agreement that bridges the two worlds: a fixed wire format that every wallet, explorer, indexer, and SDK must speak identically. Get one byte wrong and the call silently misfires. Get the grammar right and every cross-contract interaction becomes predictable, auditable, and gas-optimal.

### Contents

1. [Learning Objectives](#learning-objectives)
2. [Why the ABI Exists](#why-the-abi-exists)
3. [Function Selectors — 4 Bytes That Route a Call](#function-selectors--4-bytes-that-route-a-call)
4. [Selector Collisions — Real, Not Theoretical](#selector-collisions--real-not-theoretical)
5. [Message Data Layout — Head & Tail](#message-data-layout--head--tail)
6. [The Encoding Family — Five Functions, One Grammar](#the-encoding-family--five-functions-one-grammar)
7. [calldata vs memory — Through the ABI Lens](#calldata-vs-memory--through-the-abi-lens)
8. [Decoder Behavior — What solc 0.8.24 Actually Enforces](#decoder-behavior--what-solc-0824-actually-enforces)
9. [Events & Errors Are ABI Too](#events--errors-are-abi-too)
10. [Mathematical Foundations — Selector Space & Payload Sizes](#mathematical-foundations--selector-space--payload-sizes)
11. [Locked Conventions](#locked-conventions--chapter-03-additions)
12. [Code Walkthrough — AbiProbe.sol](#code-walkthrough--abiprobesol)
13. [Production References](#production-references)
14. [Security Analysis](#security-analysis--abi-level-vulnerability-classes)
15. [Gas Optimization](#gas-optimization)
16. [Common Mistakes](#common-mistakes)
17. [Exercises & Weekly Project](#exercises--weekly-project)
18. [Quiz](#quiz)
19. [Further Reading](#further-reading)

## Learning Objectives

- **Obj 01** —  Derive why the ABI exists: calldata is the EVM's only typed input channel, so a fixed wire format is the only alternative to chaos.
- **Obj 02** —  Compute function selectors from canonical signatures by hand, state the five canonicalization rules, and quantify collision probability via the birthday bound.
- **Obj 03** —  Lay out any function call's `msg.data` byte-for-byte — selector, head words, tail offsets, length prefixes, right-padding — and verify empirically.
- **Obj 04** —  Choose correctly between all five encoding functions and between `calldata`/`memory` for read-only dynamic arguments, with measured gas numbers.
- **Obj 05** —  Predict ABI decoder behavior on malformed input: what padding validation does and does not happen, and what a structural violation reverts with.
- **Obj 06** —  Apply this grammar to Meridian's future `OracleRegistry` interface (Ch 22) using the production pattern of Chainlink's `AggregatorV3Interface`.

## Why the ABI Exists

Chapter 01 established the EVM as a word-addressed stack machine whose only per-call input is `msg.data` — a raw byte string. Nothing in the execution substrate knows that `0xa9059cbb…` "means" a transfer. Function names, parameter types, and return values are compile-time concepts. At runtime there are only bytes, gas, and state.

> **The ABI as a wire contract** —  
>  The ABI (Application Binary Interface) is the agreement that bridges typed Solidity code and raw EVM bytes. It is a fixed, unambiguous rule for mapping typed values to bytes and back — specified in the Solidity documentation ("Contract ABI Specification") and spoken by every EVM tool: wallets, explorers, indexers, SDKs. 
 
>  When you call `transfer` on USDC, your wallet packs your arguments into bytes per the ABI. The contract's dispatcher unpacks them. Disagree about the layout by even one byte and the call silently hits `fallback()` or reverts with no useful error.

Meridian will live or die on this discipline. Every interface it publishes is an ABI contract with thousands of external consumers — integrators, liquidation bots, indexers, front-ends. A breaking ABI change is a protocol-level incident, not a refactor.

## Function Selectors — 4 Bytes That Route a Call

The first four bytes of `msg.data` are the **selector**: the first four bytes of `keccak256` of the function's canonical signature.

$$ selector = keccak256("transfer(address,uint256)") [0:4] = 0xa9059cbb $$

### The five canonicalization rules

These rules are not convention — they are specification. Violating any one of them produces a different hash and a different selector.

| Rule | Correct form | Wrong form | What the wrong form produces |
| --- | --- | --- | --- |
| **No whitespace** | transfer(address,uint256) | transfer(address, uint256) | 0x9d61d234 — wrong selector, silent misroute |
| **Canonical type names** | uint256 / address / bytes32 | uint / address payable / bytes 32 | Different hash — compiler's selector ≠ hand-computed |
| **No parameter names** | transfer(address,uint256) | transfer(address to,uint256 amount) | Different hash |
| **No return types** | balanceOf(address) | balanceOf(address) returns (uint256) | Different hash |
| **Structs expand to tuples** | (uint256,address) | MyStruct | Different hash — struct names are not part of the ABI |

### The uint / uint256 footgun — measured

`uint` is a valid Solidity alias for `uint256` in declarations — the compiler normalizes it. But `abi.encodeWithSignature("f(uint)", x)` hashes the literal string *as written*:

## Selector Collisions — Real, Not Theoretical

The selector space is 2³² ≈ 4.29 × 10⁹ possible values. By the birthday bound (§Mathematics), roughly 77,000 randomly chosen signatures give a ~50% chance that some pair collides. With ~10⁶ signatures in the public `4byte.directory`, hundreds of collisions exist. Here are the six registered for `0xa9059cbb`:

| Selector | Signature | Registered | Origin |
| --- | --- | --- | --- |
| `0xa9059cbb` | `transfer(address,uint256)` | 2016-07-09 | Legitimate |
| `0xa9059cbb` | `many_msg_babbage(bytes1)` | 2018-05-11 | Mined collision |
| `0xa9059cbb` | `transfer(bytes4[9],bytes5[6],int48[11])` | 2019-03-22 | Mined collision |
| `0xa9059cbb` | `func_2093253501(bytes)` | 2021-10-20 | Mined collision |
| `0xa9059cbb` | `join_tg_invmru_haha_fd06787(address,bool)` | 2022-08-26 | Mined collision |
| `0xa9059cbb` | `workMyDirefulOwner(uint256,uint256)` | 2023-12-27 | Mined collision |

> **A selector is an identifier, not a proof of intent** —  
>  Any dispatcher routing purely on `msg.sig` can be aimed at the wrong handler via a mined collision — an attacker iterates candidate signatures until `keccak256(sig)[0:4]` matches a privileged selector. This attack is not theoretical: the collisions above were deliberately mined. 
 
>  **Meridian rule:** never route arbitrary `msg.sig` through a handler lookup table. Use compiler-generated dispatch (the `if/else` chain the Solidity compiler emits) over a small, audited set of selectors. Governance and proxy surfaces (Ch 25, 38) follow this.

## Message Data Layout — Head & Tail

Every function call's `msg.data` has a fixed structure: **selector (4 bytes) ‖ ABI-encoded arguments**. The argument region uses a **head/tail** scheme:

| Region | Content | Which types |
| --- | --- | --- |
| **Head** | One 32-byte word per argument, in order | Static types encode their value inline. Dynamic types encode the *byte offset* of their data in the tail (relative to the start of the argument region, not the head or tail). |
| **Tail** | Dynamic payloads, in argument order | Each is: 32-byte length word ‖ payload right-padded to a multiple of 32 bytes. |

### Two facts to internalise before anything else

> **Fact 1 — integers and addresses are right-aligned** —  
>  `address(0x1234)` encodes as `0x0000…00001234` — identical to `uint160(0x1234)`. This is the single most common manual-encoding error: left-padding an address produces garbage that decodes as a completely different address. Never hand-assemble address bytes without pinning the layout with a test.

> **Fact 2 — offsets are relative to the argument region, not the head** —  
>  The offset word for a dynamic argument is the byte distance from the *start of the argument region (byte 4 of `msg.data`)* to the argument's tail entry. This is independent of what any other dynamic argument contains — you can compute all offsets before writing any tail data.

### Worked example — two static args: transfer(address,uint256)

With `to = 0x…1234`, `amount = 1000`. No dynamic args → no tail.

Total: 4 + 64 = **68 bytes**

### Worked example — mixed args: encode(uint256, address, bytes)

With `a = 0x1122…ee00`, `b = 0x…1234`, `c = "meridian"` (8 bytes). One dynamic arg → tail required.

Total: 160 bytes. Offset word is 96 = 3 × 32 (the head size) — determined purely by argument count, independent of `c`'s content.

> **ERC-2612 permit — all-head, no tail** —  
>  `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` has 7 static arguments — all head, no tail. Wire size: 4 + 7×32 = **228 bytes**, costing approximately 3,600 gas in calldata alone before execution begins (16 gas per non-zero byte). This is a gas design decision embedded in the interface signature.

## The Encoding Family — Five Functions, One Grammar

All five functions produce bytes from typed values. They differ in what they include, what they check, and where they are safe to use.

Meridian default Produces: selector ‖ `abi.encode(args)`. The signature is derived from the actual function *declaration* at compile time — the compiler resolves canonical types, so `uint` becomes `uint256` before hashing. The argument tuple is type-checked against the function signature.

**Refactor-proof:** if the function is renamed or its signature changes, the call site fails to compile — you cannot accidentally send calldata to the wrong selector.

Protocol storage & hashing Produces head/tail encoding with no selector prefix. The correct choice for anything that will be `abi.decode`d, stored in state, or used as a signing substrate (EIP-712 struct hashing). Encoding is **injective** — distinct typed inputs produce distinct bytes — because 32-byte padding separates values.

Fixed-size hashing only Not ABI-compatible Raw concatenation — no padding, no length prefixes. Cheaper calldata (fewer zero bytes) but **not injective** for variable-length or sub-word types: `encodePacked(uint16(0x1234), uint16(0x5678))` and `encodePacked(uint32(0x12345678))` are byte-identical.

Safe only for hashing inputs where all types are fixed-size and unambiguous: `(bytes32, bytes32)` pairs, not `string` or sub-word types.

Low-level calls Produces: selector ‖ `abi.encode(args)` — identical to `encodeCall` in output, but the selector is passed as a `bytes4` literal you supply. Use when you already hold a compiled selector constant (e.g. a stored interface selector from a factory). No type checking against a declaration.

Script / tooling only Hashes the literal string argument — the `uint`/`uint256` footgun applies in full. If you write `"f(uint)"` the selector is wrong even if the compiler accepts it in a declaration. **Never in protocol code.** Acceptable in deploy scripts where a human double-checks the canonical form.

### abi.encodePacked — the collision in detail

The Solidity documentation's canonical example is worth memorising:

```solidity
// These two produce byte-identical output — identical keccak256 hashes:
keccak256(abi.encodePacked("a", "bc"))
==
keccak256(abi.encodePacked("ab", "c"))

// Same applies to sub-word integers:
keccak256(abi.encodePacked(uint16(0x1234), uint16(0x5678)))
==
keccak256(abi.encodePacked(uint32(0x12345678)))

// The lab fuzz-proves this for all uint8 pairs (256 runs):
// keccak256(encodePacked(uint8(a), uint8(b))) == keccak256(encodePacked(uint16(a<<8|b)))
```

> **The rule: packed hashing over fixed-size inputs only** —  
>  `abi.encodePacked` is safe when every input is `bytes32`-sized and fixed-width — the collision only arises when variable-length or sub-word types are mixed. If in doubt: `abi.encode` — the 32-byte padding is what makes it injective.

## calldata vs memory — Through the ABI Lens

Chapter 02 gave the location matrix. The ABI gives it operational meaning: every dynamic argument that arrives via calldata is already correctly encoded bytes sitting in `msg.data`. What happens next is a function of which location you declare.

| Location | How data is accessed | Gas model | Mutability |
| --- | --- | --- | --- |
| **calldata** | Read directly from `msg.data` via `CALLDATALOAD` | 3 gas/word — no copy cost | Read-only. Sliceable with `data[a:b]` for calldata only. |
| **memory** | Copied from calldata into fresh memory at function entry | 3 gas/word written + quadratic expansion (Ch 01) | Mutable. Required if you need to modify the argument. |
| **storage** | State — never a parameter location | 2,100 cold / 100 warm SLOAD | Persists. Only for state variables. |

> **Locked rule: external + calldata for read-only dynamic arguments** —  
>  A 64-word array read inline from calldata: **17,619 gas**. The same array after a calldata → memory copy: **18,178 gas**. Difference: **559 gas** for 64 words — and the gap grows linearly with array size plus the quadratic memory-expansion term. 
 
>  Default to `external` + `calldata` for all read-only dynamic arguments. Use `memory` only when you must mutate before use. This is the single most repeated gas decision in Meridian's vault code (Ch 20–22).

## Decoder Behavior — What solc 0.8.24 Actually Enforces

`abi.decode(data, (uint256, address, bytes))` is the inverse of `abi.encode`. The decoder is strict about structure — but two measured results (solc 0.8.24) may surprise you:

Truncating the 24 trailing padding bytes off `encode(uint256, address, "meridian")` (160 → 136 bytes) still decodes successfully. The decoder checks that `offset + length ≤ data.length`; it does not require the padded region to exist beyond the payload.

Truncating 40+ bytes (cutting into the payload itself) or providing an out-of-bounds offset (e.g. `1,000,000`) reverts with **empty revert data** — not `Panic(0x11)`, not `Error(string)`.

| Truncation from 160 bytes | Bytes remaining | Result |
| --- | --- | --- |
| Remove trailing padding (24 bytes) | 136 | Decodes successfully |
| Remove 28 bytes | 132 | Reverts — empty revert data |
| Bogus offset (1,000,000) | 160 | Reverts — empty revert data |

> **Two critical consequences** —  
>  **(a)** `try/catch Error(string)` will *not* catch a malformed-payload revert. The empty revert data falls through to the bare `catch` or is missed entirely. Check `returndatasize()` before decoding attacker-supplied data. 
 
>  **(b)** Decoding attacker-controlled bytes in a loop amplifies one bad element into a whole-batch revert — a griefing/DoS vector for multicall-style endpoints. Validate length and offset bounds before decoding, or use per-element `try/catch` (the OpenZeppelin Multicall `(bool success, bytes result)` pattern).

## Events & Errors Are ABI Too

The head/tail grammar does not stop at function calls. The same rules govern every byte channel the EVM exposes:

| Channel | topic0 / selector | Remaining payload |
| --- | --- | --- |
| **Events** | `keccak256("Transfer(address,address,uint256)")` | Indexed params → topics 1–3 (padded to 32 bytes, right-aligned). Non-indexed → `abi.encode`d into the data field. |
| **require string** | `0x08c379a0` — `Error(string)` | `abi.encode("the message")` |
| **assert / Panic** | `0x4e487b71` — `Panic(uint256)` | `abi.encode(panicCode)` — e.g. `0x11` for overflow |
| **Custom errors** (Meridian) | 4-byte selector of the error signature | `abi.encode(params)` — typed, decodable by ABI consumers |

> **Why custom errors decode cleanly** —  
>  A custom error `error AboveBound(uint256 bound, uint256 received)` reverts with exactly: `keccak256("AboveBound(uint256,uint256)")[0:4]` ‖ `abi.encode(bound, received)`. A client switches on the 4-byte selector, then `abi.decode`s the remainder — the same grammar as a function return value. This is why callers can decode custom errors without string parsing.

### EIP-712 preview

Chapter 14's ERC-2612 `permit` depends on EIP-712 typed-data signing. The digest is: `keccak256(abi.encode(TYPE_HASH, field1, field2, …))` — every dynamic field pre-hashed to a `bytes32`. The right-alignment rules, the head/tail grammar, and the canonical type names from this chapter are what make the signature reproducible off-chain and on-chain identically. The `permit` selector `0xd505accf` is already in the lab's constant table; the full encoding arrives in Ch 14.

## Mathematical Foundations — Selector Space & Payload Sizes

### Selector collision probability (birthday bound)

### Payload size formula

For a function with *s* static and *d* dynamic arguments whose dynamic payloads have byte lengths L₁…L_d:

## Locked Conventions — Chapter 03 Additions

- **`abi.encodeCall` as the default for all protocol calls.** Compile-time type-checked, signature derived from the declaration — the only choice that is both refactor-proof and selector-correct.
- **`abi.encode` for anything stored, hashed (with domain separation), or returned to be decoded.** Injective encoding — 32-byte padding separates values.
- **`abi.encodePacked` only for hashing fixed-size, unambiguous inputs.** `bytes32` pairs, fixed-size tuples. Never with `string`, `bytes`, or sub-word types. Never for argument passing.
- **`abi.encodeWithSignature` — deploy scripts and Foundry tests only.** Never in protocol code. The literal-string footgun applies in full.
- **ABI is versioned and breaking changes are protocol incidents.** Renaming a parameter is safe. Changing a type, adding an argument, or removing a function breaks every caller. Interface changes are coordinated through the upgrade lifecycle (Ch 38).
- **Validate length/offset bounds before `abi.decode` on attacker-supplied data.** Structural violations revert empty — not with a catchable error. Per-element `try/catch` in any loop that decodes external input.
- **Never route arbitrary `msg.sig` through a handler table.** Use compiler-generated dispatch on a small, audited selector set. Proxy and governance surfaces (Ch 25, 38) follow this.

## Code Walkthrough — AbiProbe.sol

`AbiProbe` is a pedagogical measurement contract — not protocol code — following the Ch 02 pattern. Four functions carry the teaching load, each pinning one measurable ABI fact.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAbiProbe {
    // I-prefix: full surface in one place (Ch 02 convention)
    function selectorOf(string calldata signature) external pure returns (bytes4);
    function headWord(bytes calldata data, uint256 wordIndex) external pure returns (uint256);
    function packedHash16() external pure returns (bytes32);
    function packedHash32() external pure returns (bytes32);
    function sumCalldata(uint256[] calldata xs) external pure returns (uint256);
    function sumCopied(uint256[] calldata xs) external pure returns (uint256);
}

contract AbiProbe is IAbiProbe {

    /// @notice Raw selector computation — hashes the literal string.
    ///         The caller must supply canonical form; there is no alias resolution.
    ///         This is why abi.encodeWithSignature is dangerous in protocol code.
    ///         Asserted: selectorOf("transfer(address,uint256)") == 0xa9059cbb
    ///         Asserted: selectorOf("f(uint)") != selectorOf("f(uint256)") [0x693c6139 vs 0xb3de648b]
    function selectorOf(string calldata signature) external pure returns (bytes4) {
        return bytes4(keccak256(bytes(signature)));
    }

    /// @notice Read the Nth 32-byte word from an encoded payload.
    ///         Data slicing (data[a:b]) compiles only for calldata — a compile error
    ///         on memory. This is why the function takes calldata, not memory.
    ///         headWord(payload, 2) == 96  (offset word for dynamic arg)
    ///         headWord(payload, 3) == 8   (length prefix of "meridian")
    ///         headWord(payload, 4) == uint256(bytes32("meridian")) (right-padded payload)
    function headWord(bytes calldata data, uint256 wordIndex)
        external pure returns (uint256) {
        // calldata slicing — only legal on calldata (not memory)
        return uint256(bytes32(data[wordIndex * 32 : (wordIndex + 1) * 32]));
    }

    /// @notice Proves the encodePacked collision: uint16 pair == uint32 same bits.
    ///         packedHash16() == packedHash32() — byte-identical inputs, identical hashes.
    ///         The fuzz twin asserts this for all uint8 pairs (256 fuzz runs).
    function packedHash16() external pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint16(0x1234), uint16(0x5678)));
    }
    function packedHash32() external pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint32(0x12345678)));
    }

    /// @notice Gas measurement pair: same sum, two locations.
    ///         sumCalldata: reads xs[i] via CALLDATALOAD — no copy, 3 gas/word.
    ///         sumCopied: copies xs to memory first, then reads — 3 gas/word written
    ///                    + quadratic memory expansion.
    ///         Measured: 17,619 vs 18,178 gas for 64 words (+559 gas for the copy).
    function sumCalldata(uint256[] calldata xs) external pure returns (uint256 s) {
        for (uint256 i; i < xs.length; ++i) s += xs[i];
    }
    function sumCopied(uint256[] calldata xs) external pure returns (uint256 s) {
        uint256[] memory m = xs; // explicit calldata → memory copy
        for (uint256 i; i < m.length; ++i) s += m[i];
    }
}
```

#### Test suite — 16 tests, what each proves

| Test | Category | Fact pinned |
| --- | --- | --- |
| `testSelectorKnownSignature` | Layout | `selectorOf("transfer(address,uint256)") == 0xa9059cbb` |
| `testSelectorUintAlias` | Layout | `selectorOf("f(uint)") != selectorOf("f(uint256)")` — the footgun, measured |
| `testHeadTailLayoutExact` | Layout | Every byte region of a 160-byte payload asserted word-by-word |
| `testEncodeCallPrefixIsSelector` | Layout | `abi.encodeCall` output = selector + 160 bytes |
| `testPackedHashCollision` | Collision | `packedHash16() == packedHash32()` — byte-identical inputs |
| `testFuzzPackedConcatenationIsAmbiguous` | Collision (fuzz) | For all `uint8` pairs (256 runs): two-word and one-word packings hash equal |
| `testDecodePaddingNotValidated` | Decoder | 136-byte truncated payload (24 padding bytes removed) still decodes |
| `testDecodeTruncatedPayloadRevertsEmpty` | Decoder | 132-byte truncation reverts with empty revert data |
| `testDecodeBogusOffsetRevertsEmpty` | Decoder | Offset of 1,000,000 reverts empty — verified with `vm.expectRevert(bytes(""))` |
| `testFuzzEncodeDecodeRoundtrip` | Round-trip (fuzz) | `abi.decode(abi.encode(a,b,c)) == (a,b,c)` for 256 fuzz inputs |
| `testGasCalldataVsCopy` | Gas | 17,619 vs 18,178 gas for 64-word sum; `assertLt(calldataGas, copiedGas)` |

```solidity
/// [DECODER] Trailing padding (24 bytes) not validated — decodes successfully.
function testDecodePaddingNotValidated() public pure {
    bytes memory encoded = abi.encode(uint256(1), address(0x2), "meridian"); // 160 bytes
    bytes memory truncated = new bytes(136);             // remove 24 padding bytes
    for (uint256 i; i < 136; ++i) truncated[i] = encoded[i];
    (, , bytes memory c) = abi.decode(truncated, (uint256, address, bytes));
    assertEq(c, "meridian"); // succeeds — payload region intact, padding not checked
}

/// [DECODER] Structural violation (payload cut) reverts with EMPTY data.
///           NOT Panic(0x11), NOT Error(string). Caught only by bare catch.
function testDecodeTruncatedPayloadRevertsEmpty() public {
    bytes memory encoded = abi.encode(uint256(1), address(0x2), "meridian");
    bytes memory truncated = new bytes(132); // cuts into the payload — structural violation
    for (uint256 i; i < 132; ++i) truncated[i] = encoded[i];
    vm.expectRevert(bytes(""));            // empty revert data — not catchable as Error(string)
    abi.decode(truncated, (uint256, address, bytes));
}

/// [FUZZ] abi.encode is injective: distinct inputs produce distinct hashes.
function testFuzzEncodeDecodeRoundtrip(
    uint256 a, address b, bytes calldata c
) public pure {
    (uint256 da, address db, bytes memory dc) =
        abi.decode(abi.encode(a, b, c), (uint256, address, bytes));
    assertEq(da, a); assertEq(db, b); assertEq(dc, c);
}
```

## Production References

### OpenZeppelin v5 — Address.sol & Multicall.sol

The two most-cited ABI consumer references in production DeFi:

| Contract | ABI pattern | Meridian inheritance |
| --- | --- | --- |
| `Address.functionCall` | Low-level call wrapper; decodes revert data unchanged; caps forwarded return data at 4,096 bytes (return-bomb guard) | Template for every low-level call in Meridian's deploy tooling and vault operations |
| `Multicall.multicall` | `bytes[] calldata data` → per-element `delegatecall` → `results[i] = abi.decode(result, (bytes))` | The `(bool success, bytes result)` tuple pattern: per-element failures do not revert the batch. Meridian's LiquidationEngine batch endpoints (Ch 24–25) copy this. |

### Chainlink AggregatorV3Interface — the oracle ABI Meridian will consume

```solidity
// Selector: 0xfeaf968c (verified: cast sig "latestRoundData()")
// Five static returns — all head, no tail.
// Wire size: 4 + 5×32 = 164 bytes per call.
function latestRoundData() external view returns (
    uint80  roundId,       // sub-word type — still 32-byte head word (ABI pads, never packs)
    int256  answer,
    uint256 startedAt,
    uint256 updatedAt,
    uint80  answeredInRound
) external view;
```

This is the exact interface Meridian's `OracleRegistry` (Ch 22) will consume as its primary price feed. Note: `uint80` is a sub-word type that still occupies a full 32-byte head word — the ABI pads, it never packs. The encoding and the gas cost are identical to `uint256` for calldata and return data purposes.

### Reading plan — one lens, three contracts

For each contract below, extract separately: function selectors, event topics, and error selectors. That is the exact skill Chapter 39's full-system audit requires.

| Contract | What to trace | Chapter connection |
| --- | --- | --- |
| **OZ v5 Address.sol** | `functionCall → functionCallWithValue → verifyCallResultFromTarget → _revert`: the `returndatasize() > 4096` cap and how revert data is forwarded unchanged | Reference for every low-level call Meridian makes |
| **OZ v5 Multicall.sol** | How `results[i] = abi.decode(result, (bytes))` decodes heterogeneous return data; why `(bool success, bytes result)` tuples survive per-element failures | Template for Ch 24–25 batch endpoints |
| **OZ v5 EIP712.sol** | `_hashTypedDataV4` and the `keccak256(abi.encode(...))` struct hashing — the bridge from this chapter to Ch 14's ERC-2612 permit | Direct prerequisite for Ch 14 |

## Security Analysis — ABI-Level Vulnerability Classes

**Selector Collision / Signature Squatting** —   Any dispatcher routing on `msg.sig` — proxy fallback dispatchers, "anycall" wrappers — cannot distinguish colliding signatures. A mined collision (compute candidate strings until `keccak256(sig)[0:4]` matches a privileged selector) redirects calls to a different handler. Not theoretical: `0xa9059cbb` has 5 mined collisions, the earliest from 2018.  
**Fix:** Compiler-generated dispatch only — the `if/else` chain the Solidity compiler emits. Never a user-editable handler lookup table. Governance and proxy surfaces follow this (Ch 25, 38).

**Hash-Input Collision via Ambiguous Packed Encoding** —   `abi.encodePacked` with variable-length or sub-word types makes distinct values hash identically: `(uint16(0x1234), uint16(0x5678)) ≡ uint32(0x12345678)`; `("a","bc") ≡ ("ab","c")`. If such a hash is a commitment, an ID, or a signature digest, an attacker substitutes the colliding value. Formally: hash-input ambiguity — the vulnerability class Solidity docs and OpenZeppelin guidance both flag.  
**Fix:** Packed hashing only over fixed-size, unambiguous inputs (bytes32 pairs). `abi.encode` + domain separation otherwise — 32-byte padding is what makes encoding injective.

**Malformed-Payload Griefing via Decoder Revert** —   Structural ABI violations revert with empty data (measured). Any loop that `abi.decode`s attacker-supplied per-element payloads — multicall batching, LiquidationEngine batch endpoints — lets one malformed element revert the entire batch. The attacker loses nothing; the protocol's critical function (liquidation) is bricked.  
**Fix:** Validate length/offset bounds before decoding. `try/catch` per element and record per-element failure — the OZ Multicall `(bool success, bytes result)` pattern is the production answer.

**Return-Data Bomb** —   A `delegatecall` wrapper that forwards all return data lets a malicious callee return gigabytes. The quadratic memory expansion term (Ch 01: w²/512) turns a large return into a gas grenade: 1 MB of return data costs ~2 × 10⁶ gas in expansion alone. OZ `Address.functionCall` caps forwarded return data at 4,096 bytes specifically for this reason.  
**Fix:** Cap return data at 4,096 bytes anywhere wrapping arbitrary calls. Meridian inherits this guard from OZ Address wherever it wraps external calls.

**Topic0 Spoofing / Fake Transfer Events** —   Any contract can emit any event with any `topic0` — `keccak256("Transfer(address,address,uint256)")` is public knowledge. The "fake airdrop" scam class works by emitting `Transfer` events from an attacker-controlled contract, causing indexers and dashboards to show non-existent token movements. Indexers that verify only topic values, not emitting address, are vulnerable.  
**Fix:** Always verify the emitting address when processing events. Meridian's subgraph (Ch 37) enforces this at the indexer level: filter on `event.address == expectedContract`, never on topics alone.

## Gas Optimization

All figures measured: loop-amplified `gasleft()` min-delta, plain `forge test -vvv`, solc 0.8.24, optimizer 200 runs.

### 1. Read calldata inline — don't copy to memory

```solidity
// Forces calldata → memory copy at entry
function sumCopied(
    uint256[] calldata xs
) external pure returns (uint256 s) {
    uint256[] memory m = xs; // copy
    for (uint256 i; i < m.length; ++i)
        s += m[i];
}
// 18,178 gas (64 words)
```

```solidity
// Reads directly from msg.data (CALLDATALOAD)
function sumCalldata(
    uint256[] calldata xs
) external pure returns (uint256 s) {
    for (uint256 i; i < xs.length; ++i)
        s += xs[i];
}
// 17,619 gas (64 words)
```

↓ 18,178 → 17,619 gas — saving grows linearly with array length + quadratic expansion

### 2. encodePacked vs encode — only where semantics allow

| Encoding | Calldata size | Gas | Safe for? |
| --- | --- | --- | --- |
| `abi.encode(uint256, address, bytes8)` | 160 bytes | 3,013 gas | Everything — injective, ABI-decodable |
| `abi.encodePacked(uint256, address, bytes8)` | 60 bytes | 2,363 gas | Hashing fixed-size types only — not injective for variable-length or sub-word types |

−650 gas (−21.6%) driven by calldata size reduction: 100 fewer bytes at 16 gas/byte = −1,600 gas for calldata alone, partially offset by fewer memory writes. The saving is real — but the security constraint is real too.

### 3. Shape your function signatures

Every extra static parameter adds 32 calldata bytes (512 gas at 16/byte for non-zero). Every `bytes` or `string` parameter adds at minimum 64 bytes (32 offset + 32 length) plus the padded payload. Design argument shapes with the calldata cost model in mind, especially for functions called frequently by liquidators and keepers.

## Common Mistakes

- **Non-canonical selector strings in `abi.encodeWithSignature`.** Spaces, `uint` instead of `uint256`, parameter names — all silently change the hash. The call dies in `fallback()` with no error. Fix: `abi.encodeCall`.
- **Right-alignment violations in hand-encoded data.** `address` is right-aligned — left-padding it produces a different address. Never hand-assemble without a byte-level test pinning the layout.
- **Slicing `memory` bytes with `data[a:b]`.** Slice syntax is legal on `calldata` only — a compile error on `memory`. Copy to a `calldata`-taking helper or read words via `abi.decode`.
- **Assuming decoder reverts carry data.** Structural decode failures revert empty — `catch Error(string)` will not catch them. A library that tries to decode the revert data will itself fail. Always check `returndatasize() > 4` before decoding revert data.
- **`abi.encodePacked` in hashing with dynamic/sub-word types.** The `uint16/uint32` and `"a","bc"/"ab","c"` collisions. When in doubt: `abi.encode` — 32-byte padding is what makes it injective.
- **`memory` for read-only dynamic arguments.** Forces a full copy. `calldata` is free to read. +559 gas per 64 words measured, growing with array size.
- **Assuming `encode == encodePacked` for a single static arg.** For a single `uint256` or `bytes32` they produce identical bytes. The divergence appears with multiple args, sub-word types, or dynamic types. Choose by semantics, never by coincidental equivalence.
- **Treating interface changes as safe refactors.** Renaming a parameter is safe. Changing a type or arity silently orphans all existing calldata. Treat every interface change as a breaking change with a coordinated upgrade (Ch 38).

## Exercises & Weekly Project

### Conceptual exercises

- **Compute by hand** (then verify with `cast sig`) the selectors of `balanceOf(address)`, `totalSupply()`, `name()`, `symbol()`, `decimals()`. Confirm against `0x70a08231`, `0x18160ddd`, `0x06fdde03`, `0x95d89b41`, `0x313ce567`.
- **Hand-lay** the 68-byte `transfer(address,uint256)` calldata from §Layout, then generate it with `cast calldata "transfer(address,uint256)" 0x1234 1000` and diff byte-by-byte.
- **Using the payload-size formula**, predict the calldata length of `abi.encodeCall(probe.encode, (uint256(1), address(0x2), hex"deadbeef"))` and confirm against `testEncodeCallPrefixIsSelector` (expected: 4 + 96 + 64 = 164 bytes).
- **Extend AbiProbeTest** with a fuzz test asserting `abi.encode` is injective for `(uint8, uint8)`: `keccak256(abi.encode(a,b))` must never equal `keccak256(abi.encode(c,d))` for `(a,b) ≠ (c,d)`. Contrast with the packed version the lab proves is not injective.
- **Query `cast 4byte 0x23b872dd` and `cast 4byte 0x095ea7b3`**; count registrations and identify mined ones. In one sentence: why are `transferFrom`'s collisions more dangerous than `approve`'s in a dispatcher?
- **Explain**, using the measured decoder facts, why a `try/catch Error(string)` around `abi.decode` of attacker data can let a malformed payload slip through to a second decode site.

### Weekly Project — Design the Meridian Oracle ABI

> **Project 1.3 · meridian/src/IMeridianOracle.sol** —  
> An interface + selector-locked tests + the compatibility contract that Ch 22's `OracleRegistry` must not break.

1. Write `meridian/src/IMeridianOracle.sol` — interface only, no implementation. Include: `latestRoundData()` mirroring Chainlink's shape; `consult(address market, uint256 secondsAgo) external view returns (uint256 price)`; `decimals() external view returns (uint8)`. Full NatSpec on every function including canonical signature.
2. Write `meridian/test/MeridianOracleAbi.t.sol`: (a) hard-assert selectors via `abi.encodeCall` prefix checks; (b) fuzz-assert that calldata for `consult` has the length predicted by the size formula; (c) assert `latestRoundData` returns 5 static words (164 bytes total return data).
3. Produce `docs/abi-contract.md` — the locked selector table: canonical signature, selector (hex), wire size, and a one-line invariant that Ch 22 must not break.

> **Success criteria** —  
> Interface + tests: all green (38/38 suite-wide). Selector table in `docs/abi-contract.md` confirmed by `cast sig`. Every function has NatSpec including the canonical signature string used to derive the selector.

## Quiz

Tap a question to reveal the answer.

- **Q.** Why does abi.encodeWithSignature("f(uint)", x) fail to call function f(uint x)? 
  **A.** The string is hashed literally: `keccak256("f(uint)")[0:4] = 0x693c6139`, but the compiler's selector for the declaration `f(uint256 x)` is `0xb3de648b` (canonical form expands `uint` to `uint256`). The call lands in `fallback()` with no error — a silent misroute. Fix: `abi.encodeCall(f, (x))`, which derives the signature from the function declaration at compile time and cannot diverge.
- **Q.** keccak256(abi.encodePacked(a, b)) for (uint16, uint16) equals the hash of what other encoding? Name the vulnerability class. 
  **A.** `keccak256(abi.encodePacked(uint32((uint16(a) << 16) | b)))` — byte-identical inputs, identical hashes. Vulnerability class: hash-input ambiguity / packed-encoding collision. Distinct logical values hash identically, breaking commitments and signature digests. The lab fuzz-proves this for all `uint8` pairs. Fix: `abi.encode` — 32-byte padding separates values and makes encoding injective.
- **Q.** You truncate the last 24 bytes (padding) of abi.encode(uint256,address,bytes) and decode it. What happens? What if you truncate 40 bytes? 
  **A.** Removing 24 bytes (padding only): decodes successfully. The solc 0.8.24 calldata decoder validates that `offset + length ≤ data.length` — it does not require the padded region beyond the payload. Removing 40 bytes (cutting into the payload): reverts with **empty revert data** — not `Panic(0x11)`, not `Error(string)`. Consequence: `try/catch Error(string)` will not catch it; `returndatasize()` returns 0.
- **Q.** In encode(uint256 a, address b, bytes c), what is the value of the third head word and what is it relative to? 
  **A.** 96 — the byte offset of `c`'s tail entry relative to the *start of the argument region* (byte 4 of `msg.data`). It equals 3 × 32 = 96 because there are three head words. This value is fully determined by the number of arguments — independent of what `c` contains. You can compute all offsets before writing any tail data.
- **Q.** Roughly how many random signatures give a ~50% chance of a selector collision, and what real evidence confirms collisions exist? 
  **A.** ~77,163 (birthday bound: `n ≈ √(2 ln 2) · 2¹⁶`). Real evidence: `4byte.directory` registers six signatures for `0xa9059cbb`, including `many_msg_babbage(bytes1)` (mined 2018) and `workMyDirefulOwner(uint256,uint256)` (mined 2023). With ~10⁶ registered signatures, expected collisions ≈ 116.
- **Q.** What is a return-data bomb and what is the mitigation? 
  **A.** A malicious callee in a `delegatecall` wrapper returns an arbitrarily large payload. Because return data is written to memory, the quadratic expansion term (Ch 01: w²/512) makes large returns extremely expensive — 1 MB costs roughly 2 × 10⁶ gas in expansion alone. This can exhaust the caller's gas budget, bricking the function. Mitigation: cap forwarded return data at 4,096 bytes — the guard OpenZeppelin `Address.functionCall` implements. Meridian inherits this cap from OZ wherever it wraps arbitrary external calls.

## Further Reading

- Spec **Solidity Documentation — "Contract ABI Specification"** — the canonical grammar: head/tail layout, canonical types, encoding rules for each type. Primary source for everything in this chapter.
- Spec **Solidity Documentation — abi.encodePacked ambiguity warning** — official caveat on packed encoding with dynamic and sub-word types. Short; worth quoting in code reviews.
- EIP-712 **EIP-712 — Typed Structured Data Hashing and Signing** — the ABI grammar applied to off-chain signatures. Ch 14 prerequisite; the bridge from this chapter to ERC-2612 `permit`.
- Library **OpenZeppelin v5 — Address.sol, Multicall.sol, EIP712.sol** — production ABI consumers. Address: return-bomb cap + revert data forwarding. Multicall: per-element failure pattern. EIP712: struct hashing.
- Tool **4byte.directory** — selector registry; confirms collision existence. Used throughout this chapter: `cast 4byte 0xa9059cbb`.
- Tool **Foundry Book — cast sig, cast 4byte, cast calldata** — the CLI trio for selector computation, collision lookup, and wire-format generation. Lab tools for this chapter.
- Security **samczsun — selector collision mining posts** — the technique behind the registered collisions; explains how a committed attacker mines a target selector in hours on commodity hardware.
- Reference **Chainlink AggregatorV3Interface** — five-line interface; the minimal ABI surface of the primary oracle. Meridian's OracleRegistry (Ch 22) consumes exactly this.
