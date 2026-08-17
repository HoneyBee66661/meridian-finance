// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IWalletLab
/// @notice I-prefix interface — a minimal smart-account validator.
interface IWalletLab {
    error InvalidSignature();
    error InvalidNonce(uint256 expected, uint256 got);
    error WrongChain(uint256 expected, uint256 got);

    function validateUserOp(bytes32 hash, uint256 nonce, uint256 chainId, bytes calldata sig)
        external
        view
        returns (bool);
    function consumeNonce() external;
}
