// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForkProbe} from "../src/ForkProbe.sol";
import {IForkProbe} from "../src/IForkProbe.sol";

/// @notice Ch 11 lab tests — unit-test isolation + mainnet-fork integration.
/// @dev Fork tests are gated on MAINNET_RPC_URL (vm.skip when unset) so the
///      suite stays green on hosts without an RPC. CI (Ch 13) sets the env var
///      and may add `[rpc_endpoints]` aliases to foundry.toml; the pinned block
///      (20,000,000) requires archive-capable RPC state. Fork tests never carry
///      gas assertions (Ch 8 methodology: gas lives in local unit tests only).
contract ForkProbeTest is Test {
    /// @dev Pinned mainnet block — determinism over freshness (Ch 11 section).
    ///      All fork tests here execute against this exact block.
    uint256 internal constant PINNED_BLOCK = 20_000_000;

    // Real mainnet addresses (canonical, public). Hardcoded constants, never
    // fetched from the RPC: the fork serves state, not trust (RPC trust model).
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant UNI_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    ForkProbe internal probe;
    address internal owner;
    address internal alice;
    address internal bob;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.label(owner, "owner");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.prank(owner);
        probe = new ForkProbe(owner);
    }

    /// @dev RPC gate: returns the fork URL or "" — fork tests skip when unset.
    function _rpc() internal view returns (string memory) {
        if (!vm.envExists("MAINNET_RPC_URL")) return "";
        return vm.envString("MAINNET_RPC_URL");
    }

    // ── UNIT: test isolation ───────────────────────────────────────────────
    // Every test function runs against a fresh copy of the world (setUp runs
    // once per test). These two tests are a pair: if the runner leaked state
    // between tests, testIsolation_B would observe value == 1 and fail.
    function testIsolation_A_mutates() external {
        probe.poke();
        assertEq(probe.value(), 1);
    }

    function testIsolation_B_seesCleanState() external {
        assertEq(probe.value(), 0); // fails only if state leaked from A
    }

    // ── UNIT: caller identity (Ch 10 conventions) ──────────────────────────
    function testSetValueAsOwner() external {
        vm.prank(owner);
        probe.setValue(42);
        assertEq(probe.value(), 42);
    }

    function testSetValueRevertsForNonOwner() external {
        bytes memory err = abi.encodeWithSelector(IForkProbe.NotOwner.selector, bob, owner);
        vm.expectRevert(err); // parameter-exact form — bare selector matches only no-arg errors
        vm.prank(bob);
        probe.setValue(1);
    }

    // ── UNIT: time travel ──────────────────────────────────────────────────
    function testAccrualNotMature() external {
        vm.expectRevert(
            abi.encodeWithSelector(IForkProbe.AccrualNotMature.selector, probe.lockUntil(), block.timestamp)
        );
        probe.accrue();
    }

    function testAccrualAfterWarp() external {
        vm.warp(probe.lockUntil() + 200);
        assertEq(probe.accrue(), 200 * 1e18);
    }

    // ── UNIT: state journal ────────────────────────────────────────────────
    // snapshotState/revertToState: the non-deprecated names (snapshot/revertTo
    // are legacy aliases — new code uses the *State forms, Ch 11 convention).
    function testSnapshotRevertTo() external {
        vm.prank(owner);
        probe.setValue(1);
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        probe.setValue(2);
        vm.revertToState(snap);
        assertEq(probe.value(), 1);
    }

    // ── FORK: state model ──────────────────────────────────────────────────
    // Two forks of the SAME pinned block are independent states: a mutation
    // applied on fork A is invisible on fork B, and survives a switch back to
    // A. WETH9 layout: balanceOf is a mapping at slot 3 (Ch 6 storage shape).
    function testForkStateIsolation() external {
        string memory rpc = _rpc();
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkA = vm.createFork(rpc, PINNED_BLOCK);
        uint256 forkB = vm.createFork(rpc, PINNED_BLOCK);
        vm.selectFork(forkA);
        bytes32 aliceSlot = keccak256(abi.encode(alice, uint256(3))); // balanceOf[alice]
        vm.store(WETH, aliceSlot, bytes32(uint256(1e18)));
        assertEq(IWETH9(WETH).balanceOf(alice), 1e18);
        vm.selectFork(forkB);
        assertEq(IWETH9(WETH).balanceOf(alice), 0); // independent state
        vm.selectFork(forkA);
        assertEq(IWETH9(WETH).balanceOf(alice), 1e18); // mutation survived the switch
    }

    // ── FORK: block pinning ────────────────────────────────────────────────
    function testForkPinnedBlock() external {
        string memory rpc = _rpc();
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PINNED_BLOCK);
        assertEq(block.number, PINNED_BLOCK); // the fork IS that block
        assertEq(IWETH9(WETH).balanceOf(address(this)), 0); // real state readable
    }

    // ── FORK: real-token integration ───────────────────────────────────────
    // vm.deal funds ETH locally; the real WETH9 contract does the wrapping.
    // Deterministic: no whale hunting, no balance heuristics (StdCheats' token
    // deal() guesses storage slots — WETH's plain layout needs no guessing).
    function testRealWethWrap() external {
        string memory rpc = _rpc();
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PINNED_BLOCK);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        IWETH9(WETH).deposit{value: 100 ether}();
        assertEq(IWETH9(WETH).balanceOf(alice), 100 ether);
    }

    // ── FORK: real oracle integration (Ch 22 OracleRegistry preview) ───────
    // The canonical Chainlink ETH/USD aggregator on mainnet. The sanity band
    // [100, 100_000] USD is deliberately wide: outside it the feed is broken
    // or the fork served the wrong state. answer is scaled by 1e8.
    function testRealChainlinkFeedSanity() external {
        string memory rpc = _rpc();
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PINNED_BLOCK);
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(ETH_USD_FEED).latestRoundData();
        assertGt(roundId, 0);
        assertGt(answeredInRound, 0);
        assertGt(updatedAt, 0);
        assertGt(answer, 100e8);
        assertLt(answer, 100_000e8);
    }

    // ── FORK: non-standard token quirk (Ch 9 returndata gates, live) ───────
    // Tether's USDT approve() famously returns NO data (returndatasize == 0) —
    // the exact quirk SafeERC20._callOptionalReturn treats as success. This
    // test pins the real contract's behavior at the pinned block. 0 → non-zero
    // allowance is legal on USDT (only non-zero → non-zero reverts).
    function testUsdtApproveReturnsNoData() external {
        string memory rpc = _rpc();
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PINNED_BLOCK);
        (bool ok, bytes memory ret) = USDT.call(abi.encodeCall(IERC20Min.approve, (address(this), 1e6)));
        assertTrue(ok);
        assertEq(ret.length, 0); // the empty-return convention, measured on-chain
    }

    // ── FORK: impersonation (privileged-path rehearsal, 2026 trust surface) ─
    // Read whoever the real Uniswap v3 factory believes is its owner, then act
    // as them on the fork — the safe way to rehearse admin-key paths (Kelp
    // DAO/Drift grounding, Apr 2026) without touching mainnet. If the factory's
    // ABI or owner ever changes, this test is SUPPOSED to fail.
    function testImpersonateUniswapFactoryOwner() external {
        string memory rpc = _rpc();
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PINNED_BLOCK);
        address realOwner = IUniswapV3Factory(UNI_V3_FACTORY).owner();
        assertTrue(realOwner != address(0));
        vm.prank(realOwner);
        IUniswapV3Factory(UNI_V3_FACTORY).setOwner(alice);
        assertEq(IUniswapV3Factory(UNI_V3_FACTORY).owner(), alice);
    }
}

/// @dev Minimal WETH9 surface (deposit + balanceOf) for fork tests.
interface IWETH9 {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal ERC20 surface for the USDT empty-return pin.
interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal Chainlink aggregator surface.
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Minimal Uniswap v3 factory surface (owner + setOwner).
interface IUniswapV3Factory {
    function owner() external view returns (address);
    function setOwner(address newOwner) external;
}
