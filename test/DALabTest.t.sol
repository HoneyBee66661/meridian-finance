// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DALab} from "../src/DALab.sol";

contract DALabTest is Test {
    DALab internal lab;

    function setUp() public {
        lab = new DALab();
    }

    /// @dev Zero excess blobs → minimum blob fee.
    function testMinFee() public {
        assertEq(lab.blobFee(0), 1);
    }

    /// @dev More excess blobs → higher fee (monotonic).
    function testFeeMonotonic(uint256 a, uint256 b) public {
        a = bound(a, 0, 1e7);
        b = bound(b, 0, 1e7);
        if (a > b) (a, b) = (b, a);
        assertLe(lab.blobFee(a), lab.blobFee(b));
    }

    /// @dev DAS: 20 samples, 50% withheld → catch prob ≈ 99.9999% (1e18 scale, strictly < 100%).
    function testSamplingBound() public {
        uint256 p = lab.samplingCatchProbability(20, 5000); // f = 50%
        assertGt(p, 999_999e12); // > 99.9999% in 1e18 scale (0.999999 × 1e18)
        assertLt(p, 1e18); // probabilistic — strictly below 100%
    }

    /// @dev More samples always improve the catch probability.
    function testMoreSamplesBetter(uint256 k1, uint256 k2) public {
        k1 = bound(k1, 1, 100);
        k2 = bound(k2, 1, 100);
        if (k1 > k2) (k1, k2) = (k2, k1);
        assertGe(lab.samplingCatchProbability(k2, 5000), lab.samplingCatchProbability(k1, 5000));
    }
}
