# Contract Lifecycle & CREATE2

A contract is not a thing — it is a state transition. The EVM maps an address to a tuple of four fields, and every operation you think of as contract "life" is an edit to that tuple. Once that mental model is solid, address derivation, counterfactual existence, and the post-Cancun death semantics become mechanical consequences.

### Contents

1. [Learning Objectives](#learning-objectives)
2. [The Full Lifecycle — Creation, Calls, Destruction](#the-full-lifecycle--creation-calls-destruction)
3. [EIP-6780 — What SELFDESTRUCT Does Now](#eip-6780--what-selfdestruct-does-now)
4. [Address Derivation — Nonce-Coupled vs Salt-Coupled](#address-derivation--nonce-coupled-vs-salt-coupled)
5. [CREATE2 Formula — Four Components, Four Consequences](#create2-formula--four-components-four-consequences)
6. [EIP-1167 Minimal Proxies — The Factory's Favourite Pattern](#eip-1167-minimal-proxies--the-factorys-favourite-pattern)
7. [CREATE vs CREATE2 — Decision Framework](#create-vs-create2--decision-framework)
8. [Mathematical Foundations — Collision Space & Salt Uniformity](#mathematical-foundations--collision-space--salt-uniformity)
9. [Locked Conventions](#locked-conventions--chapter-05-additions)
10. [Code Walkthrough — DeployerProbe.sol](#code-walkthrough--deployerprobesol)
11. [Production References](#production-references)
12. [Security Analysis](#security-analysis--factory--lifecycle-vulnerability-classes)
13. [Gas Optimization](#gas-optimization)
14. [Common Mistakes](#common-mistakes)
15. [Exercises & Weekly Project](#exercises--weekly-project)
16. [Quiz](#quiz)
17. [Further Reading](#further-reading)

## Learning Objectives

- **Obj 01** —  Trace a contract through its full lifecycle — creation, calls, and post-Cancun destruction semantics — and state precisely what the EVM does at each stage in gas terms.
- **Obj 02** —  Derive both address-derivation formulas by hand: `keccak256(rlp([sender,nonce]))[12:]` for `CREATE` and the EIP-1014 formula for `CREATE2`, and explain why the two differ.
- **Obj 03** —  Predict a `CREATE2` address before deployment and verify it on-chain, including constructor-argument handling in the initcode hash.
- **Obj 04** —  Choose between `CREATE` and `CREATE2` for a production factory based on determinism, nonce coupling, and front-running surface — with the gas delta measured, not asserted.
- **Obj 05** —  Explain the security implications of deterministic addresses: counterfactual interaction, salt griefing, address squatting, and metamorphic contracts — and which of these EIP-6780 actually killed.
- **Obj 06** —  Read a production factory (Uniswap V3 `PoolFactory`, Safe `ProxyFactory`) and apply the same patterns to Meridian's upcoming market deployment layer.

## The Full Lifecycle — Creation, Calls, Destruction

> **The mental model that makes everything mechanical** —  
>  The EVM's world-state maps every address to a single tuple: `{nonce, balance, storageRoot, codeHash}`. A contract "exists" only as long as that mapping holds a code hash different from the empty hash. Every operation you think of as contract life — deploy, call, destroy — is an edit to this tuple.

### Creation — executing initcode to produce runtime code

The payload is **initcode**: a short-lived program whose *output* becomes runtime code and whose *execution* runs the constructor. The frame has `msg.sender = deployer` and `msg.value` forwarded. Gas is deducted per opcode as with any call.

Whatever bytes the initcode program returns via `RETURN` becomes the contract's permanent runtime bytecode. This is the compiled contract body — the code that will run on every future call.

The EVM charges 200 gas per byte of runtime code deposited. EIP-170 caps runtime code at **24,576 bytes**. EIP-3860 adds 2 gas/byte of *initcode* (charged before execution). Large constructors pay twice: once for initcode execution, once for the deposit.

A contract-created contract starts at nonce 1, not 0 — this means the address of its first `CREATE`-born child differs from a fresh EOA's first contract. The lab's `testCreatePredictionMatches` pins this exactly.

The creation frame is atomic: a revert in the constructor rolls back all storage writes and any inner deployments. The address is simply never committed. One nuance: a value transfer happens before execution, so a constructor that runs out of gas mid-way may leave the balance stranded at the (now-uncommitted) address.

### Creation cost model (post EIP-3860)

| Component | Cost | EIP basis |
| --- | --- | --- |
| Base creation fee | 32,000 gas | Yellow Paper §7 |
| Initcode word cost | 2 gas/byte of initcode | EIP-3860 (Shanghai) |
| Runtime code deposit | 200 gas/byte of runtime | EIP-170 (Spurious Dragon) |
| CREATE2 initcode hash | +6 gas per 32-byte word of initcode | EIP-1014 |
| Max runtime code | 24,576 bytes | EIP-170 hard cap |
| Max initcode | 49,152 bytes | EIP-3860 hard cap |

### Calls — the lifecycle's steady state

Chapter 01 covered the frame model in full. The lifecycle point here: a contract can be called *before or after deployment* if its address is known. This is the property `CREATE2` manufactures — and the property that makes counterfactual UX and factory-permissioned deployment possible.

| Opcode | Storage context | msg.sender | State writes? |
| --- | --- | --- | --- |
| `CALL` | Callee's own storage | Caller's address | Yes |
| `DELEGATECALL` | **Caller's storage** | Original caller | Yes — to caller's slots |
| `STATICCALL` | Callee's own storage | Caller's address | No — any write reverts |

## EIP-6780 — What SELFDESTRUCT Does Now

Most mental models of contract destruction are stale as of Cancun (2024).

- Deleted the contract's code and all storage
- Transferred entire balance to beneficiary
- Refunded 24,000 gas
- Enabled "metamorphic" patterns: destroy → re-`CREATE2` at same address with new code

- Deletes code + storage **only if created in the same transaction**
- Otherwise: **forced balance transfer only** — code and storage survive
- Gas refund gone
- Two-transaction metamorphic lifecycle: **dead**
- Same-transaction metamorphic: still possible (one narrow path remains)

> **Post-Fusaka audit posture on contract destruction** —  
>  Assume a contract can **never be deleted** by an external call. The two remaining "code-at-address-changed" vectors are: (a) **EIP-7702** delegation — an EOA pointing at implementation code; (b) **upgradeable proxies** — `DELEGATECALL`-based, not deletion-based. Any protocol logic depending on `SELFDESTRUCT` clearing storage or freeing an address for re-use is broken on current networks.

## Address Derivation — Nonce-Coupled vs Salt-Coupled

### CREATE — keccak256(rlp([sender, nonce]))[12:]

Two properties follow immediately:

| Property | Consequence |
| --- | --- |
| Address is a function of *who* deploys and *when* (nonce) | Deterministic only if you control the deployer's nonce sequence — which is awkward to guarantee in a multi-function factory |
| Any change to the deployer changes every child address | Same bytecode from a different address → entirely different address space |
| EIP-161: contract nonce starts at 1, not 0 | First child of a contract ≠ first child of an EOA — a classic off-by-one in hand-rolled predictors |

### CREATE2 — keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:]

## CREATE2 Formula — Four Components, Four Consequences

| Component | Value | Consequence |
| --- | --- | --- |
| `0xff` | Domain-separation byte | Guarantees a `CREATE2` address can *never* collide with a `CREATE` address — RLP's first byte is always `0xc6`/`0xc7`… never `0xff` |
| `deploying_addr` | The factory executing the opcode | Not the EOA that initiated the transaction — changing the factory changes every child address, making pool-squatting against Uniswap's factory infeasible |
| `salt` | 256 bits, caller-chosen | The entire search space for address games: salt-search for vanity addresses, namespace by `msg.sender` to prevent griefing |
| `keccak256(initcode)` | Hash of initcode, not runtime | The single most common implementation bug: constructor args are appended to initcode. Two deployments of the same contract with different args → different addresses, even with the same salt |

> **The constructor-argument trap — measured in real audits** —  
>  If contract `C` takes a `uint256` constructor argument, its initcode is: `abi.encodePacked(type(C).creationCode, abi.encode(arg))`. 
 
>  Using only `type(C).creationCode` in the predictor produces an address that matches *no actual deployment* — every predicted address is silently wrong. The lab's `testPredictUsesInitcodeHash` pins this with a fuzz assertion.

> **Counterfactual existence — the killer feature** —  
>  Because the formula is pure, the address is computable *off-chain, before the factory even exists on-chain*. Safe wallets precompute addresses that users fund and sign for before the proxy is deployed. ERC-4337 smart accounts work the same way. Meridian's `OracleRegistry` (Ch 22) will publish feed addresses before the registry ships.

## EIP-1167 Minimal Proxies — The Factory's Favourite Pattern

The canonical factory pattern compresses cost and deployment surface by shipping a 45-byte runtime that forwards all calls via `DELEGATECALL` to a hard-coded implementation address.

### Why this changes the factory economics

≈ 40× reduction per instance — the arithmetic that makes per-user and per-pool factories viable. Meridian's future per-market deployments (Ch 20) are proxy instances, not full re-deployments.

> **The cost you pay: shared logic + storage collision discipline** —  
>  All proxy instances share one implementation. If that implementation changes (or is compromised), every proxy instance is affected. The storage collision discipline from Chapter 06 (EIP-1967 / ERC-7201 namespacing) is mandatory — a minimal proxy that uses overlapping storage slots with its implementation is a silent state-corruption bug.

## CREATE vs CREATE2 — Decision Framework

- Address = f(deployer, nonce)
- Deterministic *only* with locked nonce sequence
- Any other factory call shifts subsequent addresses
- Cannot compute address before deployment on a new factory
- Not front-runnable on address selection (no salt to steal)
- No additional hash cost

**Use when:** simple one-time deployments where counterfactual addresses are not needed and nonce control is guaranteed.

- Address = f(factory, salt, keccak256(initcode))
- Fully deterministic — any caller can predict
- Independent of factory nonce
- Computable off-chain before factory exists
- Salt can be griefed if not namespaced
- +6 gas/word of initcode (negligible vs 32,000 base)

**Use when:** counterfactual addresses needed; per-instance proxies; deterministic pool/market addresses; cross-chain address equivalence.

> **If your reason to use CREATE is gas, it is wrong** —  
>  `CREATE2` adds ≈ 6 × ⌈initcode_bytes/32⌉ gas for the initcode hash. For a 1,000-byte initcode: ~192 gas. The base is 32,000 for both. **CREATE2 costs 0.6% more — the real differences are address semantics, not gas.**

### Why production protocols default to CREATE2

Three reasons, in decreasing order of frequency:

| Reason | Production example | Meridian application |
| --- | --- | --- |
| **Counterfactual existence** — fund and sign before deployment | Safe, Argent, ERC-4337 smart accounts | `OracleRegistry` (Ch 22) — publish feed addresses before registry ships |
| **Parameter-derived determinism** — same params → same address, any caller | Uniswap V3 pools: `token0 + token1 + fee → address` | Market factory (Ch 20): `asset + oracle + params → market address` |
| **Cheap per-instance proxies** — 45-byte EIP-1167 at fixed addresses | Safe `ProxyFactory`, OZ `Clones` | One vault-proxy per market — ~41,000 gas vs ~1.6M gas per full deploy |

## Mathematical Foundations — Collision Space & Salt Uniformity

### The 20-byte truncation — why collisions are astronomically unlikely

### The salt as a control variable

With everything else fixed, the salt is a *bijection* onto addresses: changing the salt by 1 changes the preimage, and the output is uniformly distributed over the 160-bit space. This is what makes "address generation" possible:

| Goal | Method | Effort |
| --- | --- | --- |
| Address with 2 leading zero bytes (gas savings) | Iterate salts until `addr[0:2] == 0x0000` | 2⁴⁰–2⁴⁸ candidates — seconds to minutes on `anvil` |
| Specific target address (attack) | Invert keccak to find a preimage | Computationally impossible — keccak is a one-way function |

### RLP cost of CREATE addresses

`rlp([deployer, nonce])` for nonce < 2⁵⁶ is 21 bytes; the keccak input is 21 bytes. There is no entropy to exploit — the address is *predictable* to anyone who knows the nonce, but you cannot choose it. This is why `CREATE` addresses are "predictable but not controllable."

## Locked Conventions — Chapter 05 Additions

- **User-influenced salts must be namespaced by `msg.sender`.** `salt = keccak256(abi.encode(msg.sender, userSalt))` — each caller can only burn their own namespace. Raw user salts expose the factory to griefing.
- **The CREATE2 predictor hashes initcode, not runtime code.** For a parameterized constructor: `keccak256(abi.encodePacked(type(C).creationCode, abi.encode(args)))`. Using `type(C).creationCode` alone is wrong and silent.
- **Verify `codehash` after counterfactual deployment.** The address existing does not mean *your* code is there. Check `addr.codehash == expected` after any deployment that was promised counterfactually.
- **Never assume SELFDESTRUCT clears code or storage in external calls.** EIP-6780 makes it a balance transfer only. Code and storage survive. Any state-clearing logic built on it is broken.
- **Factories are operational-security events, not just code events.** Factory functions are gated with `onlyOwner`/`timelock`, emit child address events, and answer the four audit questions (§Production References) before shipping.
- **The four factory audit questions must be answered before any factory ships:** who can choose the salt, who can burn it, what happens to predictions if the template changes, and is the implementation address verified?
- **Minimal proxy implementation addresses are `immutable` and verified.** A mutable or upgradeable implementation behind 45-byte proxies is a single-point compromise. Use EIP-1167 for fixed logic; use EIP-1967 proxies for upgradeable logic.

### The four factory audit questions

- **Who can choose the salt?** If the answer is "anyone," the factory needs salt namespacing. If it is "only the owner," verify the access control gate.
- **Who can burn a salt?** On a counterfactual factory (not yet deployed), anyone can deploy their own contract to a predicted address, permanently burning that salt for the intended deployment.
- **What happens to predictions if the template changes?** If the initcode hash changes (new implementation version), every predicted address changes. Integrators relying on old predictions break loudly — this is a feature (Ch 38 upgrade discipline).
- **Is the implementation address verified after deployment?** Check `addr.codehash` or the expected EIP-1167 runtime with the implementation address embedded.

## Code Walkthrough — DeployerProbe.sol

`DeployerProbe` is pedagogical — not a protocol contract — following the Ch 02 convention (`ErrorProbe`, `ArithProbe`). It implements both address derivations in Solidity and proves them against the real opcodes.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DeployerProbe
/// @notice Proves CREATE and CREATE2 address derivation against real EVM opcodes.
/// @dev Pedagogical only — NOT part of the Meridian protocol.
contract DeployerProbe {

    /// @notice Target for lifecycle tests: increments a counter per call.
    ///         Used as the deployed contract in both CREATE and CREATE2 tests.
    contract Counter {
        uint256 public count;
        function inc() external { unchecked { ++count; } }
    }

    /// @notice CREATE prediction: keccak256(rlp([sender, nonce]))[12:]
    ///         Only correct for nonce < 0x80 (the only case a factory ever sees).
    ///         EIP-161: contract deployer starts at nonce 1, not 0 — the test must
    ///         call vm.getNonce(address(probe)) before deployment to get the right value.
    function predictCreate(address sender, uint256 nonce)
        external pure returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xc6),        // rlp list header: 2 items, both < 0x80
            bytes20(sender),    // rlp string: 20-byte address
            bytes1(uint8(nonce)) // rlp string: nonce < 0x80
        )))));
    }

    /// @notice CREATE2 prediction per EIP-1014.
    ///         initcode is the constructor bytecode PLUS any ABI-encoded constructor args.
    ///         For Counter (no args): type(Counter).creationCode
    ///         For C(uint256 arg):   abi.encodePacked(type(C).creationCode, abi.encode(arg))
    ///         Using only creationCode when args exist produces the wrong address — silently.
    function predictCreate2(address deployer, bytes32 salt, bytes memory initcode)
        external pure returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),   // domain separator: never produced by RLP
            deployer,        // the factory executing CREATE2, not the EOA
            salt,            // 256 bits of caller-controlled freedom
            keccak256(initcode) // initcode hash — NOT runtime code
        )))));
    }

    function deployCreate() external returns (address actual) {
        actual = address(new Counter());
    }

    function deployCreate2(bytes32 salt)
        external returns (address actual, address predicted)
    {
        bytes memory initcode = type(Counter).creationCode;
        predicted = predictCreate2(address(this), salt, initcode);
        actual = address(new Counter{salt: salt}());
    }

    /// @notice EIP-1167 minimal proxy — 45 bytes, hardwired to impl via DELEGATECALL.
    ///         Assembly writes the runtime bytes directly into memory and CREATE s them.
    ///         The proxy's address is nonce-derived; pair with CREATE2 variant for determinism.
    function deployMinimalProxy(address impl) external returns (address proxy) {
        bytes20 target = bytes20(impl);
        assembly ("memory-safe") {
            let c := mload(0x40)
            // store setup bytes + address slot
            mstore(c, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(c, 0x14), target)  // embed implementation address
            mstore(add(c, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            proxy := create(0, c, 0x37) // 0x37 = 55 bytes initcode for 45-byte runtime
        }
    }
}
```

#### Three details to internalize from this code

| Detail | Why it matters |
| --- | --- |
| `predictCreate` hardcodes the nonce < 0x80 RLP form | A factory starting at nonce 1 (EIP-161) and deploying < 128 children fits this case. Beyond nonce 127 the RLP encoding changes — the lab pins only the common case; `cast compute-address` handles the full range |
| `predictCreate2` takes `initcode`, not a contract type | Forces the caller to pass the full initcode including constructor args — makes the bug impossible at the call site instead of catching it at deployment |
| `deployMinimalProxy` uses `assembly("memory-safe")` | The `memory-safe` annotation tells the compiler the assembly does not violate the memory model, enabling optimizer reasoning across the assembly block |

```solidity
contract DeployerProbeTest is Test {
    DeployerProbe internal probe;

    function setUp() public { probe = new DeployerProbe(); }

    /// [UNIT] CREATE: EIP-161 nonce starts at 1 for contracts.
    function testCreatePredictionMatches() public {
        uint256 nonceBefore = vm.getNonce(address(probe)); // 1, not 0
        address predicted = probe.predictCreate(address(probe), nonceBefore);
        address actual = probe.deployCreate();
        assertEq(actual, predicted, "CREATE address mismatch");
    }

    /// [FUZZ] CREATE2: same salt → same address; different salts → different addresses.
    function testCreate2Determinism(bytes32 saltA, bytes32 saltB) public {
        vm.assume(saltA != saltB);
        (address a1,) = probe.deployCreate2(saltA);
        (address a2,) = probe.deployCreate2(saltA); // re-predict, not re-deploy
        (address b1,) = probe.deployCreate2(saltB);
        assertEq(a1, a2, "same salt must predict same address");
        assertTrue(a1 != b1, "different salts must differ");
    }

    /// [UNIT] Formula hashes initcode (creationCode), not runtimeCode.
    function testPredictUsesInitcodeHash() public view {
        address predicted = probe.predictCreate2(
            address(probe), bytes32(0), type(DeployerProbe).creationCode
        );
        address expected = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(probe), bytes32(0),
            keccak256(type(DeployerProbe).creationCode)
        )))));
        assertEq(predicted, expected);
    }

    /// [UNIT] Minimal proxy runtime is exactly 45 bytes.
    function testMinimalProxyDelegates() public {
        address proxy = probe.deployMinimalProxy(address(probe));
        assertEq(proxy.code.length, 45, "EIP-1167 runtime is 45 bytes");
    }
}
```

## Production References

| Contract | Pattern | Meridian connection |
| --- | --- | --- |
| **Uniswap V3 PoolFactory.sol** | Parameter-derived salt: `keccak256(abi.encodePacked(token0, token1, fee))`. Hard-coded `POOL_INIT_CODE_HASH` as an `immutable`. Periphery `PoolAddress.computeAddress` re-derives off-chain without storage lookups. | Template for parameter-derived determinism in Meridian's market factory. The hard-coded init-code hash also protects against implementation drift — address changes loudly on template change. |
| **Safe SafeProxyFactory.sol** | `CREATE2` with `salt = keccak256(abi.encode(userSalt, nonce))`. Counterfactual wallet addresses — fund, sign, deploy later. Proxy-deployed before owner setup is complete. | Counterfactual pattern for Meridian's deployment schedule — publish addresses before contracts exist. |
| **OZ Clones.sol** | `clone` / `cloneDeterministic` / `predictDeterministicAddress` trio. Production assembly version of `deployMinimalProxy`. The only safe way to hand-roll EIP-1167 in 2026. | Meridian's `MeridianFactory` (weekly project) should inherit from this rather than hand-rolling assembly. |
| **Solady CREATE3.sol** | Two-hop pattern: `CREATE2` an intermediate that `CREATE`s the real contract. Child address = f(salt) only — independent of factory address or initcode. Cross-chain same-salt same-address. | Ch 31 (L2 deployment) — same salt, same address on Ethereum and rollups. |

> **Ask these four questions of every factory you read** —  
>  1. Who can choose the salt? 2. Who can burn it? 3. What happens to predictions if the template changes? 4. Is the implementation address verified after deployment?

## Security Analysis — Factory & Lifecycle Vulnerability Classes

**Salt Griefing & Address Squatting** —   If a factory accepts arbitrary salts, an attacker precomputes any address and deploys their own contract there first — permanent griefing of that salt, even before the factory exists (counterfactual). Front-running the factory's first call with the same salt but different initcode also wins the address permanently.  
**Fix:** namespace salt as `keccak256(abi.encode(msg.sender, userSalt))` — each caller can only burn their own namespace. Locked as a Meridian convention this chapter.

**Counterfactual Trust — Wrong Code at the Promised Address** —   A counterfactual address commits to an *initcode hash*, not a behavior. If Alice is promised "Safe at address A" and someone deploys arbitrary code there first, every interaction Alice made with A (deposits, approvals) lands in attacker code. EIP-3607 prevents transactions *from* an address that has code — closing one class of "EOA became a contract" surprises — but does not protect Alice's deposits to A.  
**Fix:** always verify `addr.codehash == expectedHash` after deployment before trusting the address. Never treat a funded-but-empty address as trustworthy.

**Metamorphic Contracts — What EIP-6780 Actually Removed** —   Pre-Cancun: `SELFDESTRUCT` + `CREATE2` across two separate transactions allowed a contract to die and be reborn at the same address with different code. EIP-6780 kills the two-transaction path — deletion is now restricted to same-transaction creation.   **Residual paths post-EIP-6780:** (a) Create-and-destroy within *one* transaction, then redeploy later. (b) EIP-7702 EOA delegation — "the code at this address changed" via a different mechanism. Audits must still treat "address has code" as a mutable fact, through a narrower set of vectors.  
**Fix:** never rely on code-at-address being permanent. Check codehash at use time for critical security decisions. Treat EIP-7702 delegation as a separate metamorphic surface.

**Constructor-Revert Balance Trap** —   If a creation frame reverts, the account is not committed — but a value transfer happens *before* execution. A contract that runs out of gas mid-constructor may leave the sent value stranded at a never-committed address. `try/catch` that assumes "revert = refund" is wrong here.  
**Fix:** check `created.code.length > 0` after any value-carrying deployment. Handle the zero-code failure path explicitly — do not assume the value returned on revert.

**Nonce-Coupled Surprises with CREATE** —   Any internal nonce consumption (another factory function doing a `CREATE` for an unrelated reason) shifts every subsequent child address. EIP-161's nonce-1 rule means the first child of a contract is *not* at the same address as the first child of a fresh EOA — a classic off-by-one in hand-rolled predictors.  
**Fix:** use CREATE2 for any factory where address predictability matters. For CREATE-based factories, lock the nonce sequence — no other CREATE calls in the same contract.

## Gas Optimization

Numbers derived from the published post-London/EIP-3860 fee schedule.

| Scenario | Gas | Formula |
| --- | --- | --- |
| Base creation (both CREATE and CREATE2) | 32,000 | Fixed |
| CREATE2 initcode hash surcharge (1,000-byte initcode) | +192 | 6 × ⌈1000/32⌉ = 6 × 32 |
| EIP-1167 proxy code deposit (45 bytes) | +9,000 | 45 × 200 |
| **Total: deploy one proxy instance** | **~41,000** | 32,000 + 9,000 + overhead |
| Full implementation code deposit (8,000 bytes) | +1,600,000 | 8,000 × 200 |
| **Total: deploy full implementation per instance** | **~1,632,000** | 32,000 + 1,600,000 + overhead |

### Zero-byte address savings — worth a salt-search

Calldata charges 4 gas per zero byte and 16 gas per non-zero byte. An address with two leading zero bytes saves approximately 24 gas on every external call that references it as a calldata argument. Finding such an address via salt-search typically takes 2⁴⁰–2⁴⁸ candidates — seconds to minutes scripted on `anvil`. For a hot-path contract like `OracleRegistry`, called on every liquidation check, this compounds meaningfully.

### Address derivation vs storage read for child address lookup

A factory that returns a child address on every call has two options: read from storage (2,100 gas cold / 100 gas warm) or re-derive from the formula (~35–45 gas for two keccaks + packing). For frequently queried addresses, re-derivation in a `pure` function is cheaper than even a warm `SLOAD` per call. Ch 08 measures the full pattern: the key insight is that a `pure` derivation has no storage dependency and is always "warm."

## Common Mistakes

- **Hashing runtime code instead of initcode in the CREATE2 predictor.** The formula requires `keccak256(initcode)`. For a parameterized constructor: `keccak256(abi.encodePacked(type(C).creationCode, abi.encode(args)))`. Using only `type(C).creationCode` when args exist produces a silently wrong address.
- **Omitting `0xff` or truncating the wrong hash.** The formula truncates the *final keccak* to its last 20 bytes: `uint160(uint256(keccak256(...)))`. Truncating `keccak256(initcode)` instead is a real bug seen in audited code.
- **Assuming SELFDESTRUCT still refunds or deletes code in external calls.** EIP-6780 (Cancun, 2024) made it a balance transfer in external calls. State-clearing logic built on it is silently broken.
- **Treating a CREATE2 address as deployment-proof.** The address existing does not mean *your* code is there. Verify `codehash` after deployment, especially across upgrades or counterfactual deployments.
- **Using CREATE when the contract must be counterfactual.** The CREATE address depends on nonce — it cannot be predicted without knowing the exact deployment sequence. Use CREATE2 for counterfactual addresses.
- **Accepting raw user salts without namespacing.** Any user can precompute and burn any address. Namespace: `keccak256(abi.encode(msg.sender, userSalt))`.
- **Hard-coding implementation address in minimal proxies without verification.** A mutable implementation behind 45-byte proxies is a single-point compromise. Use `immutable` for the implementation address; verify `codehash` after deployment.
- **Ignoring EIP-3860 initcode limits.** Initcode is capped at 49,152 bytes and charged 2 gas/byte. Constructors that build large initcode in memory (e.g. embedding a full implementation in a factory) silently hit the cap and revert.

## Exercises & Weekly Project

### Conceptual exercises

- **Hand-derive** the CREATE address of a fresh EOA's first contract (nonce 0) and of a contract's first CREATE child (nonce 1, EIP-161). Verify both with `cast compute-address` on `anvil`.
- **Write a `predictCreate2`** that handles a constructor argument: `type(C).creationCode + abi.encode(arg)`. Confirm that two different args produce two different addresses with the same salt.
- **Explain in one paragraph** why EIP-6780 did not remove the need to check `codehash` after a counterfactual deployment. What residual attack is still possible?
- **Salt-search:** write a script on `anvil` that finds a salt producing an address with two leading zero bytes for a fixed initcode hash. Record how many iterations it took.
- **Read `Clones.sol`** and explain why `cloneDeterministic` + `predictDeterministicAddress` are the production-safe pair versus hand-rolled assembly.

### Weekly Project — MeridianFactory v0

> **Project 1.5 · meridian/src/MeridianFactory.sol** —  
>  The deployment layer skeleton Ch 20 (`MeridianVault`) and Ch 22 (`OracleRegistry`) will instantiate. Do **not** add implementation logic yet — the audit checklist is exactly the four factory questions.

1. Write `meridian/src/IMeridianFactory.sol` + `MeridianFactory.sol`: 
   `deployMarket(bytes32 salt, address implementation)` — EIP-1167 proxy via CREATE2, salt namespaced by `msg.sender`. 
   `predictMarket(bytes32 salt, address implementation)` — pure predictor; NatSpec must document that it hashes initcode, not runtime. 
   `verifyMarket(address market, address implementation)` — checks `codehash == keccak256(EIP-1167 runtime with impl embedded)`.
2. Full Meridian style: `onlyOwner` on `deployMarket`; event `MarketDeployed(address indexed market, address implementation, bytes32 salt)`; custom errors `Unauthorized()`, `MarketExists()`; `external` visibility; `calldata` args; no external calls in modifiers; full NatSpec.
3. Write `test/MeridianFactory.t.sol`: unit (deploy → predict → verify); fuzz (same userSalt from two senders → different addresses); invariant ("every deployed market's codehash equals the expected minimal-proxy codehash").
4. Write `docs/deployment-addresses.md` — the counterfactual address catalog pattern: factory address, salt-derivation method, and the four audit questions answered for this factory.

> **Success criteria** —  
> All tests green. The four factory audit questions are answered in NatSpec or docs. Salt namespacing is verified by the fuzz test. The invariant holds for all deployed markets. No implementation logic — that arrives in Ch 20.

## Quiz

Tap a question to reveal the answer.

- **Q.** What is the exact CREATE2 address formula, and why is 0xff part of it? 
  **A.** `keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:]`. The `0xff` is a domain-separation byte: RLP-encoded lists (the input to `CREATE`'s formula) always start with `0xc6`, `0xc7`, or similar — never `0xff`. This guarantees the two address spaces are provably disjoint: a `CREATE2` address can never equal a `CREATE` address, regardless of inputs.
- **Q.** A contract is deployed with CREATE2 using type(C).creationCode and salt 0. The constructor takes a uint256 argument. Why does predictCreate2 with bare creationCode produce the wrong address? 
  **A.** Constructor arguments are part of initcode — they are ABI-encoded and appended to `type(C).creationCode` before the EVM executes the constructor. The correct initcode is `abi.encodePacked(type(C).creationCode, abi.encode(arg))`. Using only `type(C).creationCode` hashes a different byte sequence, producing an entirely different address that matches no actual deployment — silently, with no error at the prediction site.
- **Q.** After EIP-6780, what does SELFDESTRUCT do when called on a contract created in an earlier transaction? 
  **A.** Only a forced balance transfer to the beneficiary address. Code and storage survive unchanged. The account is not deleted. The 24,000 gas refund is gone. This makes the two-transaction metamorphic lifecycle — deploy, selfdestruct, redeploy at same address with different code — impossible for contracts not created in the same transaction. Any protocol logic depending on post-Cancun selfdestruct clearing storage or freeing an address is silently broken.
- **Q.** Why can an attacker "burn" a salt on a counterfactual factory, and what is the namespace fix? 
  **A.** A CREATE2 address is a pure function of `(factory_addr, salt, initcode_hash)`. Before the factory exists on-chain (or before it claims the salt), anyone can precompute the address for any salt and deploy their own contract there — permanently occupying that address. Because the factory's address is in the formula, the attacker cannot hit the same address as the real factory would produce, but they can make the salt unusable for the factory's intended initcode. Fix: namespace the salt as `keccak256(abi.encode(msg.sender, userSalt))` — each caller controls only their own namespace, so burning a salt only affects their own deployment space.
- **Q.** Roughly what does deploying a 45-byte EIP-1167 proxy cost versus an 8,000-byte implementation, and why does that make proxy factories viable? 
  **A.** Proxy: ~41,000 gas (32,000 base + 45×200 deposit). Full implementation: ~1,632,000 gas (32,000 + 8,000×200). That is a ~40× reduction per instance. For a protocol that deploys one contract per user, pool, or market, this difference determines whether per-instance deployment is economically feasible at all. At 1,632,000 gas per instance at 30 gwei, deploying 1,000 markets would cost ~48 ETH in deposit costs alone; the proxy path costs ~1.2 ETH.
- **Q.** What does EIP-161 mean for a hand-rolled CREATE predictor, and how does the lab pin it? 
  **A.** EIP-161 specifies that a contract account's nonce starts at 1, not 0. This means the first `CREATE` child of a contract uses nonce 1 in the RLP formula — not nonce 0 as a fresh EOA would. A predictor that uses nonce 0 for the first child of a contract produces the wrong address. The lab's `testCreatePredictionMatches` calls `vm.getNonce(address(probe))` before deployment — which returns 1 for a contract that has not yet deployed a child — and asserts the predicted address matches the actual deployment. This pins the EIP-161 off-by-one explicitly.

## Further Reading

- EIP-1014 **EIP-1014 — Skinny CREATE2** — the original specification; contains the domain-separation proof and the exact formula. One page; read it.
- EIP-6780 **EIP-6780 — SELFDESTRUCT only in same transaction** — the Cancun change; the motivation section explains the metamorphic-contract attack it closed.
- EIP-161 **EIP-161 — State Trie Clearing** — the nonce-1 rule for newly created contracts; essential for correct CREATE predictors.
- EIP-170 **EIP-170 — Contract Code Size Limit** — the 24,576-byte runtime cap; affects factory design for large contracts.
- EIP-3860 **EIP-3860 — Limit and Meter Initcode** — 49,152-byte initcode cap and the 2 gas/byte surcharge; affects large constructor patterns.
- EIP-3607 **EIP-3607 — Reject transactions from senders with deployed code** — closes the "EOA became a contract" transaction class.
- EIP-7702 **EIP-7702 — Set EOA account code** — the new metamorphic surface post-EIP-6780; an EOA can now point at implementation code.
- EIP-1167 **EIP-1167 — Minimal Proxy Contract** — the 45-byte runtime specification with the exact byte sequence and verification method.
- Library **OpenZeppelin Clones.sol** — production EIP-1167 assembly; the safe alternative to hand-rolling. Read `cloneDeterministic` + `predictDeterministicAddress` as the correct pair.
- Library **Solady CREATE3.sol** — two-hop pattern for initcode-independent addresses; Ch 31 prerequisite for cross-chain determinism.
- Reference **Ethereum Yellow Paper §7 (Contract Creation) and §8 (Message Calls)** — the formal specification; read §7 alongside this chapter's lifecycle steps.
