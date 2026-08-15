// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianGovernanceToken} from "../src/MeridianGovernanceToken.sol";
import {StakedMeridian} from "../src/StakedMeridian.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {SimplePriceFeed} from "../src/SimplePriceFeed.sol";
import {OracleRegistry} from "../src/OracleRegistry.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MeridianFactory} from "../src/MeridianFactory.sol";
import {TestnetToken} from "../src/TestnetToken.sol";

/// @title Deploy
/// @notice Ch 40 capstone deployment script — the full Meridian protocol in
///         one `forge script` run: testnet asset stand-ins, price feeds +
///         registry, rate model, the ETH/USDC lending market (vault), the
///         token trio (MER / gMER / sMER), and the factory.
/// @dev Usage (testnet):
///      forge script script/Deploy.s.sol:Deploy --rpc-url $SEPOLIA_RPC \
///          --broadcast --verify
///      The deployer is the broadcast sender (`msg.sender` inside `run()`);
///      in tests the caller is the test contract, which also lets
///      DeploySmoke.t.sol exercise the exact same sequence.
contract Deploy is Script {
    struct Deployment {
        TestnetToken weth;
        TestnetToken usdc;
        SimplePriceFeed wethFeed;
        SimplePriceFeed usdcFeed;
        OracleRegistry oracleRegistry;
        InterestRateModel rateModel;
        MeridianVault ethUsdcVault;
        MeridianToken mer;
        MeridianGovernanceToken gmer;
        StakedMeridian smer;
        MeridianFactory factory;
        address deployer;
    }

    /// @notice Chain constants for the ETH/USDC market (Ch 20/22 grounding).
    uint256 private constant CF_BPS = 7500; // 75% collateral factor
    uint256 private constant LT = 0.8e18; // 80% liquidation threshold
    uint256 private constant LI_BPS = 1000; // 10% liquidation incentive
    uint256 private constant RF_BPS = 2000; // 20% reserve factor
    uint256 private constant FEED_DECIMALS = 8; // USD feed convention
    uint256 private constant MAX_STALENESS = 1 hours;
    uint256 private constant MER_INITIAL_SUPPLY = 10_000_000e18; // 10M MER

    function run() external returns (Deployment memory d) {
        address deployer = msg.sender;
        d.deployer = deployer;

        vm.startBroadcast(deployer);

        // 1. Testnet asset stand-ins (Ch 17 listing: plain ERC-20, mintable
        //    only on testnet).
        d.weth = new TestnetToken("Testnet WETH", "tWETH", 18);
        d.usdc = new TestnetToken("Testnet USDC", "tUSDC", 6);

        // 2. Price feeds + registry (Ch 22 wiring: primary feed with
        //    staleness check; deviation guard + TWAP fallback off for
        //    testnet — set via setFeed args if desired).
        d.wethFeed = new SimplePriceFeed(uint8(FEED_DECIMALS));
        d.wethFeed.setPrice(2000e8); // ETH at $2,000
        d.usdcFeed = new SimplePriceFeed(uint8(FEED_DECIMALS));
        d.usdcFeed.setPrice(1e8); // USDC at $1
        d.oracleRegistry = new OracleRegistry(deployer);
        d.oracleRegistry.setFeed(address(d.weth), d.wethFeed, address(0), MAX_STALENESS, 0, 0);
        d.oracleRegistry.setFeed(address(d.usdc), d.usdcFeed, address(0), MAX_STALENESS, 0, 0);

        // 3. Rate model (Ch 21 params: 2% base, 10% multiplier, 100% jump,
        //    kink at 80%, 20% reserve).
        d.rateModel = new InterestRateModel(
            _aprToPerSecond(2e16),
            _aprToPerSecond(1e17),
            _aprToPerSecond(1e18),
            8e17,
            uint64(RF_BPS)
        );

        // 4. The isolated lending market (Ch 20) — oracle = registry, so the
        //    vault consumes the Ch 22 price-resolution path.
        d.ethUsdcVault = new MeridianVault(
            address(d.weth),
            address(d.usdc),
            d.oracleRegistry,
            d.rateModel,
            uint64(CF_BPS),
            LT,
            uint64(LI_BPS),
            uint64(RF_BPS)
        );

        // 5. Token trio: MER (Ch 14), gMER (Ch 15), sMER (Ch 23).
        d.mer = new MeridianToken(deployer, deployer, deployer, MER_INITIAL_SUPPLY);
        d.gmer = new MeridianGovernanceToken(address(d.mer), "Meridian Governance", "gMER");
        d.smer = new StakedMeridian(address(d.mer), deployer, address(d.ethUsdcVault));

        // 6. Factory (Ch 25) — further markets via deployMarket.
        d.factory = new MeridianFactory();

        vm.stopBroadcast();
    }

    /// @dev APR (WAD) -> per-second rate, the InterestRateModel convention.
    function _aprToPerSecond(uint256 apr) internal pure returns (uint256) {
        return apr / 365 days;
    }
}
