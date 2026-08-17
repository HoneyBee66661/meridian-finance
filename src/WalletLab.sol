// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IWalletLab} from "./IWalletLab.sol";

/// @title WalletLab
/// @notice Pedagogical smart-account validation: signature + nonce + chain.
/// @dev NOT part of the protocol — an account-abstraction lab.
contract WalletLab is IWalletLab {
    address public immutable owner;
    uint256 public nonce;

    /// @dev secp256k1 curve order / 2 — the low-s bound (malleability guard).
    uint256 private constant _SECP256K1N_HALF =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @dev Validate a userOp hash: correct signer, fresh nonce, right chain.
    function validateUserOp(
        bytes32 hash,
        uint256 expectedNonce,
        uint256 chainId,
        bytes calldata sig
    ) external view returns (bool) {
        if (chainId != block.chainid) revert WrongChain(block.chainid, chainId);
        if (expectedNonce != nonce) revert InvalidNonce(nonce, expectedNonce);

        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (bytes32 r, bytes32 s, uint8 v) = _split(sig);
        // Reject malleable (high-s) signatures — s must be in the lower half of the curve order.
        if (uint256(s) > _SECP256K1N_HALF) revert InvalidSignature();
        address signer = ecrecover(ethHash, v, r, s);
        if (signer != owner) revert InvalidSignature();
        return true;
    }

    function consumeNonce() external {
        nonce += 1;
    }

    function _split(bytes calldata sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        r = bytes32(sig[0:32]);
        s = bytes32(sig[32:64]);
        v = uint8(sig[64]);
    }
}
