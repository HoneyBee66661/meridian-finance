# 27. Cross-Chain & Bridge Security

## Learning Objectives

By the end of this chapter you will be able to:

1. Classify bridges by their trust model — canonical/external, optimistic/validity, MPC/relayer — and derive the attack surface each one exposes.
2. Analyze the **Kelp DAO/LayerZero and Drift Protocol cross-chain incidents (~$285–292M, Apr 2026)** — an admin-key failure and a verifier-configuration trust-root failure — as trust-chain attacks *across* chains, and extract the cross-chain-specific lessons (key custody per chain, message payload authorization).
3. Model a bridge message's lifecycle: source-chain state → message format → relayer/validator set → destination-chain execution, and identify where each known bridge failure inserted itself.
4. Apply Meridian's cross-chain discipline: canonical-bridge-first, payload whitelisting, destination-side re-validation, and the Ch 25 trust-chain audit extended across chains.
5. Write the bridge-failure taxonomy (protocol logic, validator compromise, relayer griefing, message replay, spoofing) with a named incident per class.

## Prerequisites

- **Chapter 25** (Access Control) — the trust-chain model this chapter extends across chains.
- **Chapter 24** (Reentrancy) — destination-side execution discipline.
- **Chapter 13** (CI/CD) — supply-chain compromise as a message-spoofing vector.

Supporting: **Ch 26** (invariants — cross-chain conservation), **Ch 22** (oracles — cross-domain data), **Ch 32** (bridges deep-dive, M7). Locked conventions in force.

## Theory

### Bridges are trust boundaries wearing transport

A bridge is not a transport problem; it is a **trust problem with a message format**. Every bridge must answer: *who is authorized to attest that state on chain A happened, and how does chain B verify it?* The answer defines the attack surface:

| Bridge class | Attestation | Compromise surface | Canonical incident |
|---|---|---|---|
| Canonical (native) | source chain itself | source chain finality | — (no external trust)\* |
| External/validator | validator set (N/M) | N validators | Ronin (~$625M, 2022) |
| Optimistic | watchers + challenge window | watcher collusion | Nomad (~$190M, 2022) |
| Validity (ZK) | prover | proving system | — (youngest class) |
| MPC/relayer | threshold signature | verification logic (account confusion)† | Wormhole (~$326M, 2022) |
| Admin-key cross-chain | key authorization | key custody per chain | Drift (~$285M, Apr 2026) |
| Off-chain verifier infrastructure | DVN/oracle data feed | RPC nodes + DVN config | Kelp DAO/LayerZero (~$292M, Apr 2026) |

\* Canonical-bridge security requires that the destination chain's finality is enforced by the source chain. Rollup native bridges (OP, Arbitrum, zkSync) meet this; sidechains with their own validator sets do not — those belong to the external/validator row.

† Wormhole is this class's named failure, but its root cause was signature-verification logic, not stolen key shares (Security Analysis item 2); pure key-material custody failures are covered in Ch 32.

The taxonomy's lesson: **every class fails at its attestation layer** — the validator set, the watcher set, the verifier configuration, or the verification logic itself. Transport (which chain, which message format) is nearly never the failure.

### The 2026 incidents — trust chains across chains

Drift Protocol (~$285M, Apr 2026) is the admin-key cross-chain failure: a key on one side of a message flow authorized a payload on the other side. Kelp DAO/LayerZero (~$292M, Apr 2026) is the configuration trust-root failure: a misconfigured 1-of-1 LayerZero verifier (DVN) accepted a forged cross-chain message after its RPC data sources were compromised — no admin key was involved. The cross-chain-specific lesson: **a key's authority does not stop at the chain boundary, and neither does a configuration's.** An admin key — or a verifier setting — on chain A that can authorize a message attested as "from the protocol" is an authority on chain B too, unless the destination re-validates.

## Mathematical Foundations

### The bridge security equation

Let `V` = validator set (size `n`, threshold `t`), `M` = message space, `A` = set of authorized payloads. A bridge is secure iff:

```
∀ msg ∈ M: executed_on_B(msg) ⟹ attestation_valid(msg) ∧ payload ∈ A
```

The failure classes are the ways this implication breaks: attestation_valid is spoofable (validator compromise, message replay), or `A` is too wide (any payload executes — the Nomad shape: the "trusted root" was empty, so *any* message was authorized).

### Replay resistance

A message `m` must be executable at most once. The standard model: source chain tracks a `nonce` per sender, destination tracks `executed[hash(m)]`. The invariant:

```
∀ m: executed[hash(m)] ≤ 1
```

Replay attacks (a message re-executed on the destination) break this. The defense is a destination-side `executed` mapping — never trust the source to have prevented it.

## Engineering Perspective

### Meridian's cross-chain posture (M7 preview, locked here)

- **Canonical bridge first.** Meridian's L2 deployment (Ch 31) uses the rollup's native bridge for asset movement; third-party bridges are opt-in per market, each vetted with this chapter's checklist.
- **Payload whitelisting.** The destination contract accepts a closed set of function selectors + argument shapes; anything else reverts. The Nomad "any message" shape is structurally impossible.
- **Destination-side re-validation.** The receiving contract re-checks what the source *claimed*: sender identity, amount bounds, market existence. The 2026 lesson: never trust the attestation to carry the authorization.
- **Per-chain key custody.** The Ch 25 role set exists *per chain*: an operator key on L1 cannot sign L2 messages, and vice versa — the L2 bridge's `authorizedSource` accepts only the L1 bridge *contract* address, never an operator key.

## Mermaid Diagram

```mermaid
flowchart LR
    A[L1 state] -->|attest| B[Message: nonce + payload]
    B --> C{Validator set / canonical}
    C -->|valid| D[Destination check]
    D --> E{payload ∈ whitelist?}
    E -- yes --> F{executed[hash] == 0?}
    F -- yes --> G[Execute]
    F -- no --> H[revert: replay]
    E -- no --> I[revert: unauthorized]
    C -->|compromised| J[spoofed message]
```

## Code Walkthrough

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBridgeLab
/// @notice I-prefix interface — full failure surface (Ch 2 lock).
interface IBridgeLab {
    error UnauthorizedSender(address sender);
    error UnauthorizedPayload(bytes4 selector);
    error MessageReplay(bytes32 hash);
    error InvalidMarket(address market);
    error ValueOutOfBounds(uint256 value);

    function executeMessage(address sourceSender, bytes calldata payload) external;
}
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeLab} from "./IBridgeLab.sol";

/// @title BridgeLab
/// @notice Pedagogical destination-side bridge receiver: re-validates sender,
///         whitelists payloads, blocks replays. NOT part of the protocol.
contract BridgeLab is IBridgeLab {
    address public immutable authorizedSource;   // the source bridge contract
    mapping(bytes32 => bool) public executed;

    /// @dev Self-call only — target functions are reachable exclusively through
    ///      executeMessage's gated path, never as public entry points.
    modifier onlyViaExecuteMessage() {
        if (msg.sender != address(this)) revert UnauthorizedSender(msg.sender);
        _;
    }

    constructor(address authorizedSource_) { authorizedSource = authorizedSource_; }

    /// @dev Destination-side execution: source must be authorized, payload
    ///      must be a whitelisted shape, and the message must be new.
    function executeMessage(address sourceSender, bytes calldata payload) external {
        if (msg.sender != authorizedSource) revert UnauthorizedSender(msg.sender);
        if (payload.length < 4) revert UnauthorizedPayload(bytes4(0)); // length guard

        bytes4 selector = bytes4(payload[:4]);
        if (selector != this.applyMarketUpdate.selector
            && selector != this.applyCollateralFactor.selector) {
            revert UnauthorizedPayload(selector);
        }

        bytes32 h = keccak256(abi.encode(sourceSender, payload));
        if (executed[h]) revert MessageReplay(h);
        executed[h] = true;

        // destination-side re-validation happens in the target functions
        (bool ok, bytes memory ret) = address(this).call(payload);
        if (!ok) {
            // bubble the target's revert so the caller sees the real reason
            assembly { revert(add(ret, 32), mload(ret)) }
        }
    }

    /// @dev Whitelisted target — re-validates the bounds the source claimed.
    ///      Self-call only (see onlyViaExecuteMessage).
    function applyMarketUpdate(address market, uint256 newValue)
        external onlyViaExecuteMessage
    {
        if (market == address(0)) revert InvalidMarket(market);
        if (newValue > 1e27) revert ValueOutOfBounds(newValue);
    }

    /// @dev Whitelisted target — collateral factor stays within [0, 100%].
    function applyCollateralFactor(uint256 cf)
        external onlyViaExecuteMessage
    {
        if (cf > 1e18) revert ValueOutOfBounds(cf);
    }
}
```

Four details. **First**, the source is a single authorized address — the canonical bridge, not "any relayer". **Second**, the payload selector must be in the whitelist — the Nomad "any message" shape reverts here, and payloads shorter than a selector revert cleanly too. **Third**, the replay guard is destination-side, keyed on the full message. **Fourth**, the target functions are reachable only through this gated path: `onlyViaExecuteMessage` blocks direct calls, and each target re-validates its own argument bounds — destination-side re-validation is real code, not a comment.

## Production Example

**Nomad (~$190M, Aug 2022)** — the canonical "empty trusted root" failure: the bridge's trusted root was the zero value, so *any* message that hashed to an empty root was accepted; the first attacker's transaction was copied and replayed by hundreds of bots. The defense this chapter teaches: payload whitelisting + destination-side replay guard — the Nomad shape is structurally impossible in `BridgeLab`.

**Drift Protocol (~$285M, Apr 2026)** — admin-key cross-chain compromise: socially engineered multisig signers authorized a zero-timelock governance migration, and the attacker drained cross-chain positions; the lesson is per-chain key custody + destination re-validation (Ch 25 extended). **Kelp DAO/LayerZero (~$292M, Apr 2026)** — configuration trust-root failure: the LayerZero verifier was configured as a 1-of-1 DVN, so a single compromised verifier (fed by attacker-controlled RPC nodes after a DDoS) could authorize a forged cross-chain message; the lesson is that the verifier configuration is a trust root that must be audited like a key. The audit question: *can a key — or a verifier setting — on chain A authorize a message that executes on chain B without re-validation?* If yes, that is the 2026 shape.

## Foundry Lab

`meridian/test/BridgeLabTest.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BridgeLab} from "../src/BridgeLab.sol";
import {IBridgeLab} from "../src/IBridgeLab.sol";

contract BridgeLabTest is Test {
    BridgeLab internal lab;
    address internal source = address(0x50C4CE);

    function setUp() public { lab = new BridgeLab(source); }

    /// @dev Only the authorized source may submit.
    function testUnauthorizedSourceRejected() public {
        bytes memory payload = abi.encodeCall(lab.applyMarketUpdate, (address(1), 1e18));
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.UnauthorizedSender.selector, address(0xBEEF)));
        vm.prank(address(0xBEEF));
        lab.executeMessage(address(this), payload);
    }

    /// @dev Non-whitelisted payload reverts (the Nomad shape).
    function testNonWhitelistedPayloadRejected() public {
        bytes memory bad = abi.encodeWithSignature("setAdmin(address)", address(1));
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.UnauthorizedPayload.selector, bytes4(bad)));
        vm.prank(source);
        lab.executeMessage(address(this), bad);
    }

    /// @dev Same message twice = replay.
    function testReplayRejected() public {
        bytes memory payload = abi.encodeCall(lab.applyMarketUpdate, (address(1), 1e18));
        vm.prank(source);
        lab.executeMessage(address(this), payload);

        bytes32 h = keccak256(abi.encode(address(this), payload));
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.MessageReplay.selector, h));
        vm.prank(source);
        lab.executeMessage(address(this), payload);
    }

    /// @dev Whitelisted payload executes exactly once.
    function testWhitelistedExecutes() public {
        bytes memory payload = abi.encodeCall(lab.applyCollateralFactor, (0.8e18));
        vm.prank(source);
        lab.executeMessage(address(this), payload);

        bytes32 h = keccak256(abi.encode(address(this), payload));
        assertTrue(lab.executed(h));
    }

    /// @dev Target functions are not public entry points: only the self-call
    ///      from executeMessage may invoke them.
    function testDirectTargetCallRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.UnauthorizedSender.selector, address(this)));
        lab.applyMarketUpdate(address(1), 1e18);

        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.UnauthorizedSender.selector, address(this)));
        lab.applyCollateralFactor(0.8e18);
    }

    /// @dev Payloads shorter than a selector revert with the custom error,
    ///      not an opaque slice panic.
    function testShortPayloadRejected() public {
        bytes memory short = hex"aabbcc";
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.UnauthorizedPayload.selector, bytes4(0)));
        vm.prank(source);
        lab.executeMessage(address(this), short);
    }

    /// @dev Destination-side re-validation: out-of-bounds arguments revert
    ///      even though the selector is whitelisted.
    function testOutOfBoundsRejected() public {
        bytes memory payload = abi.encodeCall(lab.applyMarketUpdate, (address(1), 2e27));
        vm.expectRevert(abi.encodeWithSelector(IBridgeLab.ValueOutOfBounds.selector, 2e27));
        vm.prank(source);
        lab.executeMessage(address(this), payload);
    }
}
```

Green on forge 1.7.1.

## Security Analysis

### The failure taxonomy, with incidents

1. **Message spoofing via empty root** — Nomad (~$190M, 2022): the trusted-root default accepted any message.
2. **Signature verification bypass** — Wormhole (~$326M, Feb 2022): the guardian-set architecture was sound, but a missing account validation in the Solana program allowed a fake sysvar to substitute for the real `Instructions` sysvar, so the verification function treated unverified data as guardian-approved. No guardian keys were stolen. The lesson: attestation security requires both a sound key set *and* correct verification logic — a bug in the latter bypasses the former entirely.
3. **Validator compromise** — Ronin (~$625M, 2022): 5/9 validators compromised via social engineering of key holders.
4. **Admin-key cross-chain** — Drift Protocol (~$285M, Apr 2026): socially engineered multisig signers authorized a zero-timelock governance migration, granting the attacker admin authority to drain cross-chain positions. The lesson: a key's blast radius does not stop at the chain boundary.
5. **Off-chain verifier infrastructure** — Kelp DAO/LayerZero (~$292M, Apr 2026): a 1-of-1 DVN configuration meant one compromised verifier — fed by attacker-controlled RPC nodes after a DDoS — could authorize a forged cross-chain message; no admin key was involved. The lesson: attestation infrastructure needs redundancy (≥ 2-of-N DVN) and independent RPC data sources.
6. **Relayer griefing** — messages delayed/dropped: an availability attack, not a theft, but a liveness failure.

### The cross-chain trust surface (2026 grounding)

The ledger's 2026 grounding (Kelp/LayerZero/Drift) is *the* cross-chain incident set. The generalizable rule: **attestation proves the message came from the source protocol — it does not prove the source protocol's key — or its verifier configuration — was honest.** Destination-side re-validation is the only defense that does not trust the source's security posture.

## Common Mistakes

1. **Trusting the attestation for authorization** — the 2026 shape; attestation ≠ authorization.
2. **Any-message execution** — the Nomad shape; whitelist selectors.
3. **No destination-side replay guard** — trusting the source nonce.
4. **One key set across chains** — per-chain custody (Ch 25 extended).
5. **No payload bounds** — an authorized selector with amount = `type(uint256).max` or recipient = `address(attacker)` passes the whitelist check but causes catastrophic execution; arguments must be individually bounded.
6. **Ignoring liveness** — a bridge that can be griefed into silence is a DoS on the protocol.

## Gas Optimization

| Pattern | Before | After | Delta |
|---|---|---|---|
| Replay guard (SSTORE) | — | 22,100 first / 2,900 warm | baseline — mandatory |
| Payload whitelist check | — | ~100 (selector compare) | free |
| Single source address | — | 100 (immutable) | free |

## Reading Production Source Code

1. **The canonical bridge implementations** (rollup native bridges) — the message format, the attestation, the destination execution.
2. **Wormhole/Ronin/Nomad post-mortems** — the taxonomy's incidents.
3. **LayerZero's endpoint** — the message library + adapter + verifier configuration, and where the 2026 compromise inserted.
4. **Ch 32 (M7)** — the deep-dive this chapter's principles will be applied to.

## Exercises

1. Classify five bridges by the table's trust model and name their attestation layer.
2. For `BridgeLab`, craft the payload that the Nomad shape would have accepted and show it reverting.
3. Derive the replay-guard invariant and show where a source-only nonce fails.
4. Map the 2026 incidents: which gate was missing (per-chain custody, payload whitelist, destination re-validation)?
5. Design the Meridian L2 asset-movement flow (Ch 31 preview) using canonical-bridge-first + destination re-validation.

## Weekly Project

**Ship `BridgeLab.sol` + `IBridgeLab.sol` + `BridgeLabTest.t.sol`**, write `docs/bridge-security.md` (the taxonomy with incidents, the cross-chain trust-surface rule, the Meridian bridge checklist), and extend `docs/trust-chain.md` (Ch 25) with the per-chain role matrix.

## Deliverables

1. `meridian/src/BridgeLab.sol` + `IBridgeLab.sol` — destination-side receiver with whitelist + replay guard.
2. `meridian/test/BridgeLabTest.t.sol` — unauthorized source, non-whitelisted payload, replay, direct-call rejection, out-of-bounds args; green.
3. `docs/bridge-security.md` — taxonomy + checklist + 2026 grounding.
4. Locked conventions extended: canonical-bridge-first; payload whitelisting; destination-side re-validation; per-chain key custody; replay guard destination-side.

## Quiz

1. What does a bridge actually trust, per class?
2. Why does the Nomad failure have the shape "any message executes"?
3. What is the difference between attestation and authorization, and which incident turns on it?
4. Where does the replay guard belong, and why not the source?
5. Give the cross-chain version of the Ch 25 resilience formula.

**Answers:** (1) Its attestation layer — validators, watchers, key shares, verifier configurations, or the source chain itself. (2) The trusted root defaulted to zero, so any message hashing to an empty root passed; the whitelist defense is absent. (3) Attestation proves origin; authorization decides what origin may do. Drift turns on a key whose attestation was valid but whose payload authority was too wide; Kelp turns on verifier infrastructure — the attestation mechanism itself was subverted, not the key behind it. (4) Destination-side — the source cannot prevent re-execution on another chain; `executed[hash]` is the invariant. (5) Resilience across chains = min over chains of (keys to compromise per chain), with per-chain custody ensuring the minimization is per-chain, not global — a single compromised cross-chain signing key collapses the min to 1.

## Further Reading

- Ronin (~$625M), Wormhole (~$326M), Nomad (~$190M) post-mortems; Drift (~$285M) and Kelp DAO/LayerZero (~$292M, Apr 2026) — the 2026 grounding.
- Ch 25 (trust chains), Ch 24 (execution discipline), Ch 13 (supply chain), Ch 26 (cross-chain conservation), Ch 32 (M7 bridge deep-dive).
