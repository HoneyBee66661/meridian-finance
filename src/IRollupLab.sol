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
