# 15. Governance Tokens

## Learning Objectives

By the end of this chapter you will be able to:

1. Explain how Compound popularized checkpointed voting (May 2020), what ERC-5805 standardized from it, and what ERC-6372's clock abstraction decouples — reading both as the OZ v5.7 `Votes` module the protocol inherits.
2. State the exact OZ v5 delegation semantics, verified against the vendored source: voting units *must* be delegated to count, undelegated units live only in the total-supply checkpoint, `delegate(address(0))` **undelegates** — it removes your voting power from your previous delegate (a no-op only if you were never delegated), and `getPastVotes` enforces a strictly-past lookup (`ERC5805FutureLookup`).
3. Implement and test `delegateBySig` end-to-end: the `Delegation(address delegatee,uint256 nonce,uint256 expiry)` typehash, replay/expiry/tamper rejection — and the nonce collision with ERC-2612 permit that OZ v5's shared `Nonces` base makes real.
4. Ship the second Meridian protocol contract: `MeridianGovernanceToken.sol` (gMER), the ERC-5805/ERC-6372 wrapper around MER — zero privileged surface, deposit/withdraw 1:1, conservation invariant pinned by fuzzing + invariants.
5. Explain the Beanstalk-shaped flash-vote hazard (Apr 2022, ~$182M) with the checkpoint math: checkpoints make voting power *historical*, while the voting delay — pushing the snapshot into the past, unreachable by a same-block flash loan — keeps newly acquired power out of that history; the two solve different problems and both are required (Ch 25 wires it).
6. Measure the checkpoint machinery honestly: delegate/deposit/withdraw/delegateBySig per-call gas, same-block coalescing, and the sqrt-probe lookup over a 1,001-checkpoint history.

## Prerequisites

- **Chapter 14** (ERC20 Deep Dive) — MER's locked design (hookless token, OZ v5 base, the C3 `nonces` diamond, the four SSTORE regimes), the EIP-712 domain/`chainId` replay story, and the error-catalog canon (`IERC20Errors`/ERC-2612/`IAccessControl`).
- **Chapter 3** (ABI Encoding & Data Locations) — EIP-712 typed-data hashing as an ABI subset; the selector/domain math behind `delegateBySig`.
- **Chapter 12** (Fuzzing & Invariant Testing) — the `bound`-over-`vm.assume` handler rule and `fail_on_revert = true`, applied to the wrapper-conservation invariant.

Supporting references: **Ch 2** (custom errors in interfaces), **Ch 7/8** (gas schedule + measurement methodology: loop-amplified min-deltas, never `--gas-report`, warm-up first), **Ch 10** (parameter-exact `vm.expectRevert`; cheatcode discipline), **Ch 13** (the `--sizes` + snapshot gates watching this contract from day one). Locked conventions remain in force.

## Theory

### Why checkpoints exist: the double-vote problem

Before governance tokens had history, voting power was a *current* balance — so an attacker could borrow a token, vote, and return it, paying only the borrow fee for a governance outcome. The canonical answer is Compound's `Comp` (May 2020): a token checkpointed per block, with `getPriorVotes(account, blockNumber)` reading the *last checkpoint at or before* a given block. Uniswap forked it for UNI (Sep 2020). The shaping constraint: history must be *append-only and cheap* — a `(blockNumber, votes)` pair written only when the value changes, so a holder who never moves costs one entry.

The OZ v5.7 `Votes` docstring states the rationale directly: *"The full history of delegate votes is tracked on-chain so that governance protocols can consider votes as distributed at a particular block number to protect against flash loans and double voting. The opt-in delegate system makes the cost of this history tracking optional."* That last sentence is the design insight: tracking is per-delegate, so only governance participants pay for it.

### ERC-5805: voting with delegation

ERC-5805 (drafted by OpenZeppelin's Hadrien Croubois; the current EIP document is marked **STAGNANT**, not Final) standardized the surface `Comp` pioneered: `getVotes(account)` (current power), `getPastVotes(account, timepoint)` (historical power), `getPastTotalSupply(timepoint)` (historical total, for quorum), `delegates(account)`, `delegate(delegatee)`, and `delegateBySig(delegatee, nonce, expiry, v, r, s)`, plus the events `DelegateChanged` and `DelegateVotesChanged`. OZ v5's `Votes` is the reference implementation; its semantics — verified in the vendored v5.7.0 source — have three surprising properties:

1. **Voting units must be delegated to count.** The docstring: *"voting units _must_ be delegated in order to count as actual votes, and an account has to delegate those votes to itself if it wishes to participate."* `_transferVotingUnits` moves votes between `delegates(from)` and `delegates(to)` — and an undelegated account has delegate `address(0)`, so its units appear in **no one's** `getVotes`. They are not lost: `getPastTotalSupply` includes them (its docstring: *"Votes that have not been delegated are still part of total supply, even though they would not participate in a vote"*). The lab pins this: hold 1,000 gMER, never delegate → `getVotes(you) == 0`, `getVotes(0) == 0`, `getPastTotalSupply` = 1,000.
2. **`delegate(address(0))` undelegates.** The Comp-era folklore says undelegated votes "pool at the zero address." False in OZ v5.7 — but the mirror-image claim is false too: delegating to zero is *not* inert. `_delegate` sets `_delegatee[account] = address(0)` and calls `_moveDelegateVotes(oldDelegate, 0, amount)`; with `from != to` and `from != address(0)`, the previous delegate's checkpoint is **subtracted** — the account's voting power stops counting there. It produces no checkpoint only when the account was **already** undelegated (`0 → 0` short-circuits on `from == to`). ERC-5805 agrees: tokens delegated to `address(0)` are not tracked (the lab pins both paths; `test_delegateToZero_isInert` covers the already-undelegated case).
3. **The lookup is strictly past.** `_validateTimepoint` reverts `ERC5805FutureLookup(timepoint, clock())` whenever `timepoint >= clock()`: you cannot query the *current* block, because its checkpoint is not yet final. A governor snapshotting at `proposalBlock − votingDelay` is always strictly in the past at vote time — exactly the property the flash-vote defense needs (below).

> **Voting supply ≠ active delegated voting power.** `getPastTotalSupply` counts *all* units, undelegated ones included; `sum(getVotes)` counts only what is delegated. Quorum math must never conflate the two.

### ERC-6372: the clock abstraction

ERC-5805's timepoints are abstract; ERC-6372 (also Croubois; currently in Review status) is the *interface/clock standard* — it defines how a contract *describes* its clock: `clock()` returns a `uint48` timepoint, and `CLOCK_MODE()` returns a machine-readable description. The standard mandates the interface, not an implementation; OZ `Votes` is one implementation of that clock. In OZ v5.7 the block-number mode returns the exact string **`"mode=blocknumber&from=default"`** (verified in the vendored `ERC6372Utils`, which also reverts `ERC6372InconsistentClock` if a modified `clock()` disagrees with `block.number`); the timestamp variant returns `"mode=timestamp"`.

Why a clock at all? Because "block number" is a terrible time unit on some chains: on L2s whose block numbers advance faster than wall-clock time (Arbitrum-class), a delay of "100 blocks" means minutes, not hours. A timestamp clock makes delays time-honest. For Meridian's mainnet deployment, `mode=blocknumber` is the right default — gMER inherits it from `Votes` — and the L2 deployment (Ch 31) is where the timestamp-mode discussion becomes concrete. The widths matter too: timepoints and values are packed (`uint48` key, `uint208` value in `Trace208`), which is why OZ `ERC20Votes` caps supply at 2^208−1 (COMP's original design was `uint96` — a 2^96 cap, per the vendored docstring).

### Why gMER is a wrapper, not an ERC20Votes MER

MER shipped in Ch 14 with a locked inheritance graph and storage layout. Retrofitting `Votes` would change both — an upgrade, not an extension. Instead, gMER **wraps** MER: deposit MER, receive gMER 1:1; gMER balance *is* voting power, checkpointed. Three consequences make this the right call:

1. **MER stays cheap and liquid.** Plain MER transfers pay no checkpoint overhead. The vote-tracking cost lands only on governance participants who deposit into the wrapper.
2. **The wrapper has zero privileged surface.** No roles, no mint key, no rescue function — total supply is exactly the deposited MER (the conservation invariant). Contrast with MER, whose single `MINTER_ROLE` is a governance-held key. gMER is the first Meridian contract with **no privileged administrative key** (no role, no mint key, no rescue function) — the precise, defensible version of "nothing to compromise."
3. **There is production precedent.** Aave's `stkAAVE` is a staked wrapper whose balance Aave governance counts; the pattern is proven.

The tradeoff is worth naming: quorum over `getPastTotalSupply` of gMER is quorum over *deposited* MER — inactive holders don't inflate the denominator, but the governance-active supply is smaller and proportionally easier to dominate. Ch 25's governor picks the quorum base; this chapter makes both numbers readable.

## Mathematical Foundations

### Checkpoint semantics

A delegate's history is a sorted array of `(timepoint, votes)` pairs, append-only, written only on change. The value at timepoint `t` is the last checkpoint with key ≤ `t`:

```
votes(t) = checkpoints[upperBound(t) - 1].value   (0 if none)
```

with the strictly-past rule `t < clock()`. Because entries are per-delegate, the per-user storage cost is O(#times the user's vote *changed*), not O(#blocks).

**Same-block coalescing.** `Trace208.push` merges writes with the same key: N vote movements in one transaction produce **one** checkpoint entry (the last value). The lab pins it: three transfers in one block move bob's checkpoint 1,000 → 900 → 910 but leave `numCheckpoints(bob) == 1`. This is the storage analog of the Ch 8 dirty-SSTORE regime — batch operations pay the checkpoint write once.

### Vote movement accounting

When Alice (balance `a`, delegate `D_A`) transfers `t` to Bob (delegate `D_B`):

```
D_A loses t   (checkpoint push, key = clock())
D_B gains t   (checkpoint push, key = clock())
```

When Alice delegates to `D` (from old delegate `D_old`) — including the **undelegate** case `D == address(0)`:

```
D_old loses a   (skipped if D_old == D or D_old == 0)
D gains a       (skipped if D == 0 — zero-delegated votes are not tracked)
```

An undelegated holder is `D = 0` on both sides — the `from == to` shortcut makes the whole movement a no-op, which is the *must-delegate-to-count* rule in arithmetic form. Total-supply checkpoints move only on mint/burn, which is why `getPastTotalSupply` tracks the wrapper's deposits/withdrawals exactly.

### Lookup cost: binary search with a sqrt probe

`getPastVotes` is a binary search over the checkpoint array: ~`log2(N)` SLOADs for N entries. OZ's `upperLookupRecent` adds one optimization: for `N > 5` it probes the entry at `N − sqrt(N)` with a single comparison, splitting the array into a `sqrt(N)`-sized recent window and the rest, then binary-searches the relevant half. Recent lookups (the common case) cost ~`log2(sqrt(N))` SLOADs. The lab measures a 1,001-checkpoint history: **4,576 gas recent vs 5,971 oldest** — a real ~1.4K delta at this depth, widening with history length. A transfer writes a checkpoint that a ~4.6K-gas lookup reads for the life of the protocol; history is cheap to *write* because it is cheap to *read*. Exact gas is implementation-, compiler-, and environment-dependent — these are single-lab measurements, not protocol constants.

### The flash-vote timing equation (Beanstalk, April 2022)

Beanstalk's April 2022 exploit (~$182M in the curriculum's canon) was the canonical flash-governance attack: the attacker flash-loaned enough governance power to dominate a vote, passed a malicious proposal, and executed it in one transaction. The checkpoint math shows why the *pair* of defenses matters:

- Votes are read at snapshot timepoint `S = proposalBlock − votingDelay`.
- A same-block flash deposit+delegate writes a checkpoint with key `proposalBlock`.
- With `votingDelay = 0`: `S = proposalBlock`, the flash checkpoint **is** the snapshot, and the attack works. The lab's `test_flashDeposit_votesVisibleAtSnapshotBlock` demonstrates it concretely: deposit+delegate at block `S` is counted at `S`, and withdrawing a block later cannot rewrite the historical checkpoint.
- With `votingDelay ≥ 1`: `S < proposalBlock`, so `getPastVotes` at `S` predates the flash deposit — the borrowed power is invisible, and the flash loan expires before any real proposal could pass.

Checkpointing makes the past *queryable*; the delay makes the past *unreachable* by a same-block loan. Both are required; either alone fails (Beanstalk had effectively neither at the critical moment). Typical real governors run delays of days — Uniswap's UNI governor uses approximately a 2-day delay and 3-day period.

### The wrapper invariant

gMER's core identity is the conservation **bound**:

```
gmer.totalSupply() <= mer.balanceOf(address(gmer))   — at every transaction boundary
```

with the difference named explicitly:

```
surplus = mer.balanceOf(address(gmer)) - gmer.totalSupply()
```

deposit pulls MER then mints 1:1; withdraw burns 1:1 then releases, so every state transition through `deposit`, `depositFor`, and `withdraw` preserves **equality when surplus is zero** — and once surplus exists it is unrecoverable. There is no share-price math (unlike sMER's ERC-4626 in Ch 16/23), so there is no inflation/donation *attack* surface: a direct MER donation bumps `mer.balanceOf(gMER)` without minting, creating surplus that changes no one's balance or voting power — deliberately unrecoverable (a rescue function would be a new admin key; see Security Analysis). The invariant suite pins the `<=` bound plus equality across wrapper-driven transitions, not a universal equality.

## Mermaid Diagram

```mermaid
sequenceDiagram
    participant A as Alice (holder)
    participant G as gMER (Votes)
    participant B as Bob (delegate)
    participant P as Proposal (Ch 25)

    Note over A,G: Wrap MER -> voting power
    A->>G: deposit(1000 MER)
    G->>G: mint 1000 gMER, checkpoint totalSupply
    A->>G: delegate(Bob)
    G->>G: move 1000 votes to Bob, checkpoint(Bob, block N)

    Note over P,G: Snapshot at S = proposalBlock - votingDelay
    P->>G: getPastVotes(Bob, S) = 1000
    P->>G: getPastTotalSupply(S) = 1000

    Note over A,G: Flash-vote shape (delay = 0, the Beanstalk hazard)
    A->>G: deposit(1M) + delegate(self) in ONE block S
    G->>G: checkpoint key = S — visible at snapshot S
    A->>G: withdraw(1M) next block
    G->>G: historical checkpoint at S is immutable — votes still count
    Note over P,G: Snapshot is read after block S; getPastVotes(..., S) is strictly-past
```

## Code Walkthrough

**`meridian/src/IMeridianGovernanceToken.sol`** — the protocol-facing surface: `IERC20 + IERC20Permit + IERC5805` (which brings `IERC6372` + `IVotes`), the `Deposited`/`Withdrawn` events, `mer()`, `deposit`/`depositFor`/`withdraw`, and exactly two protocol errors: `InvalidConstructorAddress` and `ERC20ExceededSafeSupply` (the latter mirroring OZ `ERC20Votes`' cap error — checkpoint values live in a `uint208`, so supply past 2^208−1 cannot be represented). The rest of the error catalog is the OZ interface set, per the Ch 2/14 canon.
**`meridian/src/IMeridianGovernanceToken.sol`** — the protocol-facing surface: `IERC20 + IERC20Permit + IERC5805` (which brings `IERC6372` + `IVotes`), the `Deposited`/`Withdrawn` events, `mer()`, `deposit`/`depositFor`/`withdraw`, and exactly two protocol errors — `InvalidConstructorAddress` and `ERC20ExceededSafeSupply` (the latter mirroring OZ `ERC20Votes`' cap error: checkpoint values live in a `uint208`, so supply past 2^208−1 cannot be represented). The rest of the catalog is the OZ interface set, per the Ch 2/14 canon.

**`meridian/src/MeridianGovernanceToken.sol`** — `is ERC20, ERC20Permit, Votes, IMeridianGovernanceToken`. Three hand-written pieces sit on the OZ v5.7.0 bases — widely reviewed code, but an external library's review does not audit Meridian's inheritance choices, wrapper logic, or governance parameters:

- `deposit`/`depositFor`/`withdraw` — the wrapper. `depositFor` **pulls-then-mints** (interaction before effect): the one deliberate, documented exception to strict CEI, safe *only* because the underlying is constructor-pinned MER — hookless per Ch 14 — so `transferFrom` cannot reenter, and pull-first keeps the conservation invariant true at every intermediate state. `withdraw` is strict CEI (burn, then release). The docstring names the guarded bug class, per the Ch 9 convention.
- `_update` — the `ERC20Votes` v5.7 wiring, copied with attribution: `super._update`, then the 2^208−1 supply-cap check, then `_transferVotingUnits(from, to, value)`. This single override is what makes every transfer/mint/burn move votes.
- `nonces` — the C3 diamond, **with a twist vs MER**. Error 6480 required an explicit override; error 4327 then required `Nonces` in the override list, because `Votes` adds a *second* inheritance path to `Nonces` (`Votes is Context, EIP712, Nonces, IERC5805`). The final signature is `override(ERC20Permit, IERC20Permit, Nonces)` — Ch 14's "Nonces must NOT be listed" was specific to MER's graph (where `AccessControl` does not inherit `Nonces`). Graph-specific override lists are now a pinned pattern, not a remembered rule.

**`meridian/test/MeridianGovernanceToken.t.sol`** — 39 tests: wrapper mechanics (1:1 mint/burn, parameter-exact zero-address/allowance reverts, revert atomicity), delegation (self, third-party, vote movement on transfer, undelegated/undelegate semantics), historical votes (strictly-past, future revert, checkpoint immutability), `delegateBySig` (third-party submission, replay, expiry, tamper), the shared-nonce collision both directions, the flash-vote demo, coalescing, donation surplus (supply-unchanged, MER-stuck), three fuzz pins, and six gas probes. **`MeridianGovernanceTokenHandler.sol` + `MeridianGovernanceTokenInvariant.t.sol`** — a 4-op handler (deposit/withdraw/transfer/delegate, every revert edge clamped with `bound` per Ch 12) pinning wrapper conservation — the `totalSupply <= balanceOf(wrapper)` bound, equality across `deposit`/`depositFor`/`withdraw` transitions: **256×64 = 16,384 sequences, 0 reverts, green.**

## Production Example

**gMER in the Meridian protocol.** Users who want a say deposit MER into gMER; the wrapper checkpoints their power per block. Ch 25's `MeridianGovernor` will read `getPastVotes(account, snapshot)` at `snapshot = proposalBlock − votingDelay` and `getPastTotalSupply(snapshot)` for quorum — the exact reads this chapter's tests pin. Three design properties carry into production:

1. **The wrapper is permissionless and roleless.** Anyone can deposit/withdraw/delegate at any time; there is no privileged function to target, and no governance key to compromise for *this* contract (the 2026 trust surface — Kelp DAO/Drift, ~$285–292M — is about execution keys, which live in Ch 25's timelock/multisig, not here).
2. **MER liquidity is untouched.** MER remains the freely transferable asset (Ch 14); only governance participants pay the checkpoint premium, inside the wrapper.
3. **`delegateBySig` gives delegation markets their primitive.** A signed delegation is a transferable intent — which is a feature (gasless delegation, ENS-style delegate campaigns) and a risk surface (see Security Analysis #2).

## Foundry Lab

Materialized and **compile-verified in this run** (forge 1.7.1, solc 0.8.24, cancun, optimizer 200):

- **New artifacts:** `src/IMeridianGovernanceToken.sol`, `src/MeridianGovernanceToken.sol` (protocol contract #2), `test/MeridianGovernanceToken.t.sol` (39 tests incl. 3 fuzz + 6 gas probes), `test/MeridianGovernanceTokenHandler.sol` + `test/MeridianGovernanceTokenInvariant.t.sol` (wrapper conservation — `<=` bound, 16,384 calls, 0 reverts). `.gas-snapshot` regenerated to **204 rows** under `FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=1234`; paired `--check` green (the Ch 14 rule: always regenerate + check in one command).
- **Full repo suite: 199 passed / 0 failed / 6 skipped (205 total) across 21 suites** (Ch 14 baseline 159/0/6 across 19; +40 tests, +2 suites). The 6 skips remain the Ch 11 fork tests.
- **Contract size:** `MeridianGovernanceToken` **8,055 B runtime / 16,521 B margin** (vs MER 4,782 B / 19,794 B — the Votes machinery costs +3,273 B; EIP-170 healthy, Ch 13's `--sizes` gate watching).
- **Real findings, all kept:**
  1. *The override list is graph-specific, not remembered.* Error 6480 then 4327: with `Votes` in the graph, `nonces` needs `override(ERC20Permit, IERC20Permit, Nonces)` — `Nonces` must be named because Votes adds a second path to it. Ch 14's "don't list Nonces" was MER-graph-specific. Both graphs pinned by compiling tests.
  2. *Permit and delegateBySig share one EIP-712 domain AND one nonce counter* (both bases inherit `EIP712`/`Nonces`; C3 merges them). The collision is **asymmetric**, pinned both directions: permit-first → stale delegation fails `InvalidAccountNonce(alice, 1)`; delegation-first → stale permit fails `ERC2612InvalidSigner(recovered, alice)` because v5.7 `permit` hashes `_useNonce(owner)` *into* the struct (vendored line 55). Both reverts are atomic — **a failed signature burns no nonce** — so stale-signature griefing doesn't work.
  3. *`delegate(address(0))` undelegates in OZ v5.7* — from a non-zero delegation it subtracts the account's votes from the previous delegate and zeroes the delegate; only an already-undelegated account sees a no-op (`from == to`). Nothing pools at the zero address either way — the Comp-era folklore is wrong for this implementation (both paths pinned).
  4. *The Ch 14 cheatcode finding recurred (third occurrence):* `vm.prank(owner); mer.grantRole(mer.MINTER_ROLE(), handler)` pranks the `MINTER_ROLE()` view call, not the grant — the invariant suite's `setUp` failed until the role read was hoisted.
  5. *Strictly-past lookups pinned:* `getPastVotes(x, block.number)` reverts `ERC5805FutureLookup(block.number, block.number)`.
- **Gas probes (log-only, loop-amplified min-deltas, warm address first — Ch 8/9 methodology):** deposit by a delegated holder **16,060**; withdraw **15,357**; warm re-delegate **11,762**; `delegateBySig` **18,306** (EIP-712 hashing + `ecrecover` on top of a delegate — ~6.5K over the plain warm delegate); transfer with vote movement **8,934**; `getPastVotes` over 1,001 checkpoints — recent **4,576** vs oldest **5,971**. Test-level snapshot rows: deposit 152,768; delegate 229,158; delegateBySig 256,248; withdraw 239,862; the two-signature collision demo 77,976.

## Security Analysis

**1. Flash-loan governance: checkpoints and voting delay solve different problems.** Beanstalk (Apr 2022, ~$182M) proved a *current* voting balance is borrowable. Checkpointing stops the governor from treating a mutable current balance as historical voting power — it turns "current" into "historical at S". The voting delay is a *separate* defense: it makes S unreachable by a same-block loan, because power acquired at proposal time was never checkpointed at S. Neither primitive alone is the defense; the lab's demo pins the delay=0 failure mode so Ch 25's governor never ships it; any deployment with `votingDelay = 0` is re-creating Beanstalk.

**2. Delegation creates a transferable political-rights primitive.** `delegateBySig` is a signature that can be sold, bundled, and re-delegated — a protocol *capability* that vote markets and bribery systems build on. The signature function alone does not create a market; it makes the rights transferable. Vitalik's "Governance in the age of dark DAOs" (2021) named the market, and Paladin-style bribe/vote markets (2022–) run on exactly these primitives. Checkpoints cannot prevent vote buying: transferable voting power is rentable. The mitigations are governance-design (secret voting, conviction, identity-weighted schemes), not contract-level — worth stating because ERC-5805 tokens are often marketed as the fix.

**3. The shared nonce space is a UX trap, not a theft vector — and an OZ implementation coupling, not an ERC-5805 requirement.** Nothing in ERC-5805 mandates sharing a nonce counter with ERC-2612; the collision exists because OZ v5's inheritance graph routes both `ERC20Permit` and `Votes` through one `Nonces` base. Permit and delegateBySig consume one counter, so a user who signs both at nonce 0 can only land one; the other dies (asymmetrically: `InvalidAccountNonce` vs `ERC2612InvalidSigner` — pinned). The failure is loud and atomic (nothing burned): the cost is a retry, not funds. Frontends should sequence signature requests.

**4. Donations to the wrapper create unrecoverable surplus — deliberately.** No share-price math means no inflation/donation attack (that is sMER's problem, Ch 16/23); the 500-MER donation test pins supply-unchanged, MER-stuck — i.e. `mer.balanceOf(gMER) − gMER.totalSupply()` grows by 500 and stays. That is exactly why the conservation claim is the bound `totalSupply <= balanceOf(wrapper)`, with equality guaranteed only across wrapper-driven transitions (see Mathematical Foundations). No rescue function, because a rescue key is an admin key (2026 grounding): an accidental donation is gone, and there is one less key to compromise.

**5. Checkpoint spam is a bounded griefing vector.** Each `delegate()` to a new address pushes checkpoints on two delegates; an attacker can inflate a victim delegate's history with garbage entries (each ≈ an SSTORE + array growth). The attacker pays per entry; the victim pays only when reading (at 1,001 checkpoints in this lab, even the oldest entry read at 5,971 gas, with recent lookups near 4,576). Coalescing bounds same-block spam to one entry. Real, bounded, priced.

**6. On-chain voting is not the trust root.** gMER has zero privileged surface — but governance *execution* (Ch 25's timelock + multisig, and MER's `MINTER_ROLE` held by it) is where the 2026 incidents (Kelp DAO/Drift, ~$285–292M) actually landed: admin keys, not votes. A perfect voting token is a prerequisite, not a defense.

## Common Pitfalls

1. **Assuming undelegated tokens vote for their holder.** They don't — `getVotes` is 0 until delegation; quorum math must not assume `sum(getVotes) == totalSupply`.
2. **Believing `delegate(address(0))` parks votes somewhere.** Nothing pools at the zero address (pinned) — but "abstain by delegating to zero" is a real state change unless you were already undelegated: from a non-zero delegation it removes your voting power from your delegate. Undelegating explicitly is the honest way to abstain.
3. **Querying the current block.** `getPastVotes(x, block.number)` reverts `ERC5805FutureLookup`; snapshots must be strictly past — which votingDelay guarantees.
4. **Setting `votingDelay = 0`.** That is the Beanstalk configuration; the lab demonstrates the flash-vote shape it enables.
5. **Forgetting the shared nonce.** A permit and a delegation signed at the same nonce invalidate each other (asymmetrically — `InvalidAccountNonce` vs `ERC2612InvalidSigner`). Sequence them.
6. **Copying MER's `nonces` override list.** With `Votes` in the graph, `Nonces` must be listed; MER's two-entry list fails with error 4327.
7. **Hand-rolling checkpoints.** The `Trace208` packing, coalescing, and sqrt-probe lookup are subtle; the widely reviewed `Votes` base exists for a reason. (OZ's review of the library does not audit what you build on it — see Code Walkthrough.)
8. **Ignoring the 2^208−1 supply cap.** Checkpoint values are `uint208`; without the `ERC20ExceededSafeSupply` guard a large mint overflows silently.
9. **Adding a rescue function to a wrapper.** A wrapper has no share math to defend; a rescue key is just a new compromise target (2026 grounding).
10. **Reading current votes for a past decision.** Governance must use `getPastVotes` at the snapshot, never `getVotes`.

## Gas Optimization

The wrapper's hot paths are deposit/withdraw (transferFrom/burn + 1–2 checkpoint pushes) and delegate (SSTORE + 2 pushes). Measured per-call: deposit **16,060**, withdraw **15,357**, warm re-delegate **11,762**, transfer-with-votes **8,934**, `delegateBySig` **18,306**. Three optimizations are baked in, per the Ch 8 hierarchy:

- **Coalescing is free batching — for same-key updates.** Same-block vote movements targeting the *same* delegate trace write one checkpoint entry — the Ch 14 dirty-regime lesson applied to checkpoints. Different delegates or accounts still create separate entries, so a relayer's savings depend on how many of its N updates hit the same trace.
- **Undelegated deposits skip delegate checkpoints.** `_moveDelegateVotes(0, 0, …)` is a no-op; the measured 16,060 is the *delegated-holder* case (it also pushes the delegate's entry).
- **Reads stay logarithmic.** At 1,001 checkpoints in this lab, recent vs oldest lookups measured 4,576 vs 5,971 gas — lookup cost grows with `log2(N)`, but exact gas is implementation- and environment-dependent, not a universal bound. The snapshot gate (Ch 13) now carries all 40 gMER rows; future optimizations must beat them by >20 gas.

The deliberate cost: `delegateBySig` (18,306) buys gasless delegation; the plain warm delegate (11,762) is the cheap baseline for interactive users. As with MER's permit (Ch 14), the premium is a UX purchase, paid once per delegation instead of per vote.

## Reading Production Source Code

1. **OpenZeppelin `Votes.sol` (v5.7)** — the reference ERC-5805/6372 implementation: `_transferVotingUnits`, `_moveDelegateVotes`, `_validateTimepoint`, `_push`; the exact error names (`ERC5805FutureLookup`, `VotesExpiredSignature`).
2. **OpenZeppelin `ERC20Votes.sol`** — the `_update` + `_maxSupply` pattern this chapter copies with attribution; the `uint96`-vs-`uint208` note.
3. **OpenZeppelin `Checkpoints.sol` (`Trace208`)** — the packed `(uint48, uint208)` entries, coalescing push, and `upperLookupRecent`'s sqrt probe.
4. **OpenZeppelin `ERC6372Utils.sol` + `Time.sol`** — the exact `CLOCK_MODE` strings and the `ERC6372InconsistentClock` guard.
5. **OpenZeppelin `ERC20Permit.sol` (v5.5/v5.7)** — line 55: `_useNonce(owner)` inside the struct hash; the source of the asymmetric nonce collision.
6. **Compound `Comp.sol` (2020)** — the original: block checkpoints, `uint96`, `getPriorVotes`; and **Aave `StakedAave.sol`** — the wrapper precedent.

Ask of every governance token you read: *what is the clock, what is the quorum base, what happens to undelegated units, what happens to past checkpoints, and who holds the execution keys?*

## Exercises

1. Trace the vote math: Alice (1,000 gMER, delegated to Bob) transfers 400 to Carol (undelegated) in block N, then Carol delegates to Dave in block N+1. Write the checkpoint sequence for Bob and Dave; redo with both movements in block N — how many entries does each delegate end with?
2. In the flash-vote test, add `votingDelay = 5`: deposit+delegate at block N, snapshot at N−5. Show with `getPastVotes` why the flash power is invisible, and argue the delay bound (how long must a flash loan be repaid?).
3. Reproduce the asymmetric nonce collision by hand: sign a Permit and a Delegation both at nonce 0, submit the delegation first, and explain — from `ERC20Permit.permit` line 55 — why the permit fails with `ERC2612InvalidSigner` rather than `InvalidAccountNonce`.
4. Extend the invariant handler with a `depositFor` op (sender pays, recipient receives) and re-run the conservation invariant. Does it still hold? Why?
5. Design the Ch 25 governor read pattern: which calls, at which timepoint — and why does the strictly-past rule make `votingDelay` a hard requirement rather than a preference?
6. Read `Checkpoints.sol` `upperLookupRecent` and explain, line by line, what the `N − sqrt(N)` probe does for recent vs old keys.

## Weekly Project

**gMER, protocol contract #2 — materialized and verified in this run:**

1. `src/MeridianGovernanceToken.sol` + `src/IMeridianGovernanceToken.sol` — ERC-5805/ERC-6372 wrapper on OZ v5.7 `ERC20 + ERC20Permit + Votes`, zero privileged surface, conservation invariant, graph-specific `nonces` override.
2. `test/MeridianGovernanceToken.t.sol` (39 tests incl. fuzz + gas probes) + handler + invariant suite (conservation, 16,384 sequences, 0 reverts). **Verified in-run:** 199/0/6 across 21 suites, snapshot 204 rows `--check` green, EIP-170 margin 16,521 B.
3. Weekly doc `docs/governance-token-spec.md` (clock mode, delegation semantics, quorum-base guidance for Ch 25, gas profile) added to the pending-materialization debt list.
4. Protocol contract count: **2** (MER, gMER). Vault error catalog provisional to Ch 20; governor wiring lands Ch 25.

## Deliverables

1. `MeridianGovernanceToken.sol` + `IMeridianGovernanceToken.sol` — protocol contract #2, compile-verified, 8,055 B runtime / 16,521 B margin.
2. 39 tests + 1 invariant suite, all green; `.gas-snapshot` at 204 rows, paired `--check` passing; repo suite **199 passed / 0 failed / 6 skipped across 21 suites**.
3. Conventions locked: OZ v5.7 delegation semantics as measured (must-delegate, zero-delegate = undelegate, strictly-past); shared Nonces/EIP-712 space; override lists are graph-specific; wrapper has zero privileged surface and no rescue.
4. Gas profile: deposit 16,060 · withdraw 15,357 · warm delegate 11,762 · delegateBySig 18,306 · transfer-with-votes 8,934 · lookup 4,576/5,971 @ 1,001 checkpoints.

## Quiz

1. Where do undelegated voting units live in OZ v5.7 — and why does that matter for quorum math?
2. What does `delegate(address(0))` actually do in OZ v5.7, and what folklore does it contradict?
3. Why does `getPastVotes(x, block.number)` revert, and which governance parameter turns that property into a security guarantee?
4. A user signs a Permit and a Delegation both at nonce 0 and submits the delegation first. What error does the permit produce, and why isn't it `InvalidAccountNonce`?
5. Why does the gMER `nonces` override list include `Nonces` when MER's does not?
6. What does the `N − sqrt(N)` probe in `upperLookupRecent` buy, and what did the lab measure?

**Answers:** (1) Only in the total-supply checkpoint (`getPastTotalSupply`); they appear in no one's `getVotes` — so `sum(getVotes) < totalSupply` is normal, and quorum over `getPastTotalSupply` counts inactive holders. (2) It **undelegates**: `_delegate` zeroes your delegate and `_moveDelegateVotes` subtracts your votes from the previous delegate — so the voting power stops counting there (ERC-5805: zero-delegated tokens are not tracked). Only if you were already undelegated is it a no-op (`from == to` short-circuit). The folklore it contradicts: votes do not "pool at the zero address." (3) `_validateTimepoint` reverts `ERC5805FutureLookup` for `timepoint >= clock()`; with `votingDelay ≥ 1` the snapshot is strictly past, which blocks same-block flash voting. (4) `ERC2612InvalidSigner(recovered, alice)` — v5.7 `permit` hashes `_useNonce(owner)` into the struct and validates against the current nonce (1), so the stale signature recovers to a different address; the atomic revert burns nothing. (5) `Votes` adds a second inheritance path to `Nonces`, so the override must name it (error 4327); MER's graph had only one path. (6) One comparison splits the array into a `sqrt(N)` recent window vs the rest, making recent lookups ~`log2(sqrt(N))`; measured 4,576 vs 5,971 over 1,001 checkpoints.

## Further Reading

- ERC-5805 and ERC-6372 (Croubois) — the specs (ERC-5805 is currently marked STAGNANT, ERC-6372 is in Review); OZ v5 `Votes` is the reference implementation.
- Compound `Comp` (May 2020) / UNI (Sep 2020) — the originals; ENS (Nov 2021) — `ERC20Votes` at airdrop scale; Aave `stkAAVE` — the wrapper precedent.
- Beanstalk post-mortems (Apr 2022, ~$182M) — the flash-loan governance attack; the delay+checkpoint pairing.
- Vitalik Buterin, "Governance in the age of dark DAOs" (2021); Paladin vote-market write-ups (2022–) — delegation as a buyable primitive.
- 2026 security grounding: Kelp DAO/LayerZero and Drift admin-key incidents (~$285–292M, Apr 2026) — execution keys are the real trust root (Ch 25).
- Ch 16/23 (sMER — where donation/inflation math lives), Ch 25 (MeridianGovernor — the consumer of every read pinned here), Ch 31 (L2 deployment — the timestamp-clock discussion).

## Ledger Update

**Ch 15 — Governance Tokens (2026-08-13)** — full entry appended to `ledger/CONTINUITY_LEDGER.md`.

- **Second PROTOCOL contract shipped:** `MeridianGovernanceToken.sol` (gMER) + `IMeridianGovernanceToken.sol` on OZ v5.7.0 (`ERC20 + ERC20Permit + Votes`). ERC-5805/ERC-6372 wrapper, deposit/withdraw 1:1, **zero privileged surface** (no roles, no mint key, no rescue; donations create unrecoverable surplus by design — conservation is the bound `totalSupply <= balanceOf(wrapper)`), clock `mode=blocknumber&from=default`, `_update`/`_maxSupply` (2^208−1 cap) copied with attribution from `ERC20Votes`.
- **Real findings, all kept:** (1) override lists are graph-specific — with `Votes` in the graph `nonces` needs `override(ERC20Permit, IERC20Permit, Nonces)` (errors 6480 → 4327); Ch 14's "don't list Nonces" was MER-graph-specific. (2) shared EIP-712/Nonces space between permit and delegateBySig, **asymmetric collision pinned** (`InvalidAccountNonce` vs `ERC2612InvalidSigner` — v5.7 `permit` hashes `_useNonce` into the struct, vendored line 55); both reverts atomic → failed signatures burn no nonce. (3) `delegate(address(0))` **undelegates** in OZ v5.7 — subtracts the account's votes from the previous delegate; no-op only when already undelegated. Comp-era "pool at zero" folklore corrected; both paths pinned. (4) Ch 14 cheatcode finding recurred a third time (invariant setUp role read ate the prank) — hoisted. (5) strictly-past rule pinned (`ERC5805FutureLookup` on current block). (6) same-block coalescing pinned (3 movements → 1 entry).
- Repo: `src/IMeridianGovernanceToken.sol`, `src/MeridianGovernanceToken.sol`, `test/MeridianGovernanceToken.t.sol` (39 tests), `test/MeridianGovernanceTokenHandler.sol` + `test/MeridianGovernanceTokenInvariant.t.sol` (wrapper conservation — `<=` bound + equality across deposit/depositFor/withdraw, 16,384 calls, 0 reverts), `.gas-snapshot` → **204 rows** under the pinned CI seed, paired `--check` green. **Suite: 199 passed / 0 failed / 6 skipped (205 total) across 21 suites** (+40 tests, +2 suites). Size: **8,055 B runtime / 16,521 B margin**.
- Gas (probes, warm min-deltas): deposit 16,060 · withdraw 15,357 · warm delegate 11,762 · delegateBySig 18,306 · transfer-with-votes 8,934 · `getPastVotes` @1,001 checkpoints 4,576 recent / 5,971 oldest.
- Glossary additions: checkpoint, voting delay, snapshot timepoint, clock mode (ERC-6372), `Trace208`, `getPastTotalSupply`, strictly-past lookup, coalescing, sqrt-probe lookup, shared nonce space, flash-loan governance, wrapper conservation.
- Grounding: **Beanstalk (Apr 2022, ~$182M, flash-loan governance, delay=0 demoed in-lab)**; Comp/UNI 2020; ENS 2021; stkAAVE; dark-DAO/Paladin vote markets; **Kelp DAO/Drift (Apr 2026, ~$285–292M)** — voting ≠ trust root.
- Protocol contract count: **2** (MER, gMER). Weekly doc `docs/governance-token-spec.md` added to pending debt. Vault errors provisional to Ch 20.
- **ERRATA APPLIED (2026-08-15, review `errata/15_Governance_Tokens_REVIEW.md`):** P0 — `delegate(address(0))` reframed as **undelegation** (removes votes from the previous delegate; no-op only when already undelegated); ERC-5805 marked **STAGNANT** (ERC-6372 in Review, not Final); wrapper invariant corrected to the **`totalSupply <= balanceOf(gMER)` bound** with `surplus` defined and equality scoped to deposit/depositFor/withdraw transitions; checkpoint-vs-delay reframed as two defenses solving different problems ("the one that matters" removed). P1 — delegation framed as a transferable political-rights *capability*, not a vote market by itself; "sub-5K at any depth" scoped to the 1,001-checkpoint lab measurement (4,576/5,971 gas); relayer "~1/10th writes" replaced with same-key coalescing only; OZ claims downgraded to "built on v5.7.0 source, widely reviewed implementation" (never equated with an audited protocol). P2 — "invented" → "popularized"; ERC-6372 spec-vs-implementation split; "undelegate" terminology normalized; "nothing to compromise" → "no privileged administrative key". Internal: voting-supply ≠ active-votes box, strictly-past flash-vote annotation, nonce-sharing labeled OZ implementation coupling. Restructure skipped per scope.
- Drift: none. Module boundary: none (M4 ends Ch 17 — next boundary audit at Ch 17).
