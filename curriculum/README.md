# Meridian Finance — Curriculum

The theory track of the Meridian Finance project: a 40-chapter Web3 engineering
curriculum (EVM → Solidity → storage/gas → testing → token standards → lending
core → security → L2s → account abstraction → full-stack). Every chapter's lab
is materialized, compile-verified, and tested in the `src/` + `test/`
directories of this repository.

Each chapter below is the finalized revision (2026-08), written to be read
standalone or in sequence.

## Module 1 — EVM & Solidity Foundations (Ch 1–5)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 1 | The EVM Execution Model | [`chapters/01_The_EVM_Execution_Model.md`](chapters/01_The_EVM_Execution_Model.md) | ✅ Finalized |
| 2 | Solidity Language Essentials | [`chapters/02_Solidity_Language_Essentials.md`](chapters/02_Solidity_Language_Essentials.md) | ✅ Finalized |
| 3 | ABI Encoding & Data Locations | [`chapters/03_ABI_Encoding_and_Data_Locations.md`](chapters/03_ABI_Encoding_and_Data_Locations.md) | ✅ Finalized |
| 4 | Integer Arithmetic & Units | [`chapters/04_Integer_Arithmetic_and_Units.md`](chapters/04_Integer_Arithmetic_and_Units.md) | ✅ Finalized |
| 5 | Contract Lifecycle & CREATE2 | [`chapters/05_Contract_Lifecycle_and_CREATE2.md`](chapters/05_Contract_Lifecycle_and_CREATE2.md) | ✅ Finalized |

## Module 2 — Storage & Gas Mechanics (Ch 6–9)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 6 | Storage Layout & Packing | [`chapters/06_Storage_Layout_and_Packing.md`](chapters/06_Storage_Layout_and_Packing.md) | ✅ Finalized |
| 7 | Gas Mechanics | [`chapters/07_Gas_Mechanics.md`](chapters/07_Gas_Mechanics.md) | ✅ Finalized |
| 8 | Gas Optimization Patterns | [`chapters/08_Gas_Optimization_Patterns.md`](chapters/08_Gas_Optimization_Patterns.md) | ✅ Finalized |
| 9 | Yul & Inline Assembly | [`chapters/09_Yul_and_Inline_Assembly.md`](chapters/09_Yul_and_Inline_Assembly.md) | ✅ Finalized |

## Module 3 — Testing & Foundry Mastery (Ch 10–13)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 10 | Foundry Workflow | [`chapters/10_Foundry_Workflow.md`](chapters/10_Foundry_Workflow.md) | ✅ Finalized |
| 11 | Unit Testing & Fork Testing | [`chapters/11_Unit_Testing_and_Fork_Testing.md`](chapters/11_Unit_Testing_and_Fork_Testing.md) | ✅ Finalized |
| 12 | Fuzzing & Invariant Testing | [`chapters/12_Fuzzing_and_Invariant_Testing.md`](chapters/12_Fuzzing_and_Invariant_Testing.md) | ✅ Finalized |
| 13 | CI/CD & Static Analysis | [`chapters/13_CI_CD_and_Static_Analysis.md`](chapters/13_CI_CD_and_Static_Analysis.md) | ✅ Finalized |

## Module 4 — Token Standards (Ch 14–17)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 14 | ERC20 Deep Dive | [`chapters/14_ERC20_Deep_Dive.md`](chapters/14_ERC20_Deep_Dive.md) | ✅ Finalized |
| 15 | Governance Tokens | [`chapters/15_Governance_Tokens.md`](chapters/15_Governance_Tokens.md) | ✅ Finalized |
| 16 | ERC4626 Vaults | [`chapters/16_ERC4626_Vaults.md`](chapters/16_ERC4626_Vaults.md) | ✅ Finalized |
| 17 | Token Security Patterns | [`chapters/17_Token_Security_Patterns.md`](chapters/17_Token_Security_Patterns.md) | ✅ Finalized |

## Module 5 — AMMs & Lending Core (Ch 18–23)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 18 | AMMs: Constant Product | [`chapters/18_AMMs_Constant_Product.md`](chapters/18_AMMs_Constant_Product.md) | ✅ Finalized |
| 19 | Concentrated Liquidity | [`chapters/19_Concentrated_Liquidity.md`](chapters/19_Concentrated_Liquidity.md) | ✅ Finalized |
| 20 | Lending Markets I: Collateral & LTV | [`chapters/20_Lending_Markets_I_Collateral_and_LTV.md`](chapters/20_Lending_Markets_I_Collateral_and_LTV.md) | ✅ Finalized |
| 21 | Lending Markets II: Interest Rates | [`chapters/21_Lending_Markets_II_Interest_Rates.md`](chapters/21_Lending_Markets_II_Interest_Rates.md) | ✅ Finalized |
| 22 | Oracles | [`chapters/22_Oracles.md`](chapters/22_Oracles.md) | ✅ Finalized |
| 23 | Staking & Revenue Share | [`chapters/23_Staking_and_Revenue_Share.md`](chapters/23_Staking_and_Revenue_Share.md) | ✅ Finalized |

## Module 6 — Security & Auditing (Ch 24–28)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 24 | Reentrancy & Control Flow | [`chapters/24_Reentrancy_and_Control_Flow.md`](chapters/24_Reentrancy_and_Control_Flow.md) | ✅ Finalized |
| 25 | Access Control & Trust Chains | [`chapters/25_Access_Control_and_Trust_Chains.md`](chapters/25_Access_Control_and_Trust_Chains.md) | ✅ Finalized |
| 26 | Arithmetic & Invariant Failures | [`chapters/26_Arithmetic_and_Invariant_Failures.md`](chapters/26_Arithmetic_and_Invariant_Failures.md) | ✅ Finalized |
| 27 | Cross-Chain & Bridge Security | [`chapters/27_Cross_Chain_and_Bridge_Security.md`](chapters/27_Cross_Chain_and_Bridge_Security.md) | ✅ Finalized |
| 28 | Auditing Methodology | [`chapters/28_Auditing_Methodology.md`](chapters/28_Auditing_Methodology.md) | ✅ Finalized |

## Module 7 — L2s & Cross-Chain (Ch 29–32)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 29 | Rollup Architectures | [`chapters/29_Rollup_Architectures.md`](chapters/29_Rollup_Architectures.md) | ✅ Finalized |
| 30 | Post-Fusaka Data Availability | [`chapters/30_Post_Fusaka_Data_Availability.md`](chapters/30_Post_Fusaka_Data_Availability.md) | ✅ Finalized |
| 31 | Deploying on L2 | [`chapters/31_Deploying_on_L2.md`](chapters/31_Deploying_on_L2.md) | ✅ Finalized |
| 32 | Bridges & Messaging Protocols | [`chapters/32_Bridges_and_Messaging_Protocols.md`](chapters/32_Bridges_and_Messaging_Protocols.md) | ✅ Finalized |

## Module 8 — Account Abstraction & MEV (Ch 33–35)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 33 | Account Abstraction | [`chapters/33_Account_Abstraction.md`](chapters/33_Account_Abstraction.md) | ✅ Finalized |
| 34 | MEV Fundamentals | [`chapters/34_MEV_Fundamentals.md`](chapters/34_MEV_Fundamentals.md) | ✅ Finalized |
| 35 | MEV-Aware Protocol Design | [`chapters/35_MEV_Aware_Protocol_Design.md`](chapters/35_MEV_Aware_Protocol_Design.md) | ✅ Finalized |

## Module 9 — Full-Stack & Operations (Ch 36–38)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 36 | Frontend Stack: Viem + Wagmi + Next.js | [`chapters/36_Frontend_Stack_Viem_Wagmi_Nextjs.md`](chapters/36_Frontend_Stack_Viem_Wagmi_Nextjs.md) | ✅ Finalized |
| 37 | Indexing & Analytics | [`chapters/37_Indexing_and_Analytics.md`](chapters/37_Indexing_and_Analytics.md) | ✅ Finalized |
| 38 | Upgradeability & Operations | [`chapters/38_Upgradeability_and_Operations.md`](chapters/38_Upgradeability_and_Operations.md) | ✅ Finalized |

## Module 10 — Capstone (Ch 39–40)

| # | Chapter | File | Status |
|---|---------|------|--------|
| 39 | Capstone Prep: Full-System Audit | [`chapters/39_Capstone_Prep_Full_System_Audit.md`](chapters/39_Capstone_Prep_Full_System_Audit.md) | ✅ Finalized |
| 40 | Capstone: Launch | [`chapters/40_Capstone_Launch.md`](chapters/40_Capstone_Launch.md) | ✅ Finalized |

## How to read a chapter

Every chapter follows a locked structure:

**Learning Objectives → Theory → Mathematical Foundations → Code Walkthrough →
Production Reference → Foundry Lab → Security Analysis → Gas Optimization →
Common Mistakes → Exercises → Quiz → Further Reading**

The Foundry Lab in each chapter maps to a real, passing test suite in this
repo. Run it with:

```bash
forge test
```
