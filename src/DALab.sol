// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDALab} from "./IDALab.sol";

/// @title DALab
/// @notice Pedagogical post-Fusaka DA model: blob fee, batch cost, DAS bound.
/// @dev NOT part of the protocol — an economics lab.
contract DALab is IDALab {
    uint256 public constant MIN_BASE_FEE = 1; // wei
    uint256 public constant UPDATE_FRACTION = 3338477; // ~2^21.67, EIP-4844
    uint256 public constant TARGET_BLOBS = 14; // per-block target post-BPO2 (EIP-7892); BPO1 (Dec 9, 2025): 10; pre-BPO Fusaka: 6

    /// @dev EIP-1559-style blob base fee from excess blobs.
    function blobFee(uint256 excessBlobs) public pure returns (uint256) {
        // MIN_BASE_FEE * (1 + excess/UPDATE_FRACTION) — linearized fixed-point
        // approximation of the exponential for the lab (the live fee uses the
        // exact EIP-4844 exponential; deltas-not-absolutes, Ch 8).
        return MIN_BASE_FEE + excessBlobs / UPDATE_FRACTION;
    }

    /// @dev Total blob cost for a batch.
    function batchBlobCost(uint256 blobs, uint256 bytesPerBlob, uint256 fee)
        public
        pure
        returns (uint256)
    {
        return blobs * bytesPerBlob * fee;
    }

    /// @dev DAS catch probability: 1 − (1 − f)^k, f in basis points (bps), result in 1e18 fixed-point.
    function samplingCatchProbability(uint256 samples, uint256 withheldFractionBps)
        public
        pure
        returns (uint256)
    {
        // 1e18 scale keeps 20 sequential halvings (k = 20, f = 50%) well above
        // the integer floor — (1/2)^20 × 1e18 ≈ 9.5e14 — so the lab returns a
        // strict probability (≈ 0.9999990), never a rounded 100%.
        uint256 p = 1e18 - withheldFractionBps * 1e14; // (1 - f) in 1e18 scale
        uint256 acc = 1e18;
        for (uint256 i; i < samples; ++i) {
            acc = acc * p / 1e18;
        }
        return 1e18 - acc; // catch prob, 1e18 scale
    }
}
