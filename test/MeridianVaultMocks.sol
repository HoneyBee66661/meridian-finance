// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IInterestRateModel} from "../src/IInterestRateModel.sol";
import {IMeridianOracle} from "../src/IMeridianOracle.sol";

/// @notice Mintable, hookless ERC-20 for the Ch 20 vault test harness. Plain
///         by construction (no fee-on-transfer, no rebase, no EIP-777 hooks)
///         — the Ch 17 listing-gate shape the vault requires.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimalsOverride;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsOverride = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsOverride;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Fixed-rate interest model: returns a constant per-second borrow rate
///         regardless of utilization. Lets the Ch 20 tests isolate health-factor
///         and accounting math from rate math; the kink implementation is Ch 21.
contract FixedRateInterestRateModel is IInterestRateModel {
    uint256 private immutable _rate; // per-second WAD
    uint256 private immutable _kink; // utilization WAD

    constructor(uint256 rate_, uint256 kink_) {
        _rate = rate_;
        _kink = kink_;
    }

    function borrowRate(uint256) external view returns (uint256) {
        return _rate;
    }

    function supplyRate(uint256) external pure returns (uint256) {
        return 0;
    }

    function kink() external view returns (uint256) {
        return _kink;
    }

    function baseRatePerSecond() external view returns (uint256) {
        return _rate;
    }

    function multiplierPerSecond() external pure returns (uint256) {
        return 0;
    }

    function jumpMultiplierPerSecond() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Configurable-price oracle implementing the full `IMeridianOracle`
///         surface (Chainlink-shaped + TWAP + per-asset `getPrice`). `setPrice`
///         simulates feed moves the Ch 20 tests use for oracle-price scenarios.
contract MockOracle is IMeridianOracle {
    mapping(address => uint256) public priceOf;

    function setPrice(address asset, uint256 price) external {
        priceOf[asset] = price;
    }

    function getPrice(address asset) external view returns (uint256) {
        return priceOf[asset];
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }

    function consult(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
