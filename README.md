# Meridian Finance — Solidity Protocol (Educational)

An educational, audit-disciplined implementation of an **isolated lending-market
protocol**, built chapter-by-chapter as part of a 40-chapter Web3 engineering
curriculum (EVM → Solidity → storage/gas → testing → token standards → lending
core → security → L2s → account abstraction → full-stack). Every chapter ships a
lab that is materialized, compile-verified, and tested in this repository.

> 📚 **Curriculum (theory track):** the finalized chapter text lives in
> [`curriculum/`](curriculum/) — Module 1 (Ch 1–5) is published, chapters 6+
> ship as they are finalized.

> **Positioning (honest):** this is a *learning* codebase with production-grade
> discipline — locked conventions, a full test suite (unit + fuzz + invariant),
> fork-testing, CI, and documented security analysis. It is not deployed and has
> no audit. Treat it as evidence of engineering practice, not a product.

## The protocol

Meridian is an isolated-lending protocol: each market (asset pair) has its own
collateral factor, kink-based interest-rate model, and oracle feed (Chainlink
primary, TWAP fallback). Protocol revenue accrues to `sMER` stakers via ERC-4626
share appreciation; `gMER` holders govern through a timelock-guarded governor.

| Token / contract | Status |
|---|---|
| `MeridianToken` (MER) — ERC20 + ERC-2612 permit, role-based minting | ✅ Ch 14 |
| `MeridianGovernanceToken` (gMER) — ERC-5805/ERC-6372 checkpointed voting | ✅ Ch 15 |
| `StakedMeridian` (sMER) — ERC-4626 staking vault (spec pinned, impl Ch 23) | 📐 spec |
| `MeridianVault` — lending core v1: collateral/LTV/health-factor | 🔨 Ch 20 |
| `InterestRateModel` (kink), `OracleRegistry` (Chainlink + TWAP) | 🔜 Ch 21-22 |
| `LiquidationEngine`, `MeridianGovernor` + timelock + multisig | 🔜 Ch 24-25 |

## Engineering discipline (locked conventions)

- Custom errors only (no require strings); error catalogs in `I`-prefixed interfaces
- Full NatSpec; CEI; immutables over storage; calldata for read-only args
- Solidity `^0.8.24`, EVM cancun, optimizer 200, `abi.encodeCall`
- Rounding policy: floor for user-received, ceil for user-paid (WAD/RAY)
- Gas claims carry before/after numbers; security claims name the actual vuln class
- Grounding: post-Fusaka (PeerDAS/EIP-7594) live; 2026 incident set documented
  (Kelp DAO/Drift ~$285–292M, Balancer V2 ~$128M, Euler ~$197M, imBTC/Uniswap v1)

## Test suite

```bash
cd meridian
forge build          # solc 0.8.24, cancun, optimizer 200
forge test           # unit + fuzz + invariant (CI seed)
forge test --match-path "test/*Fork*"   # fork tests — needs MAINNET_RPC_URL
```

- **344+ tests, 0 failed, 28+ suites** (unit, fuzz, invariant, gas probes)
- 2 invariant suites with adversarial handlers (conservation, no-free-assets)
- Fork layer (Ch 11): WETH/USDT/Chainlink/Uniswap v3 state at pinned mainnet block
- CI (`.github/workflows/`): lint/unit on PR, fork nightly, release (Ch 13)
- `.gas-snapshot` tracked for gas regression (Ch 13 gate)

## Repository map

```
src/    protocol contracts (MER, gMER, MeridianVault, …) + lab/probe contracts
test/   unit, fuzz, invariant, and fork test suites (+ mocks, handlers)
docs/   weekly-project documentation (materialized per module)
.github/workflows/  CI: ci, fork, release
```

## How this was built

One chapter at a time, each with: theory + math derivations → engineering
perspective → Foundry lab (materialized here, verified green) → security
analysis → gas optimization with measured numbers → production source reading.
Continuity ledger (`ledger/`) tracks conventions, incidents, and known debt.
