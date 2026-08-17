// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMeridianFactory} from "./IMeridianFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title MeridianFactory
/// @notice Deployment layer for Meridian markets (v0 — Ch 5).
/// @dev Deploys EIP-1167 minimal proxies via CREATE2 (EIP-1014).
///      Salts are namespaced by msg.sender: salt' = keccak256(msg.sender, salt),
///      so a caller can only ever burn addresses inside its own namespace.
///      Owner-gated (timelock added in M6) per the Ch 5 security rule.
/// @custom:security Contact security@meridian.finance
contract MeridianFactory is IMeridianFactory, Ownable {
    using Clones for address;

    /// @dev EIP-1167 runtime prefix: forward call via DELEGATECALL.
    bytes internal constant PROXY_PREFIX = hex"363d3d373d3d3d363d73";
    /// @dev EIP-1167 runtime suffix: delegatecall result return.
    bytes internal constant PROXY_SUFFIX = hex"5af43d82803e903d91602b57fd5bf3";

    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IMeridianFactory
    function deployMarket(bytes32 salt, address implementation)
        external
        override
        onlyOwner
        returns (address market)
    {
        if (implementation == address(0)) {
            revert InvalidImplementation();
        }
        bytes32 nsSalt = keccak256(abi.encode(msg.sender, salt));
        market = implementation.predictDeterministicAddress(nsSalt, address(this));
        if (market.code.length > 0) {
            revert TargetExists(market);
        }
        market = implementation.cloneDeterministic(nsSalt);
        emit MarketDeployed(market, implementation, nsSalt);
    }

    /// @inheritdoc IMeridianFactory
    function predictMarket(bytes32 salt, address implementation)
        external
        view
        override
        returns (address market)
    {
        bytes32 nsSalt = keccak256(abi.encode(msg.sender, salt));
        return implementation.predictDeterministicAddress(nsSalt, address(this));
    }

    /// @inheritdoc IMeridianFactory
    function verifyMarket(address market, address implementation)
        external
        view
        override
        returns (bool ok)
    {
        // A market proxy is genuine iff its runtime is exactly the EIP-1167
        // runtime with `implementation` embedded. Compare codehash, never
        // just `code.length > 0` — the address existing says nothing about
        // whose code is there (Ch 5 counterfactual-trust rule).
        return
            market.codehash
                == keccak256(abi.encodePacked(PROXY_PREFIX, implementation, PROXY_SUFFIX));
    }
}
