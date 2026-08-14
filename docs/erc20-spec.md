# MER Token Specification (ERC-20 Deep Dive — Ch 14)

> Canonical spec for `MeridianToken.sol` (MER). Locked in Ch 14; extensions in
> later chapters (sMER = Ch 23, gMER = Ch 15, vault = Ch 20) build on this file.

## Identity

| Field | Value |
|---|---|
| Name | `Meridian Token` |
| Symbol | `MER` |
| Decimals | `18` |
| EIP-712 name (permit) | `Meridian Token` (must match token name) |
| EIP-712 version | `"1"` |
| Initial supply | `10_000_000e18` minted at construction to the initial recipient (emits `Transfer(0x0, recipient, supply)`) |
| Base | OpenZeppelin v5.7.0 `ERC20` + `ERC20Burnable` + `ERC20Permit` + `AccessControl` |

## Semantics (what MER does)

1. **Plain ERC-20.** `transfer`, `approve`, `transferFrom`, `totalSupply`,
   `balanceOf`, `allowance` — exactly per EIP-20. No transfer fee, no rebase,
   no transfer hooks. Fee capture is OFF-token: lending-spread revenue accrues
   to sMER stakers via ERC4626 share appreciation (Ch 23).
2. **Permit (ERC-2612).** Gasless approvals: `permit(owner, spender, value,
   deadline, v, r, s)` with EIP-712 typed data. Domain separator binds
   `chainId` + `verifyingContract` → cross-chain replay is impossible.
   Nonce-per-owner, monotonic; replay of a consumed signature reverts with
   `ERC2612InvalidSigner`.
3. **Mint (role-gated).** `mint(to, value)` requires `MINTER_ROLE`. Zero
   receiver reverts (`ERC20InvalidReceiver(0)`). No supply cap: supply policy
   is a governance decision (the timelock holds `DEFAULT_ADMIN_ROLE` from Ch 25).
4. **Burn.** `burn(value)` (own tokens, permissionless) and
   `burnFrom(account, value)` (allowance-gated, exactly like `transferFrom`).
   No `BURNER_ROLE` needed — burning one's own tokens is a user right.
5. **Roles (AccessControl).** `DEFAULT_ADMIN_ROLE` (grants/revokes, held by
   governance) and `MINTER_ROLE` (the supply control surface).

## Error catalog (canon, resolves the Ch 2 PROVISIONAL for tokens)

All errors come from the OpenZeppelin v5 interface catalog — never hand-rolled:

- `IERC20Errors` (ERC-6093 draft): `ERC20InsufficientBalance(sender, balance,
  needed)`, `ERC20InvalidSender(sender)`, `ERC20InvalidReceiver(receiver)`,
  `ERC20InsufficientAllowance(spender, allowance, needed)`,
  `ERC20InvalidApprover(approver)`, `ERC20InvalidSpender(spender)`.
- ERC-2612: `ERC2612ExpiredSignature(deadline)`, `ERC2612InvalidSigner(signer,
  owner)` (v5.7 names), plus `InvalidAccountNonce(account, currentNonce)`.
- `IAccessControl`: `AccessControlUnauthorizedAccount(account, neededRole)`,
  `AccessControlBadConfirmation()`.
- Protocol-specific: `InvalidConstructorAddress(account)` (constructor
  zero-address guard).

## Design decisions & non-decisions (audit trail)

| Decision | Rationale |
|---|---|
| No transfer fee | Fee-on-transfer breaks every downstream accounting model (Ch 17); Meridian's fee capture is the lending spread → sMER |
| No supply cap | MINTER_ROLE *is* the cap mechanism; a numeric cap is a governance policy, not a constructor constant |
| No pause | Emergency controls belong to the ops layer (Ch 38), not the token |
| OZ v5 base, not hand-rolled | Every v5 minor release ships an external audit (audits/ in the lib) |
| `burnFrom` over a role | Third-party burns flow through the allowance surface — one authorization model, not two |
| `nonces` explicit override | Resolves the IERC20Permit diamond (inherited via ERC20Permit AND IMeridianToken); C3 requires stating the override |

## Gas profile (lab-pinned, forge 1.7.1 / solc 0.8.24 / cancun / optimizer 200)

Op-level (gasleft probes, warm contract, incl. call overhead):

| Regime | Gas | Meaning |
|---|---|---|
| transfer, warm, not dirty, both slots nonzero | ~9,554 | 2× SSTORE reset (2,900) + LOG2 + calldata |
| transfer, self, dirty sender slot | ~3,954 | SSTORE at EIP-2200 dirty price (100) |
| transfer, dirty slots (loop) | ~3,989 | repeated writes in one tx are 100 each |
| transfer, cold receiver slot | ~27,380 | 22,100 cold SSTORE + 2,100 cold SLOAD + SET |
| permit (warm, dirty) | ~10,984 | ecrecover + hashing + 2 dirty SSTOREs |

Test-level (`.gas-snapshot`, whole test incl. harness):
transfer 47,291 · approve 41,330 · transferFrom 73,655 · permit 69,093 ·
permit+transferFrom 82,992 · mint 32,153 · burn 27,487 · self-transfer 19,255.

## Integration guidance (for Ch 20's vault and all future consumers)

1. Always `SafeERC20` (`safeTransfer`/`safeTransferFrom`/`forceApprove`) — the
   Ch 9 returndata gates; never raw `transfer`/`approve` calls.
2. `forceApprove` for allowance (two-step on false-returning tokens).
3. Permit-first UX: signatures for approvals, on-chain tx only when needed.
4. MER is a *plain* ERC20 — integrations may assume exact balances, no hooks,
   `true` returns. Fee-on-transfer / rebasing assets are excluded at the
   market-listing layer (Ch 17/20).

## Not in this file (later chapters)

- sMER (ERC4626 staking vault) — Ch 23 (design in Ch 16).
- gMER (ERC-5805/6372 governance wrapper) — Ch 15.
- Market asset whitelist & FoT handling — Ch 17, Ch 20.
