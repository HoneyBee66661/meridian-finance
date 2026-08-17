// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMessagingLab} from "./IMessagingLab.sol";

/// @title MessagingLab
/// @notice Pedagogical generalized bridge receiver: the five invariants as
///         code. NOT part of the protocol.
contract MessagingLab is IMessagingLab {
    /// @dev Arbitrum aliases L1 senders on L2: L2Alias = L1 + 0x1111...1111
    ///      (AddressAliasHelper). OP Stack instead delivers from its
    ///      L2CrossDomainMessenger, exposing the true sender via
    ///      xDomainMessageSender(). Same L1→L2 aliasing trap as Ch 31's
    ///      L2DeployLab: a raw msg.sender == canonicalSource check never
    ///      matches a genuine cross-chain call.
    uint160 internal constant L1_TO_L2_ALIAS_OFFSET =
        uint160(0x1111000000000000000000000000000000001111);

    address public immutable canonicalSource;
    uint256 public immutable maxMessageAmount;
    mapping(bytes32 => bool) public executed;

    constructor(address canonicalSource_, uint256 maxMessageAmount_) {
        canonicalSource = canonicalSource_;
        maxMessageAmount = maxMessageAmount_;
    }

    /// @dev The five invariants, in order (Ch 32 theory).
    function receiveMessage(address sourceSender, bytes calldata payload) external {
        // 1. source authenticated — canonical L1→L2 delivery never hands this
        //    contract the raw L1 address as msg.sender; compare against the
        //    aliased address (Arbitrum) / messenger-recovered sender (OP).
        address aliasedSource;
        unchecked {
            aliasedSource = address(uint160(canonicalSource) + L1_TO_L2_ALIAS_OFFSET);
        }
        if (msg.sender != aliasedSource) revert UnauthorizedSource(msg.sender);

        // 2. no replay
        bytes32 h = keccak256(abi.encode(sourceSender, payload));
        if (executed[h]) revert Replay(h);

        // 3. payload whitelisted
        bytes4 sel = bytes4(payload[:4]);
        if (sel != this.applyTransfer.selector) revert UnauthorizedPayload(sel);

        // 4. destination re-validation (amount bounds)
        (address to, uint256 amount) = abi.decode(payload[4:], (address, uint256));
        if (amount > maxMessageAmount) revert InvalidAmount(amount, maxMessageAmount);

        // 5. conservation enforced by the accounting (invariant 5)
        executed[h] = true;
        _applyTransfer(to, amount);
    }

    function applyTransfer(address to, uint256 amount) external {}
    function _applyTransfer(address to, uint256 amount) internal {}
}
