# Deployment Addresses — Counterfactual Catalog (Ch 5)

> Pipeline doc for Meridian. Every address in this catalog is computable
> **before** deployment (EIP-1014). Integrators rely on these, so treat
> this file as an API surface: any change to initcode, constructor args,
> or the deploying factory invalidates every address in the table.

## Rules (locked in Ch 5)

1. **Salt namespace**: user-influenced salts are namespaced by sender:
   `salt' = keccak256(msg.sender, salt)`. No caller can burn another
   caller's namespace.
2. **Initcode, not runtime**: predictions hash `keccak256(initcode)` with
   constructor args appended — never runtime code.
3. **Verify after deploy**: always compare `codehash` against the expected
   EIP-1167 runtime with the implementation embedded. An address existing
   proves nothing about whose code is there.
4. **Template drift breaks addresses loudly**: changing a template's
   implementation or its initcode changes every derived address. Plan
   deployments, then freeze templates.

## Address derivation

```
market = keccak256(0xff ++ MeridianFactory ++ salt' ++ keccak256(initcode))[12:]
salt'  = keccak256(deployer, salt)
```

## Catalog (populated as modules land)

| Component | Chapter | Expected address | Status |
|-----------|---------|------------------|--------|
| `MeridianFactory` (proxy factory) | Ch 5 | *TBD on deployment* | v0 written |
| `MeridianToken` (MER) | Ch 14 | *TBD* | planned |
| `MeridianVault` markets (per-market proxies) | Ch 20+ | *TBD* | planned |
| `OracleRegistry` | Ch 22 | *TBD* | planned |
| L2 bridge wrapper | Ch 31 | *TBD* | planned |

## Verification script

```bash
# after any deployment, confirm the on-chain codehash matches the promise
cast codehash <market> --rpc-url $RPC
cast keccak $(cast concat-hex 0x363d3d373d3d3d363d73 <impl> 0x5af43d82803e903d91602b57fd5bf3)
```
