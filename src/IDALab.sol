// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDALab
/// @notice I-prefix interface — the blob-fee and sampling model.
interface IDALab {
    function blobFee(uint256 excessBlobs) external pure returns (uint256);
    function batchBlobCost(uint256 blobs, uint256 bytesPerBlob, uint256 fee)
        external
        pure
        returns (uint256);
    function samplingCatchProbability(uint256 samples, uint256 withheldFractionBps)
        external
        pure
        returns (uint256);
}
