# Meridian Finance — Curriculum

The theory track of the Meridian Finance project: a 40-chapter Web3 engineering
curriculum (EVM → Solidity → storage/gas → testing → token standards → lending
core → security → L2s → account abstraction → full-stack). Every chapter's lab
is materialized, compile-verified, and tested in the `src/` + `test/`
directories of this repository.

Each chapter below is the finalized revision (2026-08), written to be read
standalone or in sequence.

## Module 1 — EVM & Solidity Foundations

| # | Chapter | File | Status |
|---|---------|------|--------|
| 1 | The EVM Execution Model | [`chapters/01_The_EVM_Execution_Model.md`](chapters/01_The_EVM_Execution_Model.md) | ✅ Finalized |
| 2 | Solidity Language Essentials | [`chapters/02_Solidity_Language_Essentials.md`](chapters/02_Solidity_Language_Essentials.md) | ✅ Finalized |
| 3 | ABI Encoding & Data Locations | [`chapters/03_ABI_Encoding_and_Data_Locations.md`](chapters/03_ABI_Encoding_and_Data_Locations.md) | ✅ Finalized |
| 4 | Integer Arithmetic & Units | [`chapters/04_Integer_Arithmetic_and_Units.md`](chapters/04_Integer_Arithmetic_and_Units.md) | ✅ Finalized |
| 5 | Contract Lifecycle & CREATE2 | [`chapters/05_Contract_Lifecycle_and_CREATE2.md`](chapters/05_Contract_Lifecycle_and_CREATE2.md) | ✅ Finalized |

> Chapters 6+ are in progress — they ship here as they are finalized.

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
