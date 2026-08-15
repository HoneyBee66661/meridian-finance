// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OracleRegistry} from "../src/OracleRegistry.sol";
import {IChainlinkFeed} from "../src/IChainlinkFeed.sol";
import {ITwapSource} from "../src/ITwapSource.sol";
import {IMeridianOracle} from "../src/IMeridianOracle.sol";
import {IMeridianVault} from "../src/IMeridianVault.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MockERC20, FixedRateInterestRateModel} from "./MeridianVaultMocks.sol";

/// @notice Configurable Chainlink-shaped feed for the Ch 22 harness. Every
///         field of `latestRoundData` is settable so the staleness matrix
///         (heartbeat, future timestamps, lagged rounds, non-positive answers)
///         can be exercised directly.
contract MockChainlinkFeed is IChainlinkFeed {
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function setRound(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @notice Configurable TWAP market: `consult` returns a settable price at a
///         settable decimal scale (the registry normalizes per `twapDecimals`).
contract MockTwapMarket is ITwapSource {
    uint256 private _price;
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function consult(address, uint256) external view returns (uint256) {
        return _price;
    }

    function twapDecimals() external view returns (uint8) {
        return _decimals;
    }
}

contract OracleRegistryTest is Test {
    OracleRegistry internal registry;
    MockChainlinkFeed internal ethFeed; // 8-dec USD feed
    MockTwapMarket internal ethTwap; // 18-dec WAD market
    MockChainlinkFeed internal usdcFeed; // 8-dec USD feed
    MockTwapMarket internal usdcTwap; // 18-dec WAD market

    address internal eth;
    address internal usdc;
    address internal dai;
    address internal alice = address(0xA11CE);

    uint256 internal constant STALENESS = 3600; // 1h heartbeat

    function setUp() public {
        vm.warp(1_000_000); // deterministic clock; feeds stamped at `now`
        registry = new OracleRegistry(address(this));
        ethFeed = new MockChainlinkFeed(8);
        ethTwap = new MockTwapMarket(18);
        usdcFeed = new MockChainlinkFeed(8);
        usdcTwap = new MockTwapMarket(18);
        // Raw 8-dec answers (Chainlink USD convention): ETH 2000.00, USDC 1.00
        ethFeed.setRound(100, 2000e8, block.timestamp, block.timestamp, 100);
        usdcFeed.setRound(50, 1e8, block.timestamp, block.timestamp, 50);
        ethTwap.setPrice(2000e18); // WAD fallback, agrees with the primary
        usdcTwap.setPrice(1e18); // WAD fallback, agrees with the primary

        eth = makeAddr("eth");
        usdc = makeAddr("usdc");
        dai = makeAddr("dai");

        registry.setFeed(eth, ethFeed, address(ethTwap), STALENESS, 0, 18);
        registry.setFeed(usdc, usdcFeed, address(0), STALENESS, 0, 18);
    }

    // ---- Primary path --------------------------------------------------------

    function test_getPrice_primaryHealthy_normalizesToWad() public view {
        // 8-dec feed answer 2000e8 -> canonical 18-dec WAD USD
        assertEq(registry.getPrice(eth), 2000e18);
        assertEq(registry.getPrice(usdc), 1e18);
    }

    function testFuzz_getPrice_normalizesFeedDecimals(uint256 raw) public {
        // Any feed scale <= 18 must land on the same WAD price: up-scale is
        // exact (multiplication), so raw * 10^(18 - dec) is the expected WAD.
        raw = bound(raw, 1, 1e30);
        for (uint8 dec = 0; dec <= 18; dec++) {
            MockChainlinkFeed f = new MockChainlinkFeed(dec);
            f.setRound(1, int256(raw), block.timestamp, block.timestamp, 1);
            registry.setFeed(dai, f, address(0), STALENESS, 0, 18);
            assertEq(
                registry.getPrice(dai), raw * (10 ** (18 - dec)), "normalization off at decimals"
            );
        }
    }

    // ---- Staleness matrix: every unhealthy signal routes to the TWAP --------

    function test_getPrice_staleHeartbeat_usesTwap() public {
        vm.warp(block.timestamp + STALENESS + 1);
        assertEq(registry.getPrice(eth), 2000e18); // twap value
    }

    function test_getPrice_exactlyAtHeartbeat_isHealthy() public {
        // updatedAt == now - maxStaleness is still fresh (<= semantics)
        ethFeed.setRound(101, 2000e8, block.timestamp - STALENESS, block.timestamp - STALENESS, 101);
        assertEq(registry.getPrice(eth), 2000e18);
    }

    function test_getPrice_futureTimestamp_unhealthy() public {
        ethFeed.setRound(100, 2000e8, block.timestamp, block.timestamp + 100, 100);
        assertEq(registry.getPrice(eth), 2000e18); // twap
    }

    function test_getPrice_laggedAnsweredInRound_usesTwap() public {
        ethFeed.setRound(101, 2000e8, block.timestamp, block.timestamp, 100); // round not complete
        assertEq(registry.getPrice(eth), 2000e18);
    }

    function test_getPrice_negativeAnswer_usesTwap() public {
        ethFeed.setRound(101, -1, block.timestamp, block.timestamp, 101);
        assertEq(registry.getPrice(eth), 2000e18);
    }

    function test_getPrice_zeroAnswer_usesTwap() public {
        ethFeed.setRound(101, 0, block.timestamp, block.timestamp, 101);
        assertEq(registry.getPrice(eth), 2000e18);
    }

    function test_getPrice_twapScaleNormalized() public {
        // 8-dec twap market: raw 2000e8 must normalize to 2000e18
        MockTwapMarket twap8 = new MockTwapMarket(8);
        twap8.setPrice(2000e8);
        registry.setFeed(dai, usdcFeed, address(twap8), STALENESS, 0, 8);
        ethFeed.setRound(101, -1, block.timestamp, block.timestamp, 101);
        registry.setFeed(eth, ethFeed, address(twap8), STALENESS, 0, 8);
        assertEq(registry.getPrice(eth), 2000e18);
    }

    // ---- Failure modes --------------------------------------------------------

    function test_getPrice_unlistedAsset_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.AssetNotListed.selector, dai));
        registry.getPrice(dai);
    }

    function test_getPrice_staleAndNoFallback_reverts() public {
        // usdc has no twap market; warp past the heartbeat
        vm.warp(block.timestamp + STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.FeedUnhealthy.selector, usdc));
        registry.getPrice(usdc);
    }

    function test_getPrice_staleAndTwapZero_reverts() public {
        ethTwap.setPrice(0);
        vm.warp(block.timestamp + STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleRegistry.FeedUnhealthy.selector, eth));
        registry.getPrice(eth);
    }

    // ---- Deviation guard ------------------------------------------------------

    function test_deviationGuard_revertsOnDivergence() public {
        registry.setFeed(eth, ethFeed, address(ethTwap), STALENESS, 500, 18); // 5% guard
        ethTwap.setPrice(1800e18); // 10% below primary
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleRegistry.DeviationGuardReverted.selector, eth, 2000e18, 1800e18, 1000
            )
        );
        registry.getPrice(eth);
    }

    function test_deviationGuard_withinLimit_passes() public {
        registry.setFeed(eth, ethFeed, address(ethTwap), STALENESS, 500, 18);
        ethTwap.setPrice(1980e18); // 1% below primary
        assertEq(registry.getPrice(eth), 2000e18);
    }

    function test_deviationGuard_disabled_ignoresTwap() public {
        ethTwap.setPrice(1e18); // wildly divergent, guard off
        assertEq(registry.getPrice(eth), 2000e18);
    }

    // ---- Governance (negative tests per Ch 10 convention) ---------------------

    function test_setFeed_onlyAdmin_reverts() public {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE(); // hoisted: Ch 14 #3 rule
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        registry.setFeed(dai, ethFeed, address(0), STALENESS, 0, 18);
    }

    function test_setTwapWindow_onlyAdmin_reverts() public {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE(); // hoisted: Ch 14 #3 rule
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        registry.setTwapWindow(60);
    }

    function test_setFeed_zeroAddress_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(OracleRegistry.InvalidConstructorAddress.selector, address(0))
        );
        registry.setFeed(address(0), ethFeed, address(0), STALENESS, 0, 18);
        vm.expectRevert(
            abi.encodeWithSelector(OracleRegistry.InvalidConstructorAddress.selector, address(0))
        );
        registry.setFeed(dai, IChainlinkFeed(address(0)), address(0), STALENESS, 0, 18);
    }

    function test_setFeed_badDecimals_reverts() public {
        MockChainlinkFeed feed19 = new MockChainlinkFeed(19);
        vm.expectRevert(
            abi.encodeWithSelector(OracleRegistry.InvalidFeedDecimals.selector, uint8(19))
        );
        registry.setFeed(dai, feed19, address(0), STALENESS, 0, 18);
        vm.expectRevert(
            abi.encodeWithSelector(OracleRegistry.InvalidTwapDecimals.selector, uint8(19))
        );
        registry.setFeed(dai, ethFeed, address(ethTwap), STALENESS, 0, 19);
    }

    function test_setFeed_zeroStaleness_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(OracleRegistry.InvalidMaxStaleness.selector, uint256(0))
        );
        registry.setFeed(dai, ethFeed, address(0), 0, 0, 18);
    }

    function test_setFeed_emitsEvent_andStoresConfig() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit OracleRegistry.FeedSet(dai, ethFeed, address(ethTwap), STALENESS, 250, 18);
        registry.setFeed(dai, ethFeed, address(ethTwap), STALENESS, 250, 18);
        (IChainlinkFeed feed, address market, uint256 staleness, uint256 guard, uint8 twapDec) =
            registry.feeds(dai);
        assertEq(address(feed), address(ethFeed));
        assertEq(market, address(ethTwap));
        assertEq(staleness, STALENESS);
        assertEq(guard, 250);
        assertEq(twapDec, 18);
    }

    function test_setTwapWindow_defaultsAndUpdates() public {
        // Constants accessed via the instance getter: solc 0.8.24 rejects
        // `OracleRegistry.DEFAULT_TWAP_WINDOW` (error 9582) — lab-pinned.
        assertEq(registry.twapWindow(), registry.DEFAULT_TWAP_WINDOW());
        vm.expectEmit(true, true, true, true, address(registry));
        emit OracleRegistry.TwapWindowSet(registry.DEFAULT_TWAP_WINDOW(), 900);
        registry.setTwapWindow(900);
        assertEq(registry.twapWindow(), 900);
    }

    // ---- Interface surface ----------------------------------------------------

    function test_latestRoundData_revertsUnsupported() public {
        vm.expectRevert(OracleRegistry.UnsupportedForRegistry.selector);
        registry.latestRoundData();
    }

    function test_decimals_isCanonicalBase() public view {
        assertEq(registry.decimals(), 18);
    }

    function test_consult_passthrough() public view {
        assertEq(registry.consult(address(ethTwap), 1800), 2000e18);
    }

    // ---- Vault integration: the registry is the vault's oracle ----------------

    function test_vault_integration_registryPricedBorrowCapacity() public {
        MockERC20 coll = new MockERC20("ETH", "ETH", 18);
        MockERC20 debt = new MockERC20("USDC", "USDC", 6);
        MeridianVault vault = new MeridianVault(
            address(coll),
            address(debt),
            registry,
            new FixedRateInterestRateModel(0, 0.8e18),
            7500, // 75% CF
            0.8e18, // liquidation threshold (WAD, LT = 80%)
            1000, // 10% incentive
            2000 // 20% reserve
        );
        // Wire the registry to the vault's assets
        registry.setFeed(address(coll), ethFeed, address(ethTwap), STALENESS, 0, 18);
        registry.setFeed(address(debt), usdcFeed, address(usdcTwap), STALENESS, 0, 18);

        coll.mint(alice, 1e18);
        debt.mint(address(this), 1_000_000e6);
        debt.approve(address(vault), type(uint256).max);
        vm.startPrank(alice);
        coll.approve(address(vault), 1e18);
        vault.depositCollateral(1e18);
        vm.stopPrank();

        // 1 ETH @ 2000 USD, 75% CF -> 1500 USD of capacity
        assertEq(vault.borrowCapacity(alice), 1500e6);
        assertEq(vault.healthFactor(alice), type(uint256).max); // no debt

        vm.prank(address(this));
        vault.supplyDebtLiquidity(1_000_000e6);
        vm.prank(alice);
        vault.borrow(750e6);
        // HF = collateralValue*LT / debtValue = 1600 / 750 = 2.1333
        assertEq(vault.healthFactor(alice), 2_133_333_333_333_333_333);

        // Borrowing up to the full capacity succeeds; one wei over reverts
        vm.prank(alice);
        vault.borrow(750e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMeridianVault.BorrowCapacityExceeded.selector, alice, 1500e6 + 1, 1500e6
            )
        );
        vault.borrow(1);
    }

    function test_vault_integration_priceDrop_flipsLiquidatable() public {
        MockERC20 coll = new MockERC20("ETH", "ETH", 18);
        MockERC20 debt = new MockERC20("USDC", "USDC", 6);
        MeridianVault vault = new MeridianVault(
            address(coll),
            address(debt),
            registry,
            new FixedRateInterestRateModel(0, 0.8e18),
            7500,
            0.8e18,
            1000,
            2000
        );
        registry.setFeed(address(coll), ethFeed, address(ethTwap), STALENESS, 0, 18);
        registry.setFeed(address(debt), usdcFeed, address(usdcTwap), STALENESS, 0, 18);

        coll.mint(alice, 1e18);
        debt.mint(address(this), 1_000_000e6);
        debt.approve(address(vault), type(uint256).max);
        vm.startPrank(alice);
        coll.approve(address(vault), 1e18);
        vault.depositCollateral(1e18);
        vm.stopPrank();
        vm.prank(address(this));
        vault.supplyDebtLiquidity(1_000_000e6);
        vm.prank(alice);
        vault.borrow(750e6);

        // Feed goes stale; TWAP drops 55% -> collValue 900, LT-adj 720,
        // HF = 720/750 = 0.96 < 1 -> liquidatable (debt 750 > 0.8 * collValue)
        vm.warp(block.timestamp + STALENESS + 1);
        ethTwap.setPrice(900e18);
        assertEq(registry.getPrice(address(coll)), 900e18);
        assertEq(vault.healthFactor(alice), 0.96e18);
        assertTrue(vault.isLiquidatable(alice));
        // Engine arrives Ch 24-25; v1 reverts as designed
        vm.expectRevert(IMeridianVault.LiquidationNotImplemented.selector);
        vault.liquidate(alice, 1);
    }

    // ---- Gas probes (loop-amplified min-deltas, warm-up first, log-only) -------

    function test_gas_getPrice_primaryHealthy() public {
        registry.getPrice(eth); // warm-up: cold account/SLOAD costs land here
        uint256 min = type(uint256).max;
        for (uint256 i = 0; i < 8; i++) {
            uint256 before = gasleft();
            registry.getPrice(eth);
            uint256 delta = before - gasleft();
            if (delta < min) min = delta;
        }
        emit log_named_uint("gas getPrice primary healthy (min)", min);
    }

    function test_gas_getPrice_twapFallback() public {
        ethFeed.setRound(101, -1, block.timestamp, block.timestamp, 101);
        registry.getPrice(eth); // warm-up
        uint256 min = type(uint256).max;
        for (uint256 i = 0; i < 8; i++) {
            uint256 before = gasleft();
            registry.getPrice(eth);
            uint256 delta = before - gasleft();
            if (delta < min) min = delta;
        }
        emit log_named_uint("gas getPrice twap fallback (min)", min);
    }

    function test_gas_getPrice_deviationGuardOn() public {
        registry.setFeed(eth, ethFeed, address(ethTwap), STALENESS, 500, 18);
        registry.getPrice(eth); // warm-up
        uint256 min = type(uint256).max;
        for (uint256 i = 0; i < 8; i++) {
            uint256 before = gasleft();
            registry.getPrice(eth);
            uint256 delta = before - gasleft();
            if (delta < min) min = delta;
        }
        emit log_named_uint("gas getPrice deviation guard on (min)", min);
    }
}
