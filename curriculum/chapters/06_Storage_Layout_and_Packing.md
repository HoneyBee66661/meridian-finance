# 6. Storage Layout & Packing

## Learning Objectives

By the end of this chapter you will be able to:

1. Explain the EVM storage model — a flat `2^256` key → value map — and how the compiler maps every state variable to a 32-byte **slot** from declaration order within the C3-linearized inheritance hierarchy (base-ward contracts first), starting at slot 0.
2. Apply the **packing rules** by hand: which types share a slot, why declaration order decides the gas bill, and how dynamic arrays and mappings derive their data slots (including element packing for small fixed-width types).
3. Compute derived slots — `keccak256(p)`, `keccak256(k . p)`, nested compositions — and read any slot directly with `sload` to prove the layout.
4. Explain why `EIP-1967` puts proxy implementation/admin/beacon pointers in **unstructured, hash-derived slots**, and recite the three canonical slot constants and their events.
5. Apply **ERC-7201 namespaced storage** to an implementation: the namespace formula, the `& ~0xff` alignment, and how namespacing reduces cross-module collision risk (while internal layout discipline still governs upgrade compatibility).
6. Audit a layout the way a reviewer would: packed-vs-unpacked gas deltas, append-only upgrade rules, uninitialized-implementation hazards, proxy-collision classes.

## Prerequisites

- **Chapter 3** (ABI Encoding & Data Locations) — `memory`/`calldata`/`storage` as distinct data locations; the ABI encoder pads everything to 32 bytes, which is exactly why storage *packing* exists as a cheaper encoding.
- **Chapter 5** (Contract Lifecycle & CREATE2) — `DELEGATECALL` semantics and minimal proxies; `MeridianFactory` deploys `EIP-1167` proxies today, and this chapter decides how those children lay out storage when they grow upgradeable (Ch 38).

## Theory

### Storage is a map, not an array

The EVM's storage is a `uint256 → uint256` mapping — 2^256 keys, each holding 32 bytes, all zero-initialized. There is no "layout" in the EVM; there is only the compiler's *convention* for turning source-level names into keys. That convention:

1. Assigns slots in **declaration order within the C3-linearized inheritance hierarchy**, starting from the most base-ward contract at slot 0, one per variable *unless* several fit — a derived contract's variables follow its bases' variables and may pack with them.
2. **Packs** consecutive variables whose total size is ≤ 32 bytes into one slot, from the least-significant byte upward.
3. **Does not reorder** variables to pack better — packing is developer discipline, not an optimizer.
4. Fixes everything at compile time: `foo`'s slot in `contract C` is identical in every deployed copy — including copies behind a proxy, where the trouble starts.

The gas stakes are immediate (EIP-2929/EIP-3529): a **cold** `SLOAD` costs 2,100, a warm one 100; a **fresh** `SSTORE` costs 22,100 (20,000 + 2,100 cold access), a warm modification 2,900, clearing a slot refunds 4,800 (capped at `gas_used/5`). Every slot you *don't* touch is pure saving — one slot costs a fifth of the reads and writes of five.

### The packing rules

Within a slot, values pack from the low byte upward in declaration order:

```
slot N: [ bytes 0..31 ]  ← least significant first
```

- `uint8` + `uint128` + `uint64` + `bool` → 8+128+64+8 = 208 bits → **one slot**.
- `uint8 a; uint256 b; uint8 c;` → **three slots** — `a` and `c` cannot share a slot across the intervening 32-byte variable. Reordered to `uint8 a; uint8 c; uint256 b;` → **two** slots, same semantics, 33% fewer slots.
- `address` (20 bytes) + `uint96` → exactly one slot — the classic pairing.
- **Static arrays** (`uint64[4]`) pack their elements inline like consecutive variables — but the array's data *starts at a new slot*, and variables declared after it start a new slot. Structs follow the same rule: a struct's members start at a new slot (the struct's base) and pack internally per the normal rules.
- **Dynamic arrays and mappings** never store their elements at the array/mapping's own slot: the slot holds the length (arrays) or nothing (mappings), and elements/values live at derived slots. **Element packing applies when elements are small and fixed-width**: `uint8[]` packs 32 elements per slot, `uint16[]` 16, `uint128[]` 2; `uint256[]` and larger or variable-width elements occupy one or more full slots. `bytes`/`string` beyond 31 bytes store data at `keccak256(p)`, one full slot per 32-byte chunk. Packing is otherwise a property of *fixed-size* data.
- **Inheritance** orders the whole tree, not just one contract. Slots are assigned in **C3-linearized order, most base-ward contract first**: `linearizedBaseContracts` runs derived → base, and storage walks it in reverse. For `contract D is B, C` with `B is A` and `C is A`, the linearization is `D → B → C → A` and storage runs `A → C → B → D` — so `C`'s variables land at *lower* slots than `B`'s, a reordering a source-order reading of `is B, C` would miss. Variables from *different* contracts in the linearization can still pack into one shared slot.

### Derived slots: dynamic arrays, mappings, strings

- **Dynamic array** at slot `p`: slot `p` stores the *length*; the data root is `keccak256(p)`. For one-slot elements, element `i` lives at `keccak256(p) + i`. For small fixed-width elements, elements share slots like a static array: `base = keccak256(p)`, element `i` at `base + floor(i / elementsPerSlot)` with the element at byte offset `(i % elementsPerSlot) × width` — `uint8[]` → 32 elements/slot, `uint16[]` → 16/slot, `uint128[]` → 2/slot; larger elements advance by their slot width.
- **Mapping** at slot `p` (for value-type keys such as `address` and unsigned integers): value for key `k` lives at `keccak256(k . p)` — the 32-byte key left-packed, concatenated with the 32-byte slot number. For `bytes`/`string` keys, hash the key first: `keccak256(keccak256(key) . p)`. (Solidity's general storage spec uses a type-dependent encoding function for keys; the simplified formula above is exact for value-type keys.)
- **Nested mapping** `m[k1][k2]` at slot `p`: `keccak256(k2 . keccak256(k1 . p))`.
- **Struct inside a mapping**: the derived slot is the struct's *base*; members offset from it per the packing rules.
- **`bytes`/`string` short-string optimization**: ≤ 31 bytes → everything (length and data) in the one slot `p`, with `2 × length` in the lowest byte (even low bit = "short"). The slot reads as `[ payload bytes ][ 2 × length ]` — payload in the high-order bytes, encoded length in the low byte. Longer values store `2 × length + 1` at slot `p` (odd = "long") and data at `keccak256(p)`.

Two consequences follow: first access to an array element or mapping value pays a `keccak` (30 + 6 gas/word) *on top of* the cold `SLOAD` — ~2,136 gas vs a struct member's 2,100, more for nested keys — and a dynamic array's length and a long string's data live in *different* slots (length: one `SLOAD`; data: a hash plus another `SLOAD`).

### EIP-1967: unstructured proxy storage

A proxy `DELEGATECALL`s into an implementation, so the implementation's code runs against the *proxy's* storage. The proxy must remember which implementation it points at — **somewhere the implementation's variables never reach**. The naive approach, `address public implementation;` as the proxy's slot-0 variable, collides with any implementation that also uses slot 0 (an `Ownable` `owner`, an `initialized` flag): the classic **storage collision**, pointer and state silently sharing a slot.

**EIP-1967** (2019) solves this with *unstructured* storage: the pointers live in slots derived from `keccak256(<string>) - 1`, astronomically unlikely to be chosen by any implementation:

| Purpose | Slot (full constant) | Derivation |
|---|---|---|
| Implementation | `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` | `keccak256("eip1967.proxy.implementation") - 1` |
| Admin | `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103` | `keccak256("eip1967.proxy.admin") - 1` |
| Beacon | `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` | `keccak256("eip1967.proxy.beacon") - 1` |

The `- 1` is deliberate: EIP-1967 chose a **standardized, deterministic, hash-derived slot construction** that sits outside the compiler's normal sequential layout and outside the collision classes of hand-picked slots — `keccak256("eip1967.proxy.implementation") - 1` is verifiable by any tool, and a contract that naively uses the raw hash without the `-1` lands exactly one slot away, making the collision a loud, detectable bug rather than a silent overlap. (The security argument is the hash-derived discipline, not the single-slot offset itself.) EIP-1967 also standardizes the events tooling watches (`Upgraded`, `AdminChanged`, `BeaconUpgraded`) and the `implementation()`/`admin()`/`beacon()` getters. It is a slots-and-events standard, not a code standard: `TransparentUpgradeableProxy`, `UUPSUpgradeable` (EIP-1822 lineage, on the EIP-1967 slot), and Beacon proxies all read and write the same three slots.

### ERC-7201: namespaced storage for implementations

EIP-1967 protects the *proxy's* few pointers; it says nothing about the implementation's own layout — where upgradeability actually breaks. An upgraded implementation must not reorder, resize, or retype any variable the old version wrote. The append-only rule ("only add at the end") fails exactly when needed most: multi-module contracts whose variables interleave.

**ERC-7201** (namespaced storage layout, authored by OpenZeppelin, 2023) gives each module its own isolated region:

```
namespace = keccak256(abi.encode(uint256(keccak256("id")) - 1)) & ~bytes32(uint256(0xff))
```

`id` is a unique string such as `"meridian.vault.markets"`. The `& ~0xff` clears the low 8 bits, **aligning the namespace root to a 256-slot boundary** — the EIP describes the alignment as a future gas-optimization convenience, not a fixed 256-slot container; the namespace then follows the normal storage-tree rules (mappings, dynamic arrays, nested structs) rooted at that address. Each module declares one struct and accesses it through a function setting the struct's `slot` to the compile-time constant — so namespacing costs **zero extra gas**, identical `SLOAD`/`SSTORE` economics to a plain layout — and upgrades become independent: module A's variables can be reordered without touching module B's region. It is the storage-layer answer to the modularity problem EIP-2535 (Diamond) solves with facet storage, and the pattern Euler v2 builds on.

## Mathematical Foundations

### The namespace formula, dissected

Take `id = "meridian.vault.markets"`. Each step of the formula has a job: `keccak256(id)` produces a uniformly distributed 256-bit value; `- 1` nudges it below the naive hash (mirroring EIP-1967, so a contract that naively uses `keccak256(id)` as its own slot never collides with the namespace); `abi.encode(uint256(...))` is the explicit 32-byte encoding (`abi.encodePacked` would be identical for a single `uint256`, but `abi.encode` is the locked Meridian default from Ch 3); and `& ~bytes32(uint256(0xff))` zeroes the low byte, aligning the namespace root to a 256-slot boundary — framed in the EIP as a future gas optimization, not a hard region size — after which a struct larger than 32 bytes laid out as consecutive slots from the base, or a mapping/dynamic array rooted there, all follow the normal storage-tree rules from that root. The `- 1` appears independently in both standards: the "one below the hash" region is one only a malicious or negligent implementation touches.

### What actually collides

Two independent 256-bit hashes collide with probability 2^-256 — cryptographically impossible to manufacture. The practical question is different: what collides with a *known* slot? An implementation declaring state at slots 0..N collides deterministically with a proxy's slot-0..N storage — no hash protects against that. EIP-1967 and ERC-7201 make cross-region collisions *impossible by construction*: the implementation's compiler-assigned slots and the standards' hash-derived slots are disjoint regions, provided the implementation follows one rule — **declare no state outside the storage you own**; for a namespaced implementation, that means no state variables at all outside the namespace structs. That rule is the entire discipline in one sentence. Note the boundary of the guarantee: ERC-7201 isolates a namespace root from other namespaces and the standard storage tree, but it does not make the module's *internal* layout upgrade-compatible automatically — the annotation is not compiler-enforced, so append-only and layout-diff discipline still apply within a namespace.

## Engineering Perspective

### Layout as a gas budget

Reads and writes dominate contract costs. Take the chapter's canonical example: four `uint64` fields declared consecutively pack into exactly one 256-bit slot; the same fields declared *interleaved* with `uint256` variables occupy four slots. When the packed fields are accessed together, the raw storage-access delta is **up to a 4× reduction** (one slot vs four):

- Cold read: **2,100 vs 8,400** (one slot vs four)
- Fresh write: **22,100 vs 88,400**
- Warm update: **2,900 vs 11,600** (warm `SSTORE` reset)

And this multiplies across a hot path: a lending vault touching collateral, debt, and interest state per user per transaction is the difference between a ~60k-gas operation and a ~200k-gas one — L1-viable or L2-bound (Ch 29-31). The multiplier is *conditional*: fields accessed together reap it; a partial write to a packed slot can require a read-modify-write that costs more than the unpacked equivalent (Solidity warns packed-struct writes can be more expensive) — pack by access pattern, not by type size alone.

### The three-way trade: packing, clarity, upgradeability

Packing saves gas but couples variables: writing `bool d` in a packed slot dirties the whole slot (2,900 gas, plus a 4,800 refund *foregone* if another member was cleared). Upgradeability adds the append-only constraint. The production answer is *intentional grouping*: pack fields that change together (Uniswap V3's `slot0`), separate fields that change independently, namespace by module so upgrade blast radius stays local. Meridian's rule, locked here: **group by access/update pattern — fields frequently read or written in the same operations — not by type size; never let a hot-path write share a slot with a rarely-touched field.**

### Proxies: transparent vs UUPS, and what EIP-1967 actually buys

Two proxy families dominate:

- **Transparent proxies** (OZ `TransparentUpgradeableProxy`): the proxy checks `msg.sender == admin` and, if so, serves admin functions (`upgradeTo`, `admin()`) itself instead of delegating. This sidesteps **function-selector clashes** — an implementation whose `upgradeTo` would shadow the proxy's. Gas model is version-specific: OZ Contracts v5 stores the admin as an `immutable` (no per-call `SLOAD`); v4-style proxies paid an extra cold `SLOAD` for the admin slot on every call.
- **UUPS** (EIP-1822 lineage): the implementation hosts `upgradeTo`; the proxy is a dumb `DELEGATECALL` shim, cheaper per call. The trade: an implementation bug can brick upgradeability, and the implementation needs protection from direct `initialize()` calls (Security Analysis).

Both read/write the same EIP-1967 implementation slot — the standard's real contribution: **one slot, one event shape, one tooling ecosystem** (Etherscan renders "proxy" tabs from these slots). Meridian defers the transparent-vs-UUPS choice to Ch 38, but the *storage contract* is locked now: EIP-1967 slots, ERC-7201 namespaces, zero state outside namespaces, append-only within one.

## Code Walkthrough

Meridian's lab for this chapter is `StorageProbe.sol` — pedagogical, not protocol (the standing convention since `ErrorProbe`/`ArithProbe`). It demonstrates packing, derived slots, and the short-string optimization, and exposes raw `sload` so tests can pin the compiler's layout exactly:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StorageProbe
/// @notice Lab contract demonstrating EVM storage layout: packing, derived
///         slots, short-string optimization. Pedagogical only — NOT protocol.
contract StorageProbe {
    // One slot: 64+64+64+64 = 256 bits exactly.
    uint64 public a;
    uint64 public b;
    uint64 public c;
    uint64 public d;

    // Declaration order decides packing; these can NOT share slots with a-d.
    uint256 public big;          // slot 1
    address public owner;        // slot 2 (20 bytes, owns slot 2 alone)
    uint96  public feeBps;       // shares slot 2 with `owner` (20+12 = 32B)

    uint256[] public values;     // slot 3: length; elements at keccak256(3)
    mapping(address => uint256) public debt;   // slot 4
    string public tag;           // slot 5: short-string inline or keccak(5)
    uint8[] public packedBytes;  // slot 6: length; elements pack 32 per slot

    /// @notice Raw slot read — the audit primitive.
    function readSlot(bytes32 slot) external view returns (bytes32 data) {
        assembly ("memory-safe") {
            data := sload(slot)
        }
    }

    /// @notice Dynamic array (`values` is uint256[]) element slot: keccak256(p) + i.
    function arrayElementSlot(uint256 i) external pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(3)))) + i);
    }

    /// @notice Packed dynamic-array element slot for `packedBytes` (uint8[]):
    ///         32 elements share one slot — keccak256(6) + i/32, byte (i % 32) * 8.
    function packedElementSlot(uint256 i) external pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(6)))) + i / 32);
    }

    /// @notice Mapping value slot: keccak256(k . p).
    function mappingSlot(address k) external pure returns (bytes32) {
        return keccak256(abi.encode(k, uint256(4)));
    }

    /// @dev Test helpers: storeAndLocate pushes and self-verifies the derived
    ///      slot with an internal assert; setTag/tagIsShort exercise the
    ///      short-string form; storeDebt writes the mapping.
    function storeAndLocate(uint256 v) external returns (bytes32 slot) {
        values.push(v);
        slot = arrayElementSlot(values.length - 1);
        assert(readSlot(slot) == bytes32(v));
    }

    function tagIsShort() external view returns (bool) {
        bytes32 s = readSlot(bytes32(uint256(5)));
        return uint8(uint256(s)) % 2 == 0;   // even low bit ⇒ short form
    }

    function storeDebt(address k, uint256 v) external { debt[k] = v; }

    function storePacked(uint8 v) external { packedBytes.push(v); }

    function setTag(string calldata t) external { tag = t; }

    function valuesLength() external view returns (uint256) { return values.length; }
}
```

Three details to notice:

- `owner` + `feeBps` pack into one slot only because they are *adjacent*; a `uint256` between them would force three slots. The tests pin this so a reorder breaks CI instead of silently costing gas.
- `arrayElementSlot`/`mappingSlot` hand-roll the compiler's derivation; tests assert `readSlot(mappingSlot(k)) == debt[k]` — the same technique an auditor uses to dump a contract's storage without source.
- The short-string check reads the slot's low bit: even → inline, odd → long. `storeAndLocate` self-verifies the array math with an internal `assert` (panic 0x01, fine for invariants per the Ch 2 convention).
- `values` is a `uint256[]` — one element per slot — while `packedBytes` (`uint8[]`) shows the packed case: `packedElementSlot` returns `keccak256(6) + i/32`, and `testPackedDynamicArrayPacking` asserts elements 0..31 share one slot with the expected byte offsets.

The companion lab, `NamespacedStorageLab.sol`, implements the formula as a library and hosts the provisional `meridian.vault.markets` namespace — deliberately *storage-only*, with no logic, because the logic arrives in Ch 20. Its `VaultStorage` struct groups the hot fields (`collateral`, `debt` — written together on every borrow/repay) with a `uint64 + uint64 + uint32 + uint96` scalar group of exactly 256 bits, all reached through a constant-slot accessor:

```solidity
function vaultStorage() internal pure returns (VaultStorage storage $) {
    assembly ("memory-safe") { $.slot := VAULT_NAMESPACE }
}
```

Because the namespace constant is folded at compile time, the accessor costs zero runtime gas.

## Production Example

**Uniswap V3 `Pool.sol` `slot0`** is the canonical packed struct: `sqrtPriceX96 (uint160) + tick (int24) + observationIndex (uint16) + observationCardinality (uint16) + observationCardinalityNext (uint16) + feeProtocol (uint8) + unlocked (bool)` — 248 bits in **one slot**. A swap reads price, tick, and liquidity state in a handful of `SLOAD`s, and the infamous `unlocked` reentrancy guard is a single bit in the same slot — set false at swap start, true at the end, in the same packed write that updates the price.

**Euler v2** is the flagship production deployment of ERC-7201-style namespaced storage: every module owns its own region, and upgrades reorder their own storage without a shared-layout migration. It is also the pattern OpenZeppelin's upgradeability docs recommend, and it composes with EIP-1967: the proxy's three pointers live in unstructured slots, everything the implementation owns lives in namespaces, and the regions cannot meet.

**OpenZeppelin `ERC1967Upgrade`** (used by `TransparentUpgradeableProxy`, `UUPSUpgradeable`, `BeaconProxy`) is the reference implementation of the EIP-1967 slots and events — read it for the assembly slot access and event-emission discipline explorers depend on.

## Foundry Lab

`meridian/test/StorageProbe.t.sol` + `meridian/test/NamespacedStorageLab.t.sol` — unit + fuzz coverage:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StorageProbe} from "../src/StorageProbe.sol";
import {NamespacedStorageLab} from "../src/NamespacedStorageLab.sol";

contract StorageProbeTest is Test {
    StorageProbe internal probe;

    function setUp() public {
        probe = new StorageProbe();
    }

    /// @dev Derived slots: mapping value lands exactly where the formula says.
    function testMappingSlotMatches(address k, uint256 v) public {
        probe.storeDebt(k, v);
        assertEq(probe.readSlot(probe.mappingSlot(k)), bytes32(v));
    }

    /// @dev Dynamic array (uint256[]): element i at keccak256(p) + i, one slot each.
    ///      Small fixed-width element types (uint8[] etc.) share slots per the packing rules.
    function testArrayElementSlot(uint256 v) public {
        probe.storeAndLocate(v);
        uint256 i = probe.valuesLength() - 1;
        assertEq(probe.readSlot(probe.arrayElementSlot(i)), bytes32(v));
    }

    /// @dev Packed dynamic array: uint8[] elements share slots — 32 per slot,
    ///      element i at keccak256(6) + i/32, byte offset (i % 32) * 8.
    function testPackedDynamicArrayPacking() public {
        for (uint256 i; i < 32; ++i) probe.storePacked(uint8(i));
        bytes32 slot0 = probe.readSlot(probe.packedElementSlot(0));
        assertEq(slot0, probe.readSlot(probe.packedElementSlot(31))); // indices 0..31 share one slot
        assertEq(uint8(uint256(slot0)), 0);                           // element 0 in the low byte
        assertEq(uint8(uint256(slot0) >> 248), 31);                   // element 31 in the high byte
        assertEq(uint256(probe.packedElementSlot(32)), uint256(probe.packedElementSlot(0)) + 1);
        probe.storePacked(32);
        assertEq(uint8(uint256(probe.readSlot(probe.packedElementSlot(32)))), 32);
    }

    /// @dev Short string: <= 31 bytes stays inline in slot 5 (even low bit).
    function testShortStringInline() public {
        probe.setTag("meridian"); // 8 bytes — short form
        assertTrue(probe.tagIsShort());
    }
}
```

Gas numbers here are **derived from the published EIP-2929/EIP-3529 fee schedule**; the layout lab (`meridian/test/StorageProbe.t.sol`) pins the slot mechanics and is green on forge 1.7.1. The `NamespacedStorageLab` test suite additionally pins the 256-slot alignment of the namespace root and asserts the namespaces never touch the EIP-1967 slots. The lab also pins **packed dynamic-array element layout** (`uint8[]` → indices 0..31 share slot `keccak256(p)`, `uint16[]` → 0..15, `uint128[]` → 0..1) and exposes the bit-offset calculation via `packedElementSlot` — element packing is a frequent audit blind spot.

## Security Analysis

### The proxy storage collision (the reason EIP-1967 exists)

Before EIP-1967, proxies stored their pointer wherever the author felt like — usually slot 0. Any implementation whose own slot 0 held state (an `Ownable` `owner`, an `initialized` flag) silently shared storage with the pointer: a governance upgrade could be overwritten, or a user-controlled value could *become* the implementation address. This class is why the standard mandates unstructured slots, and it is still the first thing every proxy audit checks: **does any implementation variable land on `0x3608...`, `0xb531...`, or `0xa3f0...`?** A modern variant: naively using the raw `keccak256("eip1967.proxy.implementation")` (without the `-1`) as your own slot lands exactly one slot away from the standard's — the `-1` turns the collision into a loud, detectable bug rather than a silent overlap. The point is the discipline (standardized hash-derived slots), not the single-slot offset.

### The uninitialized implementation

An implementation is a normal contract: anyone can call its `initialize()` directly *on the implementation* — a call that runs against the implementation's *own* storage, not the proxy's (the proxy's storage is only involved when the proxy `DELEGATECALL`s into the implementation). Two distinct failure classes are routinely lumped together under this heading:

- **Calling `initialize()` on the implementation itself** changes implementation-local state; the canonical defense is OZ's `_disableInitializers()` — a constructor call setting `initialized`/`initializing` in the *implementation's own* storage so direct `initialize()` reverts forever. The flag occupying the implementation's slot 0/1 must never collide with the EIP-1967 slots, which it provably doesn't. Direct-call state is dangerous whenever the implementation exposes privileged logic whose direct-call state can affect upgradeability or security assumptions — `_disableInitializers()` neutralizes exactly that surface for upgradeable implementations (it is not a universal fix for delegatecall-library lifecycle bugs; see below).
- **Security-critical zero/default state (a distinct class).** Nomad bridge (August 2022, ~$190M drained) is the canonical dangerous-default-state failure: the bridge's `root` — a storage variable — was never initialized, and message processing treated the zero root as a pre-confirmed valid root. The proof system was fine; the *storage state* was not. This differs from the uninitialized-implementation attack above: no `initialize()` exists to call — the flaw is that the pre-initialize state of a security-relevant variable was itself trusted. The audit question "what is the pre-initialize state of every storage variable, and is any of it security-relevant?" exists because of this class.

### Delegatecall libraries and shared implementation storage

Parity's wallet library (November 2017) remains the defining delegatecall-storage disaster: wallets `DELEGATECALL`ed into a shared library whose `initWallet` was callable *on the library itself*. An attacker called it, became the library's owner, then called `kill`, self-destructing it. Every wallet that delegated suddenly pointed at an empty account; ≈513,774 ETH (hundreds of millions USD at 2017 prices) was frozen permanently. The lesson: **code under `DELEGATECALL` shares storage with its caller, and standalone code owns its own — a single contract must be safe under both.** General rule: any implementation or library that can be called directly must have a safe direct-call state and must not expose unexpected privileged lifecycle operations (Parity's `initWallet`/`kill` pair is the archetype; `_disableInitializers()` protects upgradeable implementations, but the underlying requirement is broader).

### Append-only violations and the silent corruption

The upgrade rule — "never reorder, resize, or retype existing variables; append only" — exists because the compiler lays out slots at *compile time of the new version*. Reordering two `uint256`s between upgrades silently reinterprets live data: the protocol keeps running, balances land in the wrong slots, and the corruption surfaces as a user-draining bug weeks later. Namespacing shrinks the blast radius (each module reorders only within its region) but does not eliminate the rule — it localizes it. The checklist: diff the *storage layout* (`solc --storage-layout`) between every pair of versions, not just the source. A related mitigation reserves empty slots (`uint256[50] private __gap;`) so future versions can add variables without appending into a derived-slot region — namespaced storage generalizes the idea: the namespace *is* the gap, sized and owned.

## Common Mistakes

1. **Assuming the compiler packs optimally.** It does not reorder; `uint8 a; uint256 b; uint8 c;` is three slots. Declare by size group, hot fields adjacent.
2. **Assuming dynamic-array elements never pack.** Small fixed-width elements share slots like static arrays (`uint8[]` → 32/slot, `uint16[]` → 16/slot, `uint128[]` → 2/slot); only `uint256[]`-sized or larger elements get one slot each. Mappings always derive per-key slots.
3. **Computing derived slots with the wrong concatenation.** `abi.encode(k, p)` and `abi.encodePacked(k, p)` differ when `k` is shorter than 32 bytes (e.g., `address`) — the compiler left-packs keys; the lab's `mappingSlot` uses `abi.encode` to match.
4. **Off-by-one on the short-string low byte.** Short form stores `2 * len` (even), long form `2 * len + 1` (odd). Testing parity of the *slot value* instead of the low bit misclassifies the 31-byte boundary.
5. **Hand-rolling proxy pointers into slot 0..N, or leaving an implementation initializable.** For Meridian, an implementation pointer outside EIP-1967 is a design violation unless explicitly reviewed (a custom proxy may use another documented layout — that is a deliberate, audited decision, not a default); every upgradeable implementation needs `_disableInitializers()`-style protection and an initialized check.
6. **Skipping the storage-layout diff on upgrade.** `solc --storage-layout` before/after is the cheapest audit you will ever run; skipping it is how "silent corruption" bugs ship.
7. **Counting on refunds.** A packed-slot write that clears one member and sets another nets out against the 4,800 refund cap (`gas_used/5`, EIP-3529); "clearing pays for setting" is not a reliable gas model (Ch 1: never depend on refunds).

## Gas Optimization

All numbers derived from the published fee schedule (EIP-2929 cold 2,100 / warm 100; EIP-3529 fresh write 22,100 incl. cold access, warm change 2,900, clear refund 4,800 capped at `gas_used/5`); Ch 7's `GasProbeTest` measures and pins the gas numbers.

- **Pack four `uint64`s into one slot vs four unpackable slots:** cold read **2,100 vs 8,400**; fresh write **22,100 vs 88,400**; warm update **2,900 vs 11,600** — up to 4× when fields are accessed together (partial writes to a packed slot can cost more via read-modify-write), and packed fields often share one dirty write.
- **`address + uint96` pairing:** 20+12 bytes = one slot; a `mapping(address => uint256)` where `uint96` would do costs an extra 2,100 cold / 100 warm per read, forever.
- **Declaration-order fix:** `uint8 a; uint256 x; uint8 c;` (3 slots) → `uint8 a; uint8 c; uint256 x;` (2 slots) saves **2,100 cold** per full read and **22,100** per fresh write of the pair — zero-semantics change, pure ordering.
- **Mapping vs struct:** first access to a mapping value costs 2,100 (cold `SLOAD`) + ~36 (keccak) ≈ **2,136** vs 2,100 for a struct member; the gap widens with nested keys. Compile-time-known state belongs in structs, not mappings.
- **Short strings:** ≤ 31 bytes costs **one slot** (2,100 cold read); a long string's first data read is length slot + keccak + data slot ≈ **4,236**. Naturally-short values are cheaper as `string`/`bytes` than hashed.
- **Namespaced storage: 0 gas.** The namespace is a compile-time constant; ERC-7201 costs nothing at runtime over a plain layout. The discipline is free.
- **Immutables (Ch 2 lock):** construction-fixed values as `immutable` are `PUSH32`s (~3 gas) vs 2,100 cold `SLOAD` — the cheapest "storage" there is, and why Meridian's deploy-time constants never live in storage.

## Reading Production Source Code

Read, in this order:

1. **Uniswap V3 `Pool.sol`** — the `Slot0` struct declaration and every `slot0.` access in `swap`; count the `SLOAD`s and note the `unlocked` bit.
2. **OpenZeppelin `ERC1967Upgrade.sol` + `StorageSlot.sol`** — the assembly `sload`/`sstore` of the three slots, event emissions in `_setImplementation`/`_setAdmin`/`_setBeacon`, and typed slot wrappers — the production version of this chapter's `readSlot`.
3. **Euler v2 modules** (euler-xyz) — a real ERC-7201 namespaced layout: module-local storage structs and how upgrades reorder within a namespace.
4. **OpenZeppelin `Initializable.sol`** — `_disableInitializers()` and the `_initialized`/`_initializing` layout that must never collide with EIP-1967 slots.

Ask of each: *which fields change together, which slot do they share, and what happens to this layout when the contract is upgraded?* That is the storage audit in three questions.

## Exercises

1. Hand-compute the slot of a `mapping(address => uint256)` entry for a given key, then verify with `cast storage <addr> <slot>` on `anvil` against a deployed `StorageProbe`.
2. Predict the slot count of `struct S { uint8 a; uint128 b; uint16 c; uint256 d; }`, then reorder to minimize slots and verify with `forge inspect --storage-layout` on a forge-enabled host.
3. Derive the EIP-1967 implementation slot by hand — `keccak256("eip1967.proxy.implementation") - 1` — and confirm it equals `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`.
4. Compute the ERC-7201 namespace for `"meridian.vault.markets"` with `cast keccak` and verify the low byte is zero after `& ~0xff`.
5. Write the upgrade storage-diff procedure: `solc --storage-layout` on both versions plus a short checklist (no reorder, resize, or retype; append or reserved-slot fills only).

## Weekly Project

**Meridian's storage discipline — the layout contract every future module inherits.** Three deliverables:

1. `meridian/src/StorageProbe.sol` + `meridian/test/StorageProbe.t.sol` — the lab above: packing pins, derived-slot proofs, short-string detection, raw `sload`.
2. `meridian/src/NamespacedStorageLab.sol` + test — the ERC-7201 formula as a library, the provisional `meridian.vault.markets` skeleton (storage-only; logic in Ch 20), and a `meridian.vault.oracles` namespace reserved for Ch 22. Audit checklist: *do the namespaces overlap, is anything declared outside one, are the EIP-1967 slots untouched?*
3. `docs/storage-layout.md` — the written discipline: EIP-1967 slots for all future proxies; ERC-7201 namespaces for all implementation state; **zero state variables outside namespaces**; append-only within a namespace; hot fields packed together, cold segregated; `_disableInitializers()` on every upgradeable implementation; `solc --storage-layout` diff mandatory in every upgrade PR.

This resolves the Ch 5 open item: `MeridianFactory`'s `EIP-1167` children are non-upgradeable today, and Ch 38's upgradeable-proxy layer will build on exactly these slots and namespaces — the collision discipline is locked now so the migration later is mechanical, not architectural.

## Deliverables

1. `meridian/src/StorageProbe.sol` + `meridian/test/StorageProbe.t.sol` — layout lab (packing, derived slots, short strings, raw `sload`).
2. `meridian/src/NamespacedStorageLab.sol` + `meridian/test/NamespacedStorageLab.t.sol` — ERC-7201 formula + provisional Meridian namespaces.
3. `docs/storage-layout.md` — Meridian storage discipline (EIP-1967 + ERC-7201 + append-only + layout-diff rule).
4. Gas table: the numbers above, re-pinned by Ch 7's `GasProbeTest`.
5. Layout pins: tests asserting slot constants so any future reorder breaks CI.

## Quiz

1. Why does the compiler not reorder state variables to pack optimally, and what is the practical consequence?
2. Where does element `i` of `uint256[]` at slot `p` live, and how many `uint8[]` elements share one slot?
3. What are the three EIP-1967 slots, how are they derived, and what does the `- 1` accomplish?
4. Write the ERC-7201 namespace formula and explain the `& ~bytes32(uint256(0xff))` step.
5. What is the "uninitialized implementation" attack, and which two defenses neutralize it?

**Answers:** (1) Layout is fixed by declaration order (within the C3-linearized inheritance hierarchy) to keep storage deterministic across compilations; reordering would make layouts compiler-version-dependent. Pack by size group yourself. (2) `keccak256(p) + i` for one-slot elements; small fixed-width elements pack: `uint8[]` → 32 elements per slot (`base = keccak256(p)`, element `i` at `base + floor(i/32)`), `uint16[]` → 16, `uint128[]` → 2, `uint256[]` → 1. (3) `keccak256("eip1967.proxy.implementation") - 1`, and likewise for `.admin`/`.beacon`; the `-1` moves the slot below the naive hash so a contract using the raw hash cannot collide — the point is the standardized hash-derived discipline, not the offset itself. (4) `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`; the mask aligns the namespace root to a 256-slot boundary (a future gas optimization per the EIP, not a fixed container size) — the namespace then uses the normal storage-tree rules from that root. (5) An attacker calls `initialize()` on the implementation itself (or exploits security-critical default state — the Nomad zero-root class, a distinct failure mode); defenses: `_disableInitializers()` in the implementation constructor and an initialized check in the proxy.

## Further Reading

- EIP-1967 (Standard Proxy Storage Slots), EIP-1822 (UUPS), EIP-897 (DelegateProxy — historical), EIP-2535 (Diamond, facet storage), ERC-7201 (Namespaced Storage Layout).
- OpenZeppelin — `ERC1967Upgrade.sol`, `StorageSlot.sol`, `Initializable.sol`; "ERC-7201: Namespaced Storage Layout" (OZ blog).
- Solidity docs — "Layout of State Variables in Storage" (the authoritative reference for the rules above).
- Uniswap V3 — `Pool.sol` `Slot0`; Euler v2 — namespaced module storage in production.
- Nomad bridge post-mortem (Aug 2022) — the zero-root/uninitialized-storage class; Parity multisig library incident (Nov 2017) — delegatecall storage semantics.
- Ethereum Yellow Paper §4.1 (storage as world-state trie) and §9 (gas costs).

## Ledger Update

**Ch 6 — Storage Layout & Packing (2026-08-11)** — full entry appended to `ledger/CONTINUITY_LEDGER.md`.

- Locked storage conventions (canon) — labeled **STANDARD** vs **MERIDIAN CONVENTION**: STANDARD — EIP-1967 slot definitions; ERC-7201 formula (root aligned to a 256-slot boundary; normal storage-tree rules from the root; isolates cross-module collision risk but does not auto-make internal layouts upgrade-compatible — annotation not compiler-enforced). MERIDIAN CONVENTION — all upgradeable state uses namespaces, zero top-level implementation state, append-only namespace members, layout diff required in every upgrade PR, `_disableInitializers()` on every upgradeable implementation, `solc --storage-layout` diff mandatory; declaration-order packing within C3-linearized inheritance with no compiler reordering; hot fields packed together, cold segregated; dynamic-array elements pack when small and fixed-width (`uint8[]` 32/slot, `uint16[]` 16/slot, `uint128[]` 2/slot); structs/static arrays start at a new slot. Resolves the Ch 5 open item (proxy-storage collision discipline for `MeridianFactory` children).
- Repo artifacts (lab, NOT protocol): `meridian/src/StorageProbe.sol` + test, `meridian/src/NamespacedStorageLab.sol` + test (ERC-7201 formula + provisional `meridian.vault.markets` / `meridian.vault.oracles` namespaces, storage-only until Ch 20/22), `docs/storage-layout.md` — both suites green on forge 1.7.1.
- Glossary additions: slot packing, derived slot, short-string optimization, EIP-1967 unstructured storage, ERC-7201 namespace, append-only upgrade rule, uninitialized implementation.
- Grounding incidents: Nomad (Aug 2022, ~$190M, zero-root/uninitialized-storage class); Parity library kill (Nov 2017, ≈513,774 ETH frozen, delegatecall storage semantics).
- **ERRATA APPLIED (2026-08-14, review `errata/06_Storage_Layout_and_Packing_REVIEW.md`):** dynamic arrays CAN pack small fixed-width elements (`uint8[]` 32/slot, `uint16[]` 16/slot, `uint128[]` 2/slot); structs/static arrays start at a new slot; declaration-order rule now includes C3-linearized inheritance; ERC-7201 reframed (root alignment ≠ fixed 256-slot region; internal upgrade compatibility still requires discipline — annotation not compiler-enforced); packing savings qualified as "up to 4× when accessed together"; grouping rule now access/update-pattern; OZ v5 transparent proxy uses an immutable admin (gas version-specific); Nomad separated into the dangerous-default-state class (distinct from uninitialized implementations); warm-update numbers corrected to 2,900/11,600 (same root fix as Ch 8 errata); mapping formula labeled value-type-key scope; short-string slot diagram added.
- **ERRATA APPLIED (2026-08-15, review `errata/06_Storage_Layout_and_Packing_REVIEW.md`):** verification pass — every finding re-checked against the chapter, solc v0.8.24 source (`ContractType::stateVariables()` iterates `linearizedBaseContracts` reversed, i.e. most base-ward first), the Solidity storage-layout docs, the ERC-7201 EIP text, and the repo's OZ v5 `TransparentUpgradeableProxy` (immutable admin, no per-call SLOAD); added the C3 worked example (`D is B, C` → storage `A → C → B → D`; cross-contract packing), added the packed dynamic-array lab test (`uint8[]` 32/slot, `packedElementSlot` bit-offset math), and completed the direct-`initialize()`/proxy-storage wording fix.
- Drift: none. Module boundary: none (M2 ends Ch 9 — next boundary audit at Ch 9).
