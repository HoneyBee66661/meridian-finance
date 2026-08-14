# Meridian CI/CD & Static-Analysis Playbook (Ch 13)

> Deliverable of Ch 13 — CI/CD & Static Analysis. Materialized 2026-08-13,
> compile-verified in-run (forge 1.7.1, solc 0.8.24, cancun, optimizer 200).
> This is the first weekly-project doc materialized to disk (recorded in the
> continuity ledger).

## 1. The gate chain

Every PR must pass, in order (cheapest first — a fmt failure must never burn RPC minutes):

| # | Gate | Command | Catches | Fails on |
|---|------|---------|---------|----------|
| 1 | Format | `forge fmt --check` | style drift | any unformatted file |
| 2 | Build | `forge build --sizes` | compile errors, EIP-170 24 KB | oversize contract |
| 3 | Unit + fuzz | `forge test -vvv` | behavior regressions | any failing test |
| 4 | Invariant | same run | state-machine drift (Ch 12) | violated invariant |
| 5 | Gas | `forge snapshot --check --diff --tolerance 20` | gas regressions | delta > 20 |
| 6 | Coverage | `forge coverage --report summary` | untested branches | threshold |
| 7 | SAST | `slither . --config-file slither.config.json` | vulnerable patterns | exit code |
| 8 | SAST | `Cyfrin/aderyn-action@v1` | patterns (2nd opinion) | SARIF findings |

Fork tests are NOT on the PR path: `fork.yml` runs on merge-to-main + nightly cron
(`MAINNET_RPC_URL` secret; tests self-skip per Ch 11 when unset).

## 2. Seeds & determinism

- `foundry.toml` → `[profile.ci.fuzz] seed = "0x0000…04d2"` (1234). **Must be a 32-byte
  hex string** — `seed = 1234` fails config parsing (verified in-run).
- `ci.yml` also sets `FOUNDRY_FUZZ_SEED: "1234"` (env var wins over config).
- Any red fuzz/invariant run replays byte-identically with the same seed (Ch 12).
- Retries are banned as flakiness policy: fix determinism, don't mask reds.
- `forge config --profile ci` is NOT valid in 1.7.1 — use `FOUNDRY_PROFILE=ci forge config`.

## 3. The gas snapshot gate

- `.gas-snapshot` is committed; `forge snapshot --check` compares the live run against it.
- **Generate AND check under the pinned CI seed** (`FOUNDRY_PROFILE=ci forge snapshot` /
  `FOUNDRY_PROFILE=ci forge snapshot --check`): fuzz-test rows are `(runs: 1000, μ, ~)`
  stats that move with the PRNG (verified in-run: `testMcopyMatchesLoop` μ swung
  1,056,092 → 1,044,575 across seeds, ~1.1%, not a regression). An unpinned local
  `--check` flakes on fuzz rows by construction; `ci.yml` pins via
  `[profile.ci.fuzz] seed` + `FOUNDRY_FUZZ_SEED`.
- Tolerance 20: ~100× below a cold SLOAD (2,100, Ch 7), above runner noise (≈0 with
  pinned solc + fixed runner image). Raising it lets regressions ship silently.
- Ch 20's `MeridianVault` borrow/repay tests enter the snapshot; the ~101,500-gas net
  borrow-path budget (Ch 8) becomes CI-enforced.
- Lab receipt: `test_withdrawChecked_paysOut_withReturndataGate` = 38,138 gas,
  +679 over the unchecked twin — the Ch 9 returndata gate, permanently priced.

## 4. Slither

- Config: `slither.config.json` (strict JSON — no comments).
- `filter_paths` excludes lib/test/script + lab probes (`Probe|Mini|EvmMiniature|StorageLab`)
  from the protocol gate. Lab-targeted run:
  `slither src/StaticProbe.sol --compile-force-framework foundry` — expected hits:
  `unchecked-transfer` (Medium), `tx-origin` (Medium), `missing-zero-check` (Low);
  Aderyn: `unsafe-erc20-operation`, `centralization-risk`, `zero-address-check`.
- Severity gate flags: `--fail-high` / `--fail-medium` / `--fail-pedantic`. Meridian:
  plain exit code now; `--fail-medium` once the protocol surface exists (Ch 14+).
- Triage discipline: every finding triaged in the PR; exclusions carry written reasons;
  the triage log is a review artifact. Mass-`--exclude` fakes SAST green.

## 5. Supply-chain hardening (checklist)

- [ ] Actions pinned to full commit SHA; `dependabot` (`github-actions` ecosystem) proposes updates
- [ ] `permissions: contents: read` on every job that doesn't need write
- [ ] `persist-credentials: false` on checkout
- [ ] Secrets only in GitHub Secrets; never in repo/env
- [ ] OIDC (`id-token: write` + workload identity) over static keys for deploys
- [ ] `concurrency` groups cancel stale runs
- [ ] `forge install` pinned to tags, never branches
- [ ] Deploy step behind an `environment:` approval gate (release.yml, wired at Ch 39)

Incident map: Ledger Connect Kit (Dec 2023) — distribution channel; tj-actions/
changed-files (Mar 2025, CVE-2025-30066) — action channel; Codecov (Apr 2021) — trusted
helper script; SolarWinds (Dec 2020) — signed-but-poisoned build; event-stream (Nov 2018)
— dependency tree. 2026 grounding: Kelp DAO/Drift (~$285–292M) — a CI deploy key is an admin key.

## 6. The five-question CI audit

1. What is pinned (actions, seeds, solc, blocks)?
2. What is scoped (token permissions, secrets, environments)?
3. What secrets exist, and where could a compromised runner exfiltrate them?
4. Which gate catches a regression in the protocol's most expensive path (borrow/repay)?
5. What would a compromised action or runner be able to do — and is that acceptable?

## 7. Known follow-ups

- Ch 14: `MeridianToken.sol` enters the gate; error catalog finalized.
- Ch 20: vault snapshot entries; borrow-path budget enforced.
- Ch 28/39: audit consumes pipeline artifacts (test history, SAST triage, gas deltas).
- Ch 39: `release.yml` deploy job wired (OIDC, environment protection, source verification).
