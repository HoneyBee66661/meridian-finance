// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMeridianOracle} from "./IMeridianOracle.sol";
import {IChainlinkFeed} from "./IChainlinkFeed.sol";
import {ITwapSource} from "./ITwapSource.sol";

/// @title OracleRegistry
/// @notice Protocol contract #5 (Ch 22): the single manipulation-resistance
///         decision point for every Meridian price. Implements the Ch 3/Ch 20
///         `IMeridianOracle` surface that `MeridianVault` consumes.
/// @dev Design locked in Ch 22 (ledger):
///      - **Per-asset feed config**: Chainlink primary (heartbeat/staleness
///        checked on `updatedAt` + `answeredInRound`), on-chain TWAP fallback
///        (Uniswap-v2-style accumulator market), optional deviation guard.
///      - **Canonical base**: every price is normalized to 18-dec WAD USD per
///        whole token — the scale `MeridianVault.borrowCapacity` divides by
///        `10 ** tokenDecimals`, so the vault arithmetic is scale-consistent
///        for any token decimals (the interface NatSpec's "2000e8" example is
///        informal; the vault's math is authoritative).
///      - **Listing gate** (Ch 17): feed decimals must be <= 18, twap decimals
///        <= 18, nonzero staleness window; a listed asset that loses both
///        sources reverts `FeedUnhealthy` — an unpriced asset is an unhealthy
///        asset (IMeridianOracle NatSpec).
///      - **Deviation guard**: when enabled per feed (bps, 0 = disabled), a
///        primary price that diverges from the TWAP by more than the guard
///        reverts `DeviationGuardReverted` — liquidations pause on a suspect
///        price rather than executing on one (safe direction; Ch 24-25 handle
///        pause semantics).
///      - **Privileged surface**: `DEFAULT_ADMIN_ROLE` only (setFeed /
///        setTwapWindow) — held by the Ch 25 timelock in production. A feed
///        config key is an admin key (Kelp DAO/Drift, Apr 2026, ~$285-292M).
///      - v1 is **plain storage** (like MeridianVault v1, Ch 20): ERC-7201
///        namespacing applies when markets become proxies (Ch 38).
///      - `latestRoundData()` (no-arg, Ch 3 ABI pin) is deliberately
///        unsupported on a multi-asset registry — the per-asset surface is
///        `getPrice`; reverts `UnsupportedForRegistry` (documented deviation).
contract OracleRegistry is AccessControl, IMeridianOracle {
    using Math for uint256;

    /// @notice Canonical price base: 18-dec WAD USD per whole token.
    uint8 public constant PRICE_DECIMALS = 18;

    /// @notice Default TWAP look-back window (30 minutes).
    uint256 public constant DEFAULT_TWAP_WINDOW = 1800;

    /// @notice Per-asset feed configuration (packed per Ch 6: feed +
    ///         twapMarket share one slot, maxStaleness one, guard + twapDecimals
    ///         one — three slots per listed asset).
    struct FeedConfig {
        IChainlinkFeed feed; // primary source
        address twapMarket; // fallback source (ITwapSource)
        uint256 maxStaleness; // seconds; primary older than this is stale
        uint256 deviationGuardBps; // 0 = disabled
        uint8 twapDecimals; // decimals of twapMarket.consult() output
    }

    /// @notice Feed configuration per asset. Zero feed address == not listed.
    mapping(address asset => FeedConfig) public feeds;

    /// @notice TWAP look-back window used by the fallback path (seconds).
    uint256 public twapWindow;

    /// @notice The asset has no feed configured.
    error AssetNotListed(address asset);

    /// @notice Primary is stale AND no usable TWAP fallback exists.
    error FeedUnhealthy(address asset);

    /// @notice A constructor/listing address argument was the zero address.
    error InvalidConstructorAddress(address account);

    /// @notice Feed decimals above the supported maximum (18).
    error InvalidFeedDecimals(uint8 feedDecimals);

    /// @notice TWAP market decimals above the supported maximum (18).
    error InvalidTwapDecimals(uint8 twapDecimals);

    /// @notice Nonzero staleness window required.
    error InvalidMaxStaleness(uint256 maxStaleness);

    /// @notice The deviation guard (when enabled) was breached: primary and
    ///         TWAP disagree by more than the configured bps. Reverting here
    ///         pauses liquidations on a suspect price — the safe direction.
    error DeviationGuardReverted(
        address asset, uint256 primaryPrice, uint256 twapPrice, uint256 deviationBps
    );

    /// @notice The no-arg Chainlink-shaped surface is meaningless on a
    ///         multi-asset registry; the per-asset surface is `getPrice`.
    error UnsupportedForRegistry();

    /// @notice Feed configuration changed.
    event FeedSet(
        address indexed asset,
        IChainlinkFeed feed,
        address twapMarket,
        uint256 maxStaleness,
        uint256 deviationGuardBps,
        uint8 twapDecimals
    );

    /// @notice TWAP window changed.
    event TwapWindowSet(uint256 oldWindow, uint256 newWindow);

    /// @param admin_ The initial `DEFAULT_ADMIN_ROLE` holder (Ch 25 timelock
    ///        in production).
    constructor(address admin_) {
        if (admin_ == address(0)) revert InvalidConstructorAddress(address(0));
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        twapWindow = DEFAULT_TWAP_WINDOW;
    }

    // ---- Governance (DEFAULT_ADMIN_ROLE; Ch 25 timelock in production) -----

    /// @notice Lists or reconfigures the price sources for `asset`.
    /// @dev Listing requirements (the Ch 17 listing gate applied to prices):
    ///      non-zero asset and feed; feed decimals <= 18 (validated by an
    ///      external `decimals()` call — the feed must be a live aggregator);
    ///      twap decimals <= 18; nonzero staleness window. `twapMarket` may be
    ///      zero (primary-only listing); `deviationGuardBps` 0 = disabled.
    /// @param asset The token to price.
    /// @param feed The Chainlink primary feed.
    /// @param twapMarket The TWAP fallback market (0 = none).
    /// @param maxStaleness Seconds the primary may be silent before the
    ///        registry treats it as stale.
    /// @param deviationGuardBps Max |primary - twap| / max(primary, twap) in
    ///        bps before `getPrice` reverts (0 = disabled).
    /// @param twapDecimals Decimals of `twapMarket.consult` output.
    function setFeed(
        address asset,
        IChainlinkFeed feed,
        address twapMarket,
        uint256 maxStaleness,
        uint256 deviationGuardBps,
        uint8 twapDecimals
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || address(feed) == address(0)) {
            revert InvalidConstructorAddress(asset == address(0) ? asset : address(feed));
        }
        uint8 feedDecimals = feed.decimals();
        if (feedDecimals > PRICE_DECIMALS) revert InvalidFeedDecimals(feedDecimals);
        if (twapDecimals > PRICE_DECIMALS) revert InvalidTwapDecimals(twapDecimals);
        if (maxStaleness == 0) revert InvalidMaxStaleness(maxStaleness);

        feeds[asset] = FeedConfig({
            feed: feed,
            twapMarket: twapMarket,
            maxStaleness: maxStaleness,
            deviationGuardBps: deviationGuardBps,
            twapDecimals: twapDecimals
        });
        emit FeedSet(asset, feed, twapMarket, maxStaleness, deviationGuardBps, twapDecimals);
    }

    /// @notice Sets the TWAP look-back window used by the fallback path.
    function setTwapWindow(uint256 twapWindow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (twapWindow_ == 0) revert InvalidMaxStaleness(twapWindow_);
        emit TwapWindowSet(twapWindow, twapWindow_);
        twapWindow = twapWindow_;
    }

    // ---- Price resolution ---------------------------------------------------

    /// @inheritdoc IMeridianOracle
    /// @dev Primary path: Chainlink round must be complete (`answeredInRound >=
    ///      roundId`), positive, non-future, and within `maxStaleness`. Any
    ///      failure falls back to the TWAP market; if neither source is usable
    ///      the call reverts `FeedUnhealthy` — the vault then cannot compute
    ///      borrow capacity or health, which is the designed failure mode (no
    ///      borrowing, no liquidations on an unpriced asset). When the
    ///      deviation guard is enabled the TWAP is read even on the healthy
    ///      path and a breach reverts.
    function getPrice(address asset) external view returns (uint256) {
        FeedConfig storage cfg = feeds[asset];
        if (address(cfg.feed) == address(0)) revert AssetNotListed(asset);

        bool primaryHealthy;
        uint256 primary;
        try cfg.feed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            primaryHealthy = answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp
                && block.timestamp - updatedAt <= cfg.maxStaleness && answeredInRound >= roundId;
            if (primaryHealthy) {
                primary = _normalize(uint256(answer), cfg.feed.decimals(), PRICE_DECIMALS);
            }
        } catch {
            primaryHealthy = false; // feed missing/decoding failed — treat as stale
        }

        if (primaryHealthy) {
            if (cfg.deviationGuardBps != 0) {
                uint256 twapCheck = _twapPrice(cfg);
                if (twapCheck != 0) {
                    uint256 dev = _deviationBps(primary, twapCheck);
                    if (dev > cfg.deviationGuardBps) {
                        revert DeviationGuardReverted(asset, primary, twapCheck, dev);
                    }
                }
            }
            return primary;
        }

        uint256 twap = _twapPrice(cfg);
        if (twap == 0) revert FeedUnhealthy(asset);
        return twap;
    }

    /// @inheritdoc IMeridianOracle
    /// @dev Passthrough: forwards to the market's own `consult` (the Ch 3 ABI
    ///      pin). The registry does not interpret the market — the fallback
    ///      path calls this same surface internally with `twapWindow`.
    function consult(address market, uint256 secondsAgo) external view returns (uint256) {
        return ITwapSource(market).consult(market, secondsAgo);
    }

    /// @inheritdoc IMeridianOracle
    /// @dev Unsupported by design on a multi-asset registry — see
    ///      `UnsupportedForRegistry`. Kept on the surface so the Ch 3 ABI pins
    ///      hold; every caller must use `getPrice`.
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert UnsupportedForRegistry();
    }

    /// @inheritdoc IMeridianOracle
    /// @return The canonical price base (18 = WAD USD per whole token).
    function decimals() external pure returns (uint8) {
        return PRICE_DECIMALS;
    }

    // ---- Internals ----------------------------------------------------------

    /// @dev Reads and normalizes the fallback TWAP; 0 when no market is
    ///      configured or the market returns 0 (pair too young / window too
    ///      long — the market's own contract, per the listing contract).
    function _twapPrice(FeedConfig storage cfg) internal view returns (uint256) {
        if (cfg.twapMarket == address(0)) return 0;
        uint256 raw = ITwapSource(cfg.twapMarket).consult(cfg.twapMarket, twapWindow);
        if (raw == 0) return 0;
        return _normalize(raw, cfg.twapDecimals, PRICE_DECIMALS);
    }

    /// @dev Rescales `raw` from `decimals` to `target` decimals (both <= 18,
    ///      enforced at listing). Floor on the down-scale path — a price that
    ///      rounds down understates collateral, the conservative direction
    ///      (Ch 4/16 rounding policy).
    function _normalize(uint256 raw, uint8 decimals_, uint8 target)
        internal
        pure
        returns (uint256)
    {
        if (decimals_ == target) return raw;
        if (decimals_ > target) return raw / (10 ** (decimals_ - target));
        return raw * (10 ** (target - decimals_));
    }

    /// @dev |a - b| / max(a, b) in bps; both inputs nonzero (caller checks).
    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > b) return (a - b).mulDiv(10_000, a);
        return (b - a).mulDiv(10_000, b);
    }
}
