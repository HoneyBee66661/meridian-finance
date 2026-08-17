// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRollupLab} from "./IRollupLab.sol";

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
        if (b.challenged) revert InvalidStateRoot(b.stateRoot, bytes32(0));
        if (b.finalized) revert AlreadyFinalized(b.stateRoot);
        b.finalized = true;
    }
}
