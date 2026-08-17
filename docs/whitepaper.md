# Meridian Finance — Protocol Whitepaper (v1.0.0)

> **Positioning (honest):** Meridian is an *educational* isolated-lending
> protocol — a 40-chapter engineering curriculum's capstone artifact, not a
> production product. It has no audit beyond the curriculum's own
> full-system pass (Ch 39), is not deployed on mainnet, and the testnet
> deployment (Ch 40) uses mintable stand-in assets. It exists to demonstrate
> production-grade *discipline*: locked conventions, a 540-test suite,
> invariant campaigns, CI, and documented security analysis.

## 1. Abstract

Meridian is an **isolated lending market protocol**: each market is an
independent vault holding one collateral/debt asset pair with its own
collateral factor, liquidation threshold, interest-rate model, and oracle
feed. Isolation means a correlated-collateral crash in one market cannot
drain another — the 2026 contagion class (Ch 20 grounding). The protocol
ships with its own governance token (MER), a voting wrapper (gMER), a
staking wrapper (sMER), a market factory, and a Ch 22 oracle registry.

## 2. Mechanics

### 2.1 Markets and the vault

Each `MeridianVault` is one isolated market:

- **Deposit** collateral (collateral token) → increases `collateralOf[user]`.
- **Borrow** up to `capacity = collateralValue * CF`, where `CF` is the
  collateral factor (75% default). Debt is a Compound-style snapshot:
  `principal * index / interestIndex`, so interest accrues O(1) per user.
- **Repay** principal + accrued interest; partial repayments settle a hair
  less (rounding favors the protocol, Ch 4/16).
- **Health factor** `HF = collateralValue * LT / debtValue` (WAD). Borrow
  and withdraw enforce `HF >= 1`; a position becomes liquidatable when
  `HF < 1` (debt exceeds `LT * collateralValue`). The liquidation threshold
  sits strictly above the collateral factor, so the maximum borrower is
  never liquidatable on entry (`HF = LT/CF > 1`).
- **Interest** accrues per-second from the rate model at current
  utilization; the protocol reserve claims `reserveFactor` of it.

### 2.2 Price discovery

Prices resolve through `OracleRegistry` (Ch 22): a Chainlink-shaped primary
feed per asset with a staleness check, an on-chain TWAP fallback, and an
optional deviation guard. The vault consumes the single `getPrice(asset)`
surface; the manipulation-resistance choice lives in one place. The vault's
math is price-convention-agnostic — both assets scale together, so the
registry's 18-dec canonical normalization and a raw 8-dec feed produce
identical health factors.

### 2.3 Governance

- **MER** (ERC-20, 10M initial supply) is the raw token.
- **gMER** is the vote wrapper: deposit MER, vote with gMER
  (delegation-capable, Ch 15).
- **sMER** is the staking wrapper, accumulating protocol revenue (Ch 23).
- Parameter changes (collateral factor, liquidation threshold, rate model,
  oracle) are admin-gated in v1 and *must* flow through the Ch 38 chain in
  production: Safe multisig → timelock → governor. The Ch 39 audit fixed a
  governance seam where `setCollateralFactor` could erase the safety buffer
  (`LT > CF` cross-check now enforced on the whole governance surface).

## 3. Security model

- **Isolation** (per-market vaults) bounds contagion.
- **Rounding** is direction-locked: the protocol never loses a wei
  (ceil on what users owe, floor on what they get).
- **Conservation** is executable: invariant suites pin collateral
  conservation, exact debt books, no self-inflicted liquidation, and the
  safety-buffer inequality (Ch 39, 16,384 calls per invariant).
- **Trust anchors** (Ch 25 inventory): the governance role, the oracle,
  the rate model, and (in production) the proxy admin. The 2026
  calibration: Drift (~$285M) was key custody; Kelp DAO/LayerZero
  (~$292M) was verifier *configuration*. Both are single-point failures;
  Meridian's mitigations are the multisig + timelock chain and the
  deviation guard.
- **Upgrades** (production path, Ch 38): EIP-1967 proxy with the admin
  slot held by a Safe, append-only ERC-7201 storage, a storage-diff CI
  gate, and a pause-first incident runbook.

## 4. Tokenomics (educational)

| Token | Role | Supply |
|---|---|---|
| MER | raw ERC-20 | 10,000,000 initial |
| gMER | vote wrapper (1:1 on deposit) | uncapped, minted on deposit |
| sMER | staking wrapper | uncapped, minted on stake |

Interest spread flows to sMER stakers (reserve factor 20% default); supply
policy is a governance decision (minter role), no hard cap.

## 5. Deployment (testnet, Ch 40)

`forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast --verify`
deploys the full protocol: testnet asset stand-ins, price feeds +
registry, rate model, the ETH/USDC market, the token trio, and the factory.
The deploy script is exercised by `DeploySmoke.t.sol` (roles, oracle
wiring, deposit→borrow→repay round trip). Verified source is a tag claim:
the Ch 13 `release.yml` gate re-runs the full suite on `v*` tags and
records the artifact hash, so deployed bytecode is traceable to source.

## 6. Roadmap (beyond the curriculum)

- Real liquidation engine (v1 `liquidate()` is a documented stub).
- Mainnet-grade oracle wiring (real Chainlink feeds + TWAP markets).
- Full Aave-style configurator for cross-parameter governance.
- Timelock + governor contract wiring for the vault admin role.

## 7. Risk disclosures

- Educational codebase; no independent audit.
- Testnet-only assets; no real value at risk.
- v1 vault is non-upgradeable (plain storage) by design.
- The liquidation engine and oracle deviation guard are the first
  priorities for any productionization.
