// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterVault} from "../../src/HamsterVault.sol";
import {MockERC20, MockGame} from "../helpers/Mocks.sol";
import {VaultTest} from "../helpers/VaultTest.sol";

contract VaultHandler is Test {
    HamsterVault internal vault;
    MockERC20 internal imd;
    MockERC20 internal hamster;
    MockGame internal game;
    address[] public actors;

    uint256 public ghostImdIn;
    uint256 public ghostImdClaimed;
    uint256 public ghostMinedTotal;

    constructor(HamsterVault v, MockERC20 i, MockERC20 h, MockGame g) {
        vault = v;
        imd = i;
        hamster = h;
        game = g;
        for (uint256 j; j < 4; ++j) {
            address a = makeAddr(string(abi.encodePacked("actor", j)));
            actors.push(a);
            vm.prank(a);
            hamster.approve(address(vault), type(uint256).max);
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    function stake(uint256 s, uint256 amt) external {
        address a = _actor(s);
        amt = bound(amt, 1e18, 1_000_000e18);
        hamster.mint(a, amt);
        vm.prank(a);
        vault.stake(amt);
    }

    function requestUnstake(uint256 s, uint256 amt) external {
        address a = _actor(s);
        HamsterVault.StakeView memory sv = vault.stakeInfo(a);
        if (sv.active == 0) return;
        amt = bound(amt, 1, sv.active);
        vm.prank(a);
        vault.requestUnstake(amt);
    }

    function cancelPending(uint256 s) external {
        address a = _actor(s);
        if (vault.stakeInfo(a).pending == 0) return;
        vm.prank(a);
        vault.cancelPendingStake();
    }

    function withdrawUnstaked(uint256 s) external {
        vm.prank(_actor(s));
        try vault.withdrawUnstaked() {} catch {}
    }

    function claimRewards(uint256 s) external {
        address a = _actor(s);
        uint256 before = imd.balanceOf(a);
        vm.prank(a);
        try vault.claimRewards() {
            ghostImdClaimed += imd.balanceOf(a) - before;
        } catch {}
    }

    function depositRewards(uint256 amt) external {
        amt = bound(amt, 1, 1_000_000e18);
        imd.mint(address(this), amt);
        imd.approve(address(vault), amt);
        vault.depositRewards(amt);
        ghostImdIn += amt;
    }

    function depositDrip(uint256 amt) external {
        amt = bound(amt, 1, 1_000_000e18);
        imd.mint(address(this), amt);
        imd.approve(address(vault), amt);
        vault.depositDrip(amt);
        ghostImdIn += amt;
    }

    function gameFees(uint256 amt) external {
        amt = bound(amt, 1, 100_000e18);
        imd.mint(address(game), amt);
        game.creditStakers(amt);
        ghostImdIn += amt;
        try vault.pullFromGame() {} catch {}
    }

    function finalize(uint256 s1, uint256 l1, uint256 s2, uint256 l2, uint256 extra) external {
        if (game.nextFinalizeWindow() > 40) return;
        address[] memory accs = new address[](2);
        uint256[] memory ls = new uint256[](2);
        accs[0] = _actor(s1);
        accs[1] = _actor(s2);
        ls[0] = bound(l1, 0, 30_000e18);
        ls[1] = bound(l2, 0, 30_000e18);
        uint256 total = ls[0] + ls[1] + bound(extra, 0, 1_000e18);
        game.finalizeWindow(accs, ls, total);
    }

    function claimMined(uint256 s, uint256 k) external {
        uint256 n = game.nextFinalizeWindow();
        if (n == 0) return;
        uint256[] memory ws = new uint256[](1);
        ws[0] = bound(k, 0, n - 1);
        try vault.claimMined(ws, _actor(s)) {} catch {}
    }

    function withdrawVested(uint256 s) external {
        vm.prank(_actor(s));
        try vault.withdrawVested(64) {} catch {}
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract VaultInvariantTest is VaultTest {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        game.setStakingRecipient(address(vault));
        handler = new VaultHandler(vault, imd, hamster, game);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_hamsterSolvent() public view {
        assertEq(hamster.balanceOf(address(vault)), vault.trackedHamster());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_bucketsNeverExceeded() public view {
        assertLe(vault.miningCommitted(), vault.miningBucket());
        assertLe(vault.boostCommitted(), vault.boostBucket());
        assertEq(vault.miningBucket() + vault.boostBucket(), 8e26);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_imdSolventAndConserved() public view {
        uint256 held = imd.balanceOf(address(vault)) + game.balances(address(vault));
        assertGe(imd.balanceOf(address(vault)), vault.trackedImd());
        assertEq(held + handler.ghostImdClaimed(), handler.ghostImdIn());
        assertLe(vault.totalRewardsClaimed(), vault.totalRewardsAccrued());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_pendingRewardsCovered() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += vault.pendingRewards(handler.actors(i));
        }
        assertLe(sum, imd.balanceOf(address(vault)) + 1e6);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_hamsterSupplyFixed() public view {
        assertEq(
            hamster.balanceOf(address(vault)) + hamster.balanceOf(address(0xBEEF)) + _actorHamster(),
            hamster.totalSupply()
        );
    }

    function _actorHamster() internal view returns (uint256 s) {
        for (uint256 i; i < handler.actorCount(); ++i) {
            s += hamster.balanceOf(handler.actors(i));
        }
    }
}
