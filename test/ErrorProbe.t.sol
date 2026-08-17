// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ErrorProbe, IErrorProbe} from "../src/ErrorProbe.sol";

/// @title LegacyStringProbe
/// @notice Test-only twin of `ErrorProbe` with the SAME function surface but
///         require-string reverts — exists purely to measure the deployment
///         and revert-shape cost of the string style. Violates the locked
///         convention — never copy.
contract LegacyStringProbe {
    uint256 public immutable bound;

    constructor(uint256 bound_) {
        bound = bound_;
    }

    function probe(uint256 value) external {
        require(value <= bound, "ErrorProbe: value above bound");
        emit IErrorProbe.ProbeAccepted(msg.sender, value);
    }

    function probeLegacy(uint256 value) external {
        require(value <= bound, "ErrorProbe: value above bound (legacy)");
        emit IErrorProbe.ProbeAccepted(msg.sender, value);
    }
}

/// @notice Foundry lab for Chapter 2: custom errors vs require strings,
///         measured and pinned (Ch 2 Foundry Lab spec).
contract ErrorProbeTest is Test {
    uint256 internal constant BOUND = 100;

    ErrorProbe internal probe;
    LegacyStringProbe internal legacy;

    function setUp() public {
        probe = new ErrorProbe(BOUND);
        legacy = new LegacyStringProbe(BOUND);
    }

    // --- Revert-shape tests ---

    /// @dev A param'd custom error reverts with selector + args; the selector
    ///      alone can't be expected via vm.expectRevert — assert the shape
    ///      with a low-level call instead.
    function test_RevertShape_CustomSelector() public {
        (bool ok, bytes memory ret) =
            address(probe).call(abi.encodeWithSelector(IErrorProbe.probe.selector, BOUND + 1));
        assertFalse(ok);
        assertEq(bytes4(ret), IErrorProbe.AboveBound.selector);
        assertEq(ret.length, 4 + 64); // selector + bound + received
    }

    /// @dev Full payload: selector + bound + received (typed, decodable).
    function test_RevertShape_CustomPayload() public {
        vm.expectRevert(abi.encodeWithSelector(IErrorProbe.AboveBound.selector, BOUND, BOUND + 1));
        probe.probe(BOUND + 1);
    }

    /// @dev Legacy path reverts as Error(string) — opaque, must string-match.
    function test_RevertShape_LegacyString() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "ErrorProbe: value above bound"));
        legacy.probe(BOUND + 1);
    }

    // --- Event tests ---

    /// @dev Accepting a value emits ProbeAccepted with the caller as topic.
    function test_Event_ProbeAcceptedIndexedCaller() public {
        vm.expectEmit(true, true, true, true);
        emit IErrorProbe.ProbeAccepted(address(this), 42);
        probe.probe(42);
    }

    /// @dev Both probe and probeLegacy emit the same event shape.
    function test_Event_LegacyEmitsSameShape() public {
        vm.expectEmit(true, true, true, true);
        emit IErrorProbe.ProbeAccepted(address(this), 42);
        legacy.probe(42);
    }

    // --- Revert-data size (durable claim; gasleft around try/catch is
    //     polluted by call overhead — Ch 2 methodology note) ---

    /// @dev Custom revert data (68 B) must be shorter than Error(string)
    ///      (100 B for a 29-char message) — the measure that survives
    ///      compiler drift.
    function test_RevertData_CustomShorterThanLegacy() public {
        (bool ok1, bytes memory ret1) =
            address(probe).call(abi.encodeWithSelector(IErrorProbe.probe.selector, BOUND + 1));
        (bool ok2, bytes memory ret2) =
            address(legacy).call(abi.encodeWithSelector(IErrorProbe.probe.selector, BOUND + 1));
        assertFalse(ok1);
        assertFalse(ok2);
        assertLt(ret1.length, ret2.length, "custom revert data must be shorter");
        emit log_named_uint("custom revert bytes", ret1.length);
        emit log_named_uint("string revert bytes", ret2.length);
    }

    // --- Deployment-size tests ---

    /// @dev The string twin must have a larger creationCode (string embedded).
    function test_DeploymentSize_LegacyBigger() public {
        uint256 customSize = type(ErrorProbe).creationCode.length;
        uint256 legacySize = type(LegacyStringProbe).creationCode.length;
        assertGt(legacySize, customSize, "string twin must be bigger");
        emit log_named_uint("ErrorProbe creationCode bytes", customSize);
        emit log_named_uint("LegacyStringProbe creationCode bytes", legacySize);
    }

    /// @dev Both under the EIP-170 24,576-byte cap (sanity for the era).
    function test_DeploymentSize_UnderEip170() public {
        assertLt(type(ErrorProbe).creationCode.length, 24576);
        assertLt(type(LegacyStringProbe).creationCode.length, 24576);
    }

    // --- Fuzz ---

    /// @dev Any value above the bound reverts carrying the fuzzed value —
    ///      the typed error is the invariant oracle.
    function testFuzz_ProbeBoundary_CarriesValue(uint256 value) public {
        vm.assume(value > BOUND);
        vm.expectRevert(abi.encodeWithSelector(IErrorProbe.AboveBound.selector, BOUND, value));
        probe.probe(value);
    }

    /// @dev Never reverts within the bound; probe leaves no storage behind
    ///      (events are its only side effect; ErrorProbe has no storage slots).
    function testFuzz_AcceptsWithinBound_NoState(uint256 value) public {
        vm.assume(value <= BOUND);
        probe.probe(value);
        assertEq(vm.load(address(probe), 0), bytes32(0), "no storage written");
    }
}
