// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ITrustChainLab} from "./ITrustChainLab.sol";

/// @title TrustChainLab
/// @notice Pedagogical access-control measurement contract: role gates with
///         separated powers (Ch 25 pattern). NOT part of the protocol.
contract TrustChainLab is AccessControl, ITrustChainLab {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RISK_ROLE = keccak256("RISK_ROLE");

    bool public paused;
    uint256 public collateralFactor; // WAD
    uint256 public pendingCollateralFactor;

    /// @dev Pedagogical grant: DEFAULT_ADMIN_ROLE goes to the deployer so the
    ///      lab is self-contained. In production it belongs to the Safe 3/5
    ///      multisig, never an EOA — the audit checklist flags this.
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
    }

    function unpause() external onlyRole(OPERATOR_ROLE) {
        if (!paused) revert NotPaused();
        paused = false;
    }

    /// @dev Risk changes are staged: schedule (RISK_ROLE) then execute
    ///      (ADMIN) — the lab's stand-in for the timelock two-step.
    function scheduleCollateralFactor(uint256 cf) external onlyRole(RISK_ROLE) {
        pendingCollateralFactor = cf;
    }

    function executeCollateralFactor() external onlyRole(DEFAULT_ADMIN_ROLE) {
        collateralFactor = pendingCollateralFactor;
    }
}
