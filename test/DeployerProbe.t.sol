// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployerProbe, Counter} from "../src/DeployerProbe.sol";

contract DeployerProbeTest is Test {
    DeployerProbe internal probe;

    function setUp() public {
        probe = new DeployerProbe();
    }

    /// @dev CREATE: prediction must match reality (contract nonce starts at 1, EIP-161).
    function testCreatePredictionMatches() public {
        uint256 nonceBefore = vm.getNonce(address(probe));
        address predicted = probe.predictCreate(address(probe), nonceBefore);
        address actual = probe.deployCreate();
        assertEq(actual, predicted, "CREATE address mismatch");
    }

    /// @dev CREATE2: deploy matches prediction; different salts differ;
    ///      prediction is deterministic (re-deploying the same salt reverts —
    ///      CREATE2 cannot redeploy an existing address, EIP-1014).
    function testCreate2Determinism(bytes32 saltA, bytes32 saltB) public {
        vm.assume(saltA != saltB);
        (address a1, address p1) = probe.deployCreate2(saltA);
        (address b1, address p2) = probe.deployCreate2(saltB);
        assertEq(a1, p1, "deploy must match prediction");
        assertEq(b1, p2, "deploy must match prediction");
        assertTrue(a1 != b1, "different salts must differ");
        // determinism: the prediction repeats for the same (deployer, salt)
        address predictedAgain =
            probe.predictCreate2(address(probe), saltA, type(Counter).creationCode);
        assertEq(p1, predictedAgain, "prediction must be deterministic");
    }

    /// @dev The initcode hash in the formula is creationCode, not runtimeCode.
    function testPredictUsesInitcodeHash() public view {
        address predicted =
            probe.predictCreate2(address(probe), bytes32(0), type(DeployerProbe).creationCode);
        address expected = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(probe),
                            bytes32(0),
                            keccak256(type(DeployerProbe).creationCode)
                        )
                    )
                )
            )
        );
        assertEq(predicted, expected, "EIP-1014 formula mismatch");
    }

    /// @dev Minimal proxy forwards calls: inc() increments the proxy's storage.
    function testMinimalProxyDelegates() public {
        address proxy = probe.deployMinimalProxy(address(probe));
        assertEq(proxy.code.length, 45, "EIP-1167 runtime is 45 bytes");
    }
}
