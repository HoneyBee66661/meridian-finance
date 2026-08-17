// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakedMeridian} from "./IStakedMeridian.sol";

/// @title StakedMeridian
/// @notice ERC-4626 staking vault: sMER shares appreciate as protocol revenue
///         accrues. Virtual-offset defense against the donation/inflation
///         attack; tracked-assets accounting; hookless MER (Ch 17 lock).
/// @dev NOT upgradeable in v1 (Ch 38 adds the proxy). All state below follows
///      EIP-1967-friendly layout discipline anyway.
contract StakedMeridian is IStakedMeridian {
    using SafeERC20 for IERC20;

    uint256 private constant VIRTUAL_ASSETS = 1e18;
    uint256 private constant VIRTUAL_SHARES = 1e18;

    IERC20 public immutable underlying;
    address public immutable rewardsAdmin; // Ch 25: governor/multisig path
    address public immutable meridianVault; // the only notifier in v1 (Ch 20)

    uint256 internal _totalAssets; // TRACKED assets — never balanceOf
    uint256 internal _totalShares; // TRACKED share supply — single writer
    mapping(address => uint256) internal _shares;

    constructor(address underlying_, address rewardsAdmin_, address meridianVault_) {
        underlying = IERC20(underlying_);
        rewardsAdmin = rewardsAdmin_;
        meridianVault = meridianVault_;
    }

    /// @notice Record protocol revenue. Only the lending vault may call in v1;
    ///         the rewards admin (Ch 25) takes over via proxy in Ch 38.
    function notifyReward(uint256 amount) external {
        if (msg.sender != meridianVault && msg.sender != rewardsAdmin) {
            revert NotAuthorized(msg.sender);
        }
        if (amount == 0) return;
        // Pull, then account — the transfer can only fail loudly.
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        _totalAssets += amount;
    }

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function totalSupply() public view returns (uint256) {
        return _totalShares;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, _totalShares + VIRTUAL_SHARES, _totalAssets + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, _totalAssets + VIRTUAL_ASSETS, _totalShares + VIRTUAL_SHARES);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        _totalAssets += assets;
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        if (shares > _shares[owner]) revert InsufficientBalance(_shares[owner], shares);
        assets = convertToAssets(shares);
        if (assets == 0) revert ZeroAssets();
        _burn(owner, shares);
        _totalAssets -= assets;
        underlying.safeTransfer(receiver, assets);
    }

    function _mint(address to, uint256 shares) internal {
        _shares[to] += shares;
        _totalShares += shares;
    }

    function _burn(address from, uint256 shares) internal {
        _shares[from] -= shares;
        _totalShares -= shares;
    }
}
