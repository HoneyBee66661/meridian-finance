// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUpgradeLab} from "./IUpgradeLab.sol";

/// @title UpgradeLab
/// @notice Pedagogical EIP-1967 implementation-switching proxy (admin slot +
///         delegatecall fallback).
/// @dev NOT part of the protocol — the pattern lab. The fallback forwards
///      unrecognized calls to the implementation; the admin-path routing of a
///      full transparent proxy (OZ TransparentUpgradeableProxy) is absent:
///      admin() answers directly and every caller, admin or not, is routed.
contract UpgradeLab is IUpgradeLab {
    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 private constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor() {
        _setAdmin(msg.sender);
    }

    function upgradeTo(address newImplementation) external {
        if (msg.sender != admin()) revert NotAdmin(msg.sender);
        if (newImplementation.code.length == 0) revert InvalidImplementation(newImplementation);
        _setImplementation(newImplementation);
    }

    function admin() public view returns (address) {
        return _getSlot(ADMIN_SLOT);
    }

    /// @dev Routes unrecognized calls to the implementation via delegatecall.
    ///      Caller-based admin routing is not implemented (pattern lab only).
    fallback() external payable {
        address impl = _getSlot(IMPL_SLOT);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _getSlot(bytes32 slot) internal view returns (address value) {
        assembly { value := sload(slot) }
    }

    function _setAdmin(address a) internal {
        assembly { sstore(ADMIN_SLOT, a) }
    }

    function _setImplementation(address i) internal {
        assembly { sstore(IMPL_SLOT, i) }
    }
}
