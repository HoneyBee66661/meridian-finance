// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IMeridianOracle} from "../src/IMeridianOracle.sol";

/// @notice ABI contract test for IMeridianOracle (Ch 3 Weekly Project):
///         selector pins + calldata-length predictions via abi.encodeCall.
contract MeridianOracleAbiTest is Test {
    /// @dev Canonical selectors pinned (cast sig verified on mainnet feeds).
    function test_Selectors_Pinned() public pure {
        assertEq(
            bytes4(abi.encodeCall(IMeridianOracle.latestRoundData, ())),
            bytes4(0xfeaf968c) // Chainlink AggregatorV3Interface.latestRoundData()
        );
        assertEq(
            bytes4(abi.encodeCall(IMeridianOracle.decimals, ())),
            bytes4(0x313ce567) // ERC20-style decimals()
        );
    }

    /// @dev consult(address,uint256) selector — canonical form only.
    function test_Consult_Selector() public pure {
        bytes4 sel = bytes4(keccak256("consult(address,uint256)"));
        assertEq(bytes4(abi.encodeCall(IMeridianOracle.consult, (address(0), 0))), sel);
    }

    /// @dev abi.encodeCall length for consult = 4 + 32 + 32 = 68 bytes.
    function testFuzz_Consult_CalldataLength(address market, uint256 secondsAgo) public pure {
        bytes memory data = abi.encodeCall(IMeridianOracle.consult, (market, secondsAgo));
        assertEq(data.length, 68);
        // reference wire format: selector + market right-aligned + secondsAgo
        bytes memory expected = abi.encodePacked(
            IMeridianOracle.consult.selector, bytes32(uint256(uint160(market))), bytes32(secondsAgo)
        );
        assertEq(data, expected);
    }

    /// @dev latestRoundData calldata = 4 bytes (five static heads, no args).
    function test_LatestRoundData_CalldataLength() public pure {
        bytes memory data = abi.encodeCall(IMeridianOracle.latestRoundData, ());
        assertEq(data.length, 4);
    }
}
