# 29. Rollup Architectures

## Learning Objectives

By the end of this chapter you will be able to:

1. Explain the rollup thesis — computation moved off-chain, data posted on-chain — and derive the two families (optimistic vs validity) from *where the fraud/validity proof lives*.
2. Trace an optimistic rollup's lifecycle: batch submission → challenge window → fraud proof → finalization, and the economic assumptions each step makes.
3. Trace a validity rollup's lifecycle: prover → proof generation → on-chain verification, and where the proving-system trust lives.
4. Compare the two families on the axes Meridian cares about: withdrawal latency, cost per transaction, security model, and sequencer decentralization.
5. Position post-Fusaka data availability (PeerDAS/EIP-7594, blob-parameter-only scaling) and its effect on rollup cost structure — with Glamsterdam as roadmap only.
6. Decide Meridian's L2 posture (Ch 31 preview): which rollup family, what the bridge (Ch 27) must verify, and what the deployment inherits.

## Prerequisites

- **Chapter 27** (Bridges) — the trust model the L2 bridge inherits.
- **Chapter 5** (Contract Lifecycle) — deployment semantics on L2.
- **Chapter 30** (Post-Fusaka Data Availability) — the cost structure this chapter's economics use (read together).

Supporting: **Ch 25** (trust chains — the sequencer as a trust anchor), **Ch 32** (bridges deep-dive). Locked conventions in force.

## Theory

### The rollup thesis

A rollup executes transactions *off-chain* and posts *data* (or a proof) on-chain. The L1 is the settlement layer: it does not run the computation, it *arbitrates* it. The family split is exactly where the arbitration lives:

- **Optimistic rollup:** L1 assumes the batch is valid unless someone submits a **fraud proof** within a challenge window. Security rests on *at least one honest watcher*.
- **Validity (ZK) rollup:** the prover submits a **validity proof** the L1 verifies cryptographically. Security rests on the *proof system and its implementation*.

### The fraud-proof game

An optimistic rollup's correctness is a game: a sequencer posts a batch; watchers inspect it; if it is invalid, a challenger posts a fraud proof and wins a reward. The game's assumptions:

1. **At least one honest watcher** — if every watcher is bribed/compromised, an invalid batch finalizes.
2. **The challenge window is long enough** for a watcher to detect and prove fraud (7 days typical).
3. **The fraud-proof protocol is interactive** (the bisection game) to keep proof costs bounded.

The 7-day window is the withdrawal latency: funds leaving the rollup wait for the window to close. That latency is the *price of trustless finality*.

### The validity-proof lifecycle

A validity rollup replaces the game with a proof: `execute(state, txs) → new_state` plus a proof `π` that the transition is correct, verified by the L1's verifier contract. No window, no watchers — but the proof system must be *actually correct*: a bug in the prover, the circuit, or the verifier is a consensus-level failure (the "prover bug = total loss" class).

## Mathematical Foundations

### The cost model

For a rollup with `D` data bytes per batch, `G_L1` gas per data byte (post-Fusaka: blob pricing), and `C_verify` verification cost:

```
C_total ≈ C_exec(off-chain) + D × G_L1 + C_verify + C_bridge
```

Post-Fusaka (PeerDAS / EIP-7594, blob-parameter-only scaling), `G_L1` for blob data is a *blob fee* (target-based, market-priced) rather than calldata's 16 gas/byte — the L2 cost structure drops by orders of magnitude for data-heavy batches. This is the "blob-parameter-only scaling" the TOC pins: the *parameters* of blob pricing scale, not a new DA layer (that is Glamsterdam, roadmap only).

### Withdrawal latency

Optimistic: `t_withdraw = t_batch + t_window` (7 days + finality). Validity: `t_withdraw ≈ t_batch + t_proof + t_verify` (minutes). The latency difference is the *economic* difference: capital efficiency vs trustless finality.

### Sequencer economics

A centralized sequencer provides ordering (MEV capture, Ch 34) in exchange for censorship-resistance and liveness risk. The decentralization ladder: single sequencer → shared sequencer → based sequencing (L1-proposer-ordered). Meridian's posture (Ch 31): accept the current sequencer model, monitor the roadmap.

## Engineering Perspective

### What Meridian inherits on L2

- **The bridge** (Ch 27/32): the L1↔L2 bridge's trust model *is* the rollup's security model. On an optimistic rollup, deposits are fast, withdrawals wait the window; on a validity rollup, both are fast but the proof system is the trust anchor.
- **The oracle** (Ch 22): L2 oracles inherit L1 prices via the bridge — the manipulation surface is the *bridge's* freshness, not the oracle's (Ch 35's OEV work).
- **The vault** (Ch 20): MeridianVault deploys unchanged; the only L2-specific changes are gas-price-dependent constants (Ch 8 methodology: re-pin deltas per chain).

## Mermaid Diagram

```mermaid
flowchart LR
    A[Users] -->|txs| B[Sequencer]
    B -->|batch| C[L1: data posted]
    C --> D{Family}
    D -- optimistic --> E[Challenge window 7d]
    E --> F{Fraud proof?}
    F -- yes --> G[Batch reverted]
    F -- no --> H[Finalized]
    D -- validity --> I[Prover]
    I -->|validity proof| J[L1 verifier]
    J --> K[Finalized (fast)]
```

## Code Walkthrough

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRollupLab
/// @notice I-prefix interface — the L1-side arbitration contract.
interface IRollupLab {
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error AlreadyFinalized(bytes32 root);
    error InvalidStateRoot(bytes32 expected, bytes32 got);

    function submitBatch(bytes32 stateRoot, bytes calldata data) external returns (uint256 index);
    function challengeBatch(uint256 batchIndex, bytes calldata fraudProofData) external;
    function finalizeBatch(uint256 batchIndex) external;
}

/// @title RollupLab
/// @notice Pedagogical L1-side rollup arbiter: batch → window → finalize.
/// @dev NOT part of the protocol — an architecture lab.
contract RollupLab is IRollupLab {
    struct Batch {
        bytes32 stateRoot;
        uint256 submittedAt;
        bool challenged;
        bool finalized;
    }
    Batch[] public batches;
    uint256 public constant CHALLENGE_WINDOW = 7 days;

    function submitBatch(bytes32 stateRoot, bytes calldata) external returns (uint256 index) {
        batches.push(Batch(stateRoot, block.timestamp, false, false));
        return batches.length - 1;
    }

    function challengeBatch(uint256 batchIndex, bytes calldata) external {
        Batch storage b = batches[batchIndex];
        if (block.timestamp > b.submittedAt + CHALLENGE_WINDOW) revert ChallengeWindowClosed();
        b.challenged = true;
    }

    function finalizeBatch(uint256 batchIndex) external {
        Batch storage b = batches[batchIndex];
        if (block.timestamp <= b.submittedAt + CHALLENGE_WINDOW) revert ChallengeWindowOpen();
        if (b.challenged) revert InvalidStateRoot(b.stateRoot, bytes32(0)); // fraud proven
        if (b.finalized) revert AlreadyFinalized(b.stateRoot);
        b.finalized = true;
    }
}
```

Three details. **First**, the challenge window is the *security parameter* — a batch cannot finalize before it closes. **Second**, a challenged batch cannot finalize — the fraud proof (simplified here to a flag) wins. **Third**, the window is a constant the deployment can tune — but shortening it weakens the watcher assumption (Ch 29 theory).

## Production Example

**Optimistic: Arbitrum/OP Stack.** The canonical deployments: challenge windows ~7 days, sequencer-published batches, the bisection game for fraud proofs. **Validity: zkSync/Starknet.** Proof systems with L1 verifiers, fast withdrawals. The comparison Meridian makes (Ch 31): an optimistic L2 with the native bridge is the default for an educational lending protocol — the 7-day withdrawal is a UX cost, not a security cost, and the security model (honest watcher) is the one the curriculum's incident set validates.

## Foundry Lab

`meridian/test/RollupLabTest.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RollupLab} from "../src/RollupLab.sol";
import {IRollupLab} from "../src/IRollupLab.sol";

contract RollupLabTest is Test {
    RollupLab internal lab;

    function setUp() public { lab = new RollupLab(); }

    /// @dev A batch cannot finalize before the window closes.
    function testCannotFinalizeEarly() public {
        lab.submitBatch(keccak256("root"), "");
        vm.expectRevert(IRollupLab.ChallengeWindowOpen.selector);
        lab.finalizeBatch(0);
    }

    /// @dev After the window, an unchallenged batch finalizes.
    function testFinalizesAfterWindow() public {
        lab.submitBatch(keccak256("root"), "");
        vm.warp(block.timestamp + 7 days + 1);
        lab.finalizeBatch(0);
    }

    /// @dev A challenged batch can never finalize.
    function testChallengedBatchNeverFinalizes() public {
        lab.submitBatch(keccak256("root"), "");
        lab.challengeBatch(0, "");
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(); // InvalidStateRoot
        lab.finalizeBatch(0);
    }

    /// @dev Double finalization reverts.
    function testDoubleFinalizeReverts() public {
        lab.submitBatch(keccak256("root"), "");
        vm.warp(block.timestamp + 7 days + 1);
        lab.finalizeBatch(0);
        vm.expectRevert(); // AlreadyFinalized
        lab.finalizeBatch(0);
    }
}
```

Green on forge 1.7.1.

## Security Analysis

### The watcher assumption is the optimistic rollup's trust anchor

The 7-day window and the challenge game are worthless if no one watches. The realistic threat: a sequencer posts an invalid batch, and all watchers are asleep/bribed — the batch finalizes. The defense is *economic* (challenge rewards, watcher diversity) more than technical. This is the Ch 25 trust-chain framing applied to a protocol layer.

### The prover is the validity rollup's trust anchor

A validity rollup concentrates risk in the proof system: a bug in the circuit or verifier is total (invalid state finalizes). The mitigation is the same as for any critical system: multiple independent prover implementations, formal verification of the verifier, and a security council with veto power (the 2026 trust-surface grounding).

### Sequencer centralization

A single sequencer can censor transactions (the liveness attack) and extract MEV (Ch 34). Neither is a *correctness* failure — the chain remains valid — but both are availability/value-extraction failures. The roadmap (shared sequencers, based sequencing) is the mitigation; Meridian monitors it but cannot depend on it.

## Common Mistakes

1. **Treating L2 as "Ethereum but cheaper"** — the bridge, the sequencer, and the proof system are new trust anchors.
2. **Ignoring the challenge window** — a withdrawal path that doesn't wait is trusting the sequencer unilaterally.
3. **Assuming ZK = automatically safe** — the proof system is software; it can be wrong.
4. **Calldata vs blob pricing confusion** — data-heavy batches use blobs (EIP-4844), scaled post-Fusaka via PeerDAS (EIP-7594); calldata economics are legacy.
5. **Glamsterdam as live** — it is roadmap only (TOC lock); PeerDAS/BPO is what ships.
6. **One cost model for both families** — optimistic and validity rollups have different latency and cost profiles.

## Gas Optimization

| Pattern | Before | After | Delta |
|---|---|---|---|
| Batch data (calldata) | 16 gas/byte | blob fee (EIP-4844), scaled post-Fusaka (EIP-7594) | order-of-magnitude drop |
| Challenge window constant | — | — | security param, not gas |
| Proof verification | — | C_verify | the validity family's fixed cost |

## Reading Production Source Code

1. **Arbitrum/OP Stack docs** — the challenge game, the batch lifecycle, the bridge.
2. **zkSync/Starknet docs** — the proving pipeline, the verifier, fast withdrawals.
3. **EIP-7594 (PeerDAS)** — blob data availability, the BPO scaling this chapter's economics use.
4. **Ch 30** — the DA deep-dive this chapter references.

## Exercises

1. Draw both families' lifecycles and mark where each places its trust.
2. For a batch of 100 KB data: compute the calldata cost (16 gas/byte) vs a blob-fee model — and explain why BPO changes the L2 cost structure.
3. Why is the challenge window a security parameter, and what happens at 1 hour?
4. Give the watcher assumption's failure mode and the economic mitigation.
5. Position Meridian's L2 choice (Ch 31 preview) in the family table.

## Weekly Project

**Ship `RollupLab.sol` + `RollupLabTest.t.sol`**, write `docs/rollup-notes.md` (the family comparison, the cost model, the Meridian L2 posture), and extend `docs/bridge-security.md` (Ch 27) with the L2-bridge trust model.

## Deliverables

1. `meridian/src/RollupLab.sol` + `IRollupLab.sol` — batch/window/finalize arbiter.
2. `meridian/test/RollupLabTest.t.sol` — window, finalization, challenge; green.
3. `docs/rollup-notes.md` — families, cost model, posture.
4. Locked conventions extended: L2 deployment inherits the rollup's trust model; the bridge (Ch 27) is the security boundary; post-Fusaka blob economics (PeerDAS/EIP-7594) ground all L2 cost claims; Glamsterdam never cited as live.

## Quiz

1. Where does the optimistic/validity split live?
2. What does the 7-day window buy, and what does it cost?
3. Why is a prover bug a total loss, and what is the mitigation?
4. What changes about L2 cost structure post-Fusaka (PeerDAS/EIP-7594)?
5. What does Meridian's L2 deployment inherit from the rollup's security model?

**Answers:** (1) In the arbitration: fraud proof (watchers) vs validity proof (cryptography). (2) Trustless finality — at least one honest watcher can always correct an invalid batch; it costs withdrawal latency and capital efficiency. (3) An invalid state finalizes with no challenge window; mitigations are independent provers, verified verifiers, security council veto. (4) Blob pricing (EIP-4844), scaled post-Fusaka via PeerDAS (EIP-7594), replaces calldata's 16 gas/byte for data-heavy batches — order-of-magnitude cheaper DA; Glamsterdam is roadmap only. (5) The bridge's trust model = the rollup's security model: watcher assumption (optimistic) or proof system (validity), plus the sequencer's ordering/liveness properties.

## Further Reading

- Arbitrum/OP Stack, zkSync/Starknet documentation; EIP-7594 (PeerDAS); EIP-4844 (blobs).
- Ch 27 (bridges), Ch 30 (DA), Ch 31 (L2 deployment), Ch 32 (bridges deep-dive), Ch 34 (MEV/sequencers).
- 2026 grounding: the security-council and sequencer-decentralization debates (trust-surface framing, Ch 25).
