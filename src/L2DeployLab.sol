// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2DeployLab} from "./IL2DeployLab.sol";

/// @title L2DeployLab
/// @notice Pedagogical L2 market: whitelisted cross-chain messages, stale
///         oracle guard, per-chain admin. NOT part of the protocol.
contract L2DeployLab is IL2DeployLab {
    /// @dev Arbitrum's L1→L2 alias offset (AddressAliasHelper): canonical
    ///      delivery presents the aliased address, never the raw L1 one.
    uint160 internal constant L1_TO_L2_ALIAS_OFFSET =
        uint160(0x1111000000000000000000000000000000001111);

    address public immutable l1Vault; // the canonical source on L1
    address public admin; // per-chain Safe (Ch 25)
    uint256 public oraclePrice;
    uint256 public oracleTimestamp;
    uint256 public constant MAX_ORACLE_AGE = 1 hours;

    constructor(address l1Vault_, address admin_) {
        l1Vault = l1Vault_;
        admin = admin_;
    }

    /// @dev Cross-L2 message: only the L1 vault, whitelisted payloads.
    ///      Canonical L1→L2 delivery never presents the raw L1 address as
    ///      msg.sender — Arbitrum aliases it (checked below, AddressAliasHelper
    ///      style) and OP Stack routes via the L2CrossDomainMessenger, where
    ///      sourceSender is the recovered xDomainMessageSender. Verify both the
    ///      delivery path and the declared L1 source.
    function executeCrossMessage(address sourceSender, bytes calldata payload) external {
        if (msg.sender != _applyL1ToL2Alias(l1Vault)) revert UnauthorizedSender(msg.sender);
        if (sourceSender != l1Vault) revert UnauthorizedSender(sourceSender);
        bytes4 sel = bytes4(payload[:4]);
        if (sel != this.applyMarketState.selector) revert UnauthorizedPayload(sel);
        (bool ok, bytes memory ret) = address(this).call(payload);
        if (!ok) {
            // Bubble the inner revert reason instead of flattening it.
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
    }

    /// @dev Arbitrum-style L1→L2 aliasing (AddressAliasHelper.applyL1ToL2Alias),
    ///      inlined so the lab needs no extra dependency.
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + L1_TO_L2_ALIAS_OFFSET);
        }
    }

    /// @dev Pedagogical stub: a real market re-validates sender, payload
    ///      selector, AND amount bounds here. The whitelist gate above is only
    ///      the entry check — amount bounds are deliberately NOT enforced, so
    ///      do not copy this stub as a complete destination-side validation.
    function applyMarketState(uint256 newCollateralFactor) external {}

    /// @dev Oracle update with a staleness guard (Ch 22).
    function setOraclePrice(uint256 price, uint256 timestamp) external {
        if (msg.sender != admin) revert UnauthorizedSender(msg.sender);
        if (block.timestamp > timestamp + MAX_ORACLE_AGE) {
            revert OracleStale(timestamp, MAX_ORACLE_AGE);
        }
        oraclePrice = price;
        oracleTimestamp = timestamp;
    }

    function healthOf(address) external pure returns (uint256) {
        return 1e18;
    }
}
