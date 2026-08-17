// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestnetToken
/// @notice Ch 40 testnet-only mintable ERC-20. Exists so the capstone deploy
///         script has an honest, controllable asset to stand in for real
///         collateral/debt tokens on a testnet (e.g. WETH/USDC stand-ins).
/// @dev TESTNET ONLY — do not use in production: the owner can mint
///      unlimited supply, which is exactly the Ch 17 listing gate a real
///      asset must pass. A production deployment wires the real token
///      addresses as constructor args instead.
contract TestnetToken is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mints testnet supply to `to`.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
