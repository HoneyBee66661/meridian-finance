// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Cheatcode lab for the Foundry Workflow chapter — pedagogical, NOT protocol code.
/// @dev Each public function targets exactly the EVM state Foundry cheatcodes
///      manipulate: caller identity (`vm.prank`), time/height (`vm.warp`/`vm.roll`),
///      ETH balance (`vm.deal`), and raw storage (`vm.store`/`vm.load`). Written
///      to repo conventions: custom errors declared in the interface, full
///      NatSpec, CEI ordering, immutables for construction-fixed values, no
///      require strings.
interface IFoundryProbe {
    /// @notice The caller is not the contract owner.
    error NotOwner(address caller, address owner);

    /// @notice Accrual attempted before the lock period elapsed.
    error AccrualNotMature(uint256 nowTs, uint256 matureTs);

    /// @notice The probe's ETH transfer failed.
    error TransferFailed(address to, uint256 amount);

    /// @notice Emitted on every successful `setValue`.
    event ValueSet(address indexed setter, uint256 value);

    /// @notice Emitted on every `accrue`, with the period covered.
    event FeesAccrued(uint256 amount, uint256 periodStart, uint256 periodEnd);

    /// @notice Owner-only write of `value`; the classic access-control target.
    function setValue(uint256 newValue) external;

    /// @notice Time-gated accrual: `ratePerSecond` applied over the elapsed
    ///         seconds since the last accrual, reverting until `lockDuration`
    ///         has passed since deployment.
    function accrue(uint256 ratePerSecond) external;

    /// @notice Owner pulls `amount` wei of ETH held by the probe to `to`.
    function withdrawEth(address to, uint256 amount) external;

    /// @notice The current owner (storage slot 0).
    function owner() external view returns (address);

    /// @notice The owner-set value (storage slot 1).
    function value() external view returns (uint256);

    /// @notice Accrual lock duration in seconds, fixed at construction.
    function lockDuration() external view returns (uint256);

    /// @notice Deployment timestamp.
    function startTs() external view returns (uint256);

    /// @notice Deployment block number.
    function startBlock() external view returns (uint256);

    /// @notice Accumulated accrual units.
    function accrued() external view returns (uint256);

    /// @notice Timestamp of the last accrual.
    function lastTs() external view returns (uint256);

    /// @notice Number of blocks since deployment.
    function blocksSinceDeploy() external view returns (uint256);
}

/// @notice Cheatcode lab implementation — see `IFoundryProbe`.
contract FoundryProbe is IFoundryProbe {
    address public owner;
    uint256 public value;
    uint256 public accrued;
    uint256 public lastTs;

    uint256 public immutable lockDuration;
    uint256 public immutable startTs;
    uint256 public immutable startBlock;

    /// @notice Sets the deployer as owner and fixes the accrual lock.
    /// @param _lockDuration Seconds the accrual stays immature after deploy.
    constructor(uint256 _lockDuration) {
        owner = msg.sender;
        lockDuration = _lockDuration;
        startTs = block.timestamp;
        startBlock = block.number;
        lastTs = block.timestamp;
    }

    /// @dev Access-control gate: only `owner` may pass. Custom error, no string.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);
        _;
    }

    /// @inheritdoc IFoundryProbe
    function setValue(uint256 newValue) external onlyOwner {
        value = newValue;
        emit ValueSet(msg.sender, newValue);
    }

    /// @inheritdoc IFoundryProbe
    function accrue(uint256 ratePerSecond) external onlyOwner {
        uint256 matureTs = startTs + lockDuration;
        if (block.timestamp < matureTs) revert AccrualNotMature(block.timestamp, matureTs);

        uint256 elapsed = block.timestamp - lastTs;
        uint256 gain = (elapsed * ratePerSecond) / 1e18;
        accrued += gain;
        emit FeesAccrued(gain, lastTs, block.timestamp);
        lastTs = block.timestamp;
    }

    /// @inheritdoc IFoundryProbe
    function withdrawEth(address to, uint256 amount) external onlyOwner {
        // CEI: effects (none) then interaction; the balance check is implicit in the call.
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }

    /// @inheritdoc IFoundryProbe
    function blocksSinceDeploy() external view returns (uint256) {
        return block.number - startBlock;
    }

    /// @notice Accepts ETH transfers into the probe.
    receive() external payable {}
}
