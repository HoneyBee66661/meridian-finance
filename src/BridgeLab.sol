// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeLab} from "./IBridgeLab.sol";

/// @title BridgeLab
/// @notice Pedagogical destination-side bridge receiver: re-validates sender,
///         whitelists payloads, blocks replays. NOT part of the protocol.
contract BridgeLab is IBridgeLab {
    address public immutable authorizedSource; // the source bridge contract
    mapping(bytes32 => bool) public executed;

    /// @dev Self-call only — target functions are reachable exclusively through
    ///      executeMessage's gated path, never as public entry points.
    modifier onlyViaExecuteMessage() {
        if (msg.sender != address(this)) revert UnauthorizedSender(msg.sender);
        _;
    }

    constructor(address authorizedSource_) {
        authorizedSource = authorizedSource_;
    }

    /// @dev Destination-side execution: source must be authorized, payload
    ///      must be a whitelisted shape, and the message must be new.
    function executeMessage(address sourceSender, bytes calldata payload) external {
        if (msg.sender != authorizedSource) revert UnauthorizedSender(msg.sender);
        if (payload.length < 4) revert UnauthorizedPayload(bytes4(0)); // length guard

        bytes4 selector = bytes4(payload[:4]);
        if (
            selector != this.applyMarketUpdate.selector
                && selector != this.applyCollateralFactor.selector
        ) {
            revert UnauthorizedPayload(selector);
        }

        bytes32 h = keccak256(abi.encode(sourceSender, payload));
        if (executed[h]) revert MessageReplay(h);
        executed[h] = true;

        // destination-side re-validation happens in the target functions
        (bool ok, bytes memory ret) = address(this).call(payload);
        if (!ok) {
            // bubble the target's revert so the caller sees the real reason
            assembly { revert(add(ret, 32), mload(ret)) }
        }
    }

    /// @dev Whitelisted target — re-validates the bounds the source claimed.
    ///      Self-call only (see onlyViaExecuteMessage).
    function applyMarketUpdate(address market, uint256 newValue) external onlyViaExecuteMessage {
        if (market == address(0)) revert InvalidMarket(market);
        if (newValue > 1e27) revert ValueOutOfBounds(newValue);
    }

    /// @dev Whitelisted target — collateral factor stays within [0, 100%].
    function applyCollateralFactor(uint256 cf) external onlyViaExecuteMessage {
        if (cf > 1e18) revert ValueOutOfBounds(cf);
    }
}
