# Meridian Storage Discipline (v1 — locked Ch 6)

> Canonical reference for every storage layout decision in `meridian/`.
> Locked in Chapter 6 (Storage Layout & Packing). Later modules (Ch 14 token,
> Ch 20-22 vault/oracles, Ch 38 upgradeability) build on this — do not deviate
> silently; update this doc in the same PR that changes a rule.

## 1. The two regions

Every Meridian contract's storage is split into exactly two disjoint regions:

| Region | Owned by | Standard |
|---|---|---|
| Proxy pointers (implementation/admin/beacon) | the **proxy** only | EIP-1967 unstructured slots |
| All implementation state | the **implementation** | ERC-7201 namespaces |

Rule: **zero state variables declared outside a namespace struct.** An
implementation may only hold state inside its ERC-7201 namespace region(s).

## 2. EIP-1967 slots (canonical constants)

| Purpose | Slot |
|---|---|
| Implementation | `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` |
| Admin | `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103` |
| Beacon | `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` |

Derivation: `keccak256("eip1967.proxy.<role>") - 1`. Events: `Upgraded`,
`AdminChanged`, `BeaconUpgraded`. Audit check: no implementation variable may
land on these slots.

## 3. ERC-7201 namespaces (reserved)

| Namespace id | Constant | Introduced | Used by |
|---|---|---|---|
| `meridian.vault.markets` | `VAULT_NAMESPACE` | Ch 6 (skeleton) | `MeridianVault` (Ch 20) |
| `meridian.vault.oracles` | `ORACLE_NAMESPACE` | Ch 6 (reserved) | `OracleRegistry` (Ch 22) |

Formula (compile-time constant — zero runtime gas):

```
namespace = keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
```

Accessor pattern (memory-safe):

```solidity
function vaultStorage() internal pure returns (VaultStorage storage $) {
    assembly ("memory-safe") { $.slot := VAULT_NAMESPACE }
}
```

## 4. Packing rules (canon)

- Declaration order decides layout; **the compiler never reorders** — pack by size group yourself.
- Pack fields that change together; never let a hot-path write share a slot with a rarely-touched field.
- `address` + `uint96` = one slot; group small scalars to ≤ 256 bits per slot.
- Dynamic arrays and mappings **never** pack (full slot per element/value).
- Short `string`/`bytes` (≤ 31 bytes) inline in one slot; long form at `keccak256(slot)`.
- Measured schedule (EIP-2929/EIP-3529): cold SLOAD 2,100 / warm 100; fresh SSTORE 22,100; warm change 2,900; clear refund 4,800 capped at `gas_used/5`. 4× packed group: read 2,100 vs 8,400; write 22,100 vs 88,400; update 3,000 vs 12,000.

## 5. Upgrade rules

1. **Append-only within a namespace** — no reorder, no resize, no retype of existing members.
2. Reserve `__gap` slots only inside namespaces that need room; prefer adding new namespaces over growing structs.
3. Every upgradeable implementation: `_disableInitializers()` in the constructor + initialized check in the proxy.
4. Mandatory per upgrade PR: `solc --storage-layout` diff (old vs new), reviewed, attached to the PR.
5. Never store upgrade authority in the implementation's own namespace — the proxy's EIP-1967 admin slot is the single source of truth.

## 6. Audit checklist (every layout review)

- [ ] Any state outside a namespace? (violation)
- [ ] Any variable on an EIP-1967 slot? (violation)
- [ ] Do two namespaces overlap? (violation)
- [ ] Packed group = fields that change together?
- [ ] `solc --storage-layout` diff clean (append-only)?
- [ ] Implementation protected from direct `initialize()`?
- [ ] Pre-initialize state of every security-relevant variable known (no Nomad-class zero-root assumptions)?
