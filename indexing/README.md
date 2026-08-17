# Meridian Indexing

Subgraph skeleton (Ch 37): schema + handlers fold the vault/sMER event stream into Position/Market/Liquidation entities. Live state always read from chain (Ch 36 rule). See docs/indexing-notes.md.

## Handler Correctness Checklist

Pre-deploy gate for every `handleX`:

| # | Check | How to verify |
|---|---|---|
| 1 | Entity ID is a string (`.toHexString()` or `tx.hash + logIndex`) | `graph codegen` type check |
| 2 | All non-null schema fields initialized in the `null` branch | Read schema, trace null path |
| 3 | Event params converted to schema types (`.toBigDecimal()`, `.toString()`) | `graph codegen` type check |
| 4 | Historical event entities use `tx.hash + logIndex` as ID | Manual review |
| 5 | No `ethereum.call()` in handlers that must survive reorgs | `graph build --network` warning audit |
| 6 | Required-field entity saves never reach `.save()` with unset fields | Integration test against local Graph node |

`graph codegen` catches 1 and 3 (type errors); 2, 4, and 6 need manual review or integration testing; 5 is a reorg-safety audit.
