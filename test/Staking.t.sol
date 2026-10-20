// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTest} from "./helpers/VaultTest.sol";
import {HamsterVault} from "../src/HamsterVault.sol";

contract StakingTest is VaultTest {
    // ----------------------------------------------------------------- warm-up
    function test_stakeBelowMinimumReverts() public {
        _giveHamster(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.BelowMinimum.selector);
        vault.stake(1e18 - 1);
    }

    function test_warmupThenWeight() public {
        _stake(alice, 100e18);
        HamsterVault.StakeView memory s = vault.stakeInfo(alice);
        assertEq(s.pending, 100e18);
        assertEq(s.active, 0);
        assertEq(s.pendingActivateAt, block.timestamp + 24 hours);
        assertEq(vault.totalWeight(), 0);
        // Rewards streamed during the warm-up are not earned.
        _depositRewards(700e18);
        vm.warp(block.timestamp + 24 hours - 1);
        vault.sync(10);
        assertEq(vault.totalWeight(), 0);
        vm.warp(block.timestamp + 1);
        vault.sync(10);
        assertEq(vault.totalWeight(), 100e18);
        assertEq(vault.stakeInfo(alice).active, 100e18);
        assertEq(vault.pendingRewards(alice), 0);
        // Afterwards it earns; the stream paused while weight was zero, so a full 7 days remain.
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(vault.pendingRewards(alice), 700e18, 1e6);
    }

    function test_activationIsExactWithoutPoke() public {
        // Nobody touches the vault between activation time and the claim: rewards from the exact
        // activation second are still credited, because the queue replays activations in time.
        _stake(alice, 100e18);
        _stake(bob, 100e18); // same activation time
        vm.warp(block.timestamp + 12 hours);
        _depositRewards(14_000e18); // 2,000 per day for 7 days
        vm.warp(block.timestamp + 12 hours + 3 days); // 3 days of flow since activation
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vault.claimRewards();
        // stream paused for 12h (zero weight) then flowed 3 days: 6,000 split in two.
        assertApproxEqAbs(imd.balanceOf(alice) - before, 3_000e18, 1e6);
    }

    function test_restakeDuringWarmupRestarts() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 12 hours);
        _stake(alice, 50e18);
        assertEq(vault.stakeInfo(alice).pending, 150e18);
        vm.warp(block.timestamp + 12 hours);
        vault.sync(10);
        assertEq(vault.stakeInfo(alice).active, 0); // stale entry skipped
        vm.warp(block.timestamp + 12 hours);
        vault.sync(10);
        assertEq(vault.stakeInfo(alice).active, 150e18);
        assertEq(vault.totalWeight(), 150e18);
    }

    function test_cancelPendingStake() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vault.cancelPendingStake();
        assertEq(vault.stakeInfo(alice).pending, 0);
        assertEq(vault.stakeInfo(alice).unstaking, 100e18);
        vm.warp(block.timestamp + 24 hours);
        vault.sync(10);
        assertEq(vault.totalWeight(), 0);
        vm.prank(alice);
        vault.withdrawUnstaked();
        assertEq(hamster.balanceOf(alice), 100e18);
    }

    function test_syncRequiredWithBacklog() public {
        for (uint256 i; i < 70; ++i) {
            address who = address(uint160(0x5000 + i));
            _stake(who, 1e18);
            vm.warp(block.timestamp + 1);
        }
        vm.warp(block.timestamp + 1 days);
        _giveHamster(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.SyncRequired.selector);
        vault.stake(10e18);
        vault.sync(100);
        vm.prank(alice);
        vault.stake(10e18);
        assertEq(vault.totalWeight(), 70e18);
    }

    // ----------------------------------------------------------------- unstake timing
    function test_unstakeStopsWeightAndReleasesAfter24h() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 24 hours);
        _depositRewards(7_000e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.requestUnstake(100e18);
        assertEq(vault.totalWeight(), 0);
        uint256 earned = vault.pendingRewards(alice);
        assertApproxEqAbs(earned, 1_000e18, 1e6);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawUnstaked();
        vm.warp(block.timestamp + 24 hours - 1);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawUnstaked();
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vault.withdrawUnstaked();
        assertEq(hamster.balanceOf(alice), 100e18);
        // No rewards accrued after the request.
        assertEq(vault.pendingRewards(alice), earned);
        vm.prank(alice);
        vault.claimRewards();
        assertEq(imd.balanceOf(alice), earned);
    }

    function test_unstakeMoreThanActiveReverts() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.InsufficientStake.selector);
        vault.requestUnstake(1e18);
    }

    function test_unstakeQueueOrder() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        vault.requestUnstake(40e18);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.requestUnstake(60e18);
        vm.warp(block.timestamp + 23 hours);
        assertEq(vault.stakeInfo(alice).withdrawableUnstake, 40e18);
        vm.prank(alice);
        vault.withdrawUnstaked();
        assertEq(hamster.balanceOf(alice), 40e18);
        assertEq(vault.unstakesOf(alice).length, 2);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.withdrawUnstaked();
        assertEq(hamster.balanceOf(alice), 100e18);
    }

    // ----------------------------------------------------------------- zero-staker periods
    function test_zeroStakerPeriodWaitsNoWindfall() public {
        _depositRewards(700e18);
        _depositDrip(1_000e18);
        vm.warp(block.timestamp + 3 days);
        // Nothing was distributed: first staker gets no instant payout.
        _stake(alice, 10e18);
        assertEq(vault.pendingRewards(alice), 0);
        vm.warp(block.timestamp + 24 hours);
        vault.sync(10);
        assertEq(vault.pendingRewards(alice), 0);
        assertEq(vault.dripPot(), 1_000e18);
        HamsterVault.RewardsView memory r = vault.rewardsInfo();
        assertEq(r.streamRemaining, 700e18);
        assertEq(r.streamEnd, block.timestamp + 7 days);
        assertEq(r.totalRewardsAccrued, 0);
        // Only now does the flow begin.
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(vault.pendingRewards(alice), 100e18 + 10e18, 1e9);
    }

    function test_gapBetweenStakersCarriesRewards() public {
        _stake(alice, 10e18);
        vm.warp(block.timestamp + 24 hours);
        _depositRewards(700e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.requestUnstake(10e18); // weight zero from here
        vm.warp(block.timestamp + 10 days);
        _stake(bob, 10e18);
        vm.warp(block.timestamp + 24 hours);
        vault.sync(10);
        assertEq(vault.pendingRewards(bob), 0);
        vm.warp(block.timestamp + 6 days);
        assertApproxEqAbs(vault.pendingRewards(bob), 600e18, 1e9);
        assertApproxEqAbs(vault.pendingRewards(alice), 100e18, 1e9);
    }

    // ----------------------------------------------------------------- pro-rata
    function test_proRataByWeight() public {
        _stake(alice, 300e18);
        _stake(bob, 100e18);
        vm.warp(block.timestamp + 24 hours);
        _depositRewards(400e18);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(vault.pendingRewards(alice), 300e18, 1e6);
        assertApproxEqAbs(vault.pendingRewards(bob), 100e18, 1e6);
        vm.prank(alice);
        vault.claimRewards();
        vm.prank(bob);
        vault.claimRewards();
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), 400e18);
        assertEq(vault.trackedImd(), imd.balanceOf(address(vault)));
    }

    function test_claimRewardsNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.claimRewards();
    }

    // ----------------------------------------------------------------- vesting as stake
    function test_vestingCountsAsWeightAndVestsLinearly() public {
        _finalize(alice, 1e18); // 20,000 HAMSTER grant
        _claim(0, alice);
        assertEq(vault.totalWeight(), 20_000e18);
        assertEq(vault.stakeInfo(alice).weight, 20_000e18);
        _depositRewards(700e18);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(vault.pendingRewards(alice), 100e18, 1e6);
        // 1/7 vested after one day
        assertApproxEqAbs(vault.withdrawableVested(alice), uint256(20_000e18) / 7, 1e6);
        vm.prank(alice);
        vault.withdrawVested(10);
        uint256 got = hamster.balanceOf(alice);
        assertApproxEqAbs(got, uint256(20_000e18) / 7, 1e6);
        assertEq(vault.totalWeight(), 20_000e18 - got);
        assertEq(vault.stakeInfo(alice).grantBalance, 20_000e18 - got);
        vm.warp(block.timestamp + 6 days);
        vm.prank(alice);
        vault.withdrawVested(10);
        assertEq(hamster.balanceOf(alice), 20_000e18);
        assertEq(vault.totalWeight(), 0);
        assertEq(vault.stakeInfo(alice).grantCursor, 1);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawVested(10);
    }

    function test_grantsAreNotTransferableOrStakeable() public {
        _finalize(alice, 1e18);
        _claim(0, alice);
        // Nothing left the vault; the grant is only a weight inside it.
        assertEq(hamster.balanceOf(alice), 0);
        assertEq(vault.trackedHamster(), hamster.balanceOf(address(vault)));
    }

    function test_multipleGrantsCursor() public {
        _finalize(alice, 1e18);
        _claim(0, alice);
        vm.warp(block.timestamp + 3 days);
        _finalize(alice, 1e18);
        _claim(1, alice);
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        vault.withdrawVested(1); // only the first, fully vested
        assertEq(hamster.balanceOf(alice), 20_000e18);
        assertEq(vault.stakeInfo(alice).grantCursor, 1);
        vm.prank(alice);
        vault.withdrawVested(10);
        assertApproxEqAbs(hamster.balanceOf(alice), 20_000e18 + uint256(20_000e18) * 4 / 7, 1e6);
    }

    // ----------------------------------------------------------------- drip
    function test_dripOnePercentPerDay() public {
        _stake(alice, 10e18);
        vm.warp(block.timestamp + 24 hours);
        vault.sync(10);
        _depositDrip(10_000e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.claimRewards();
        assertApproxEqRel(imd.balanceOf(alice), 100e18, 1e9);
        assertApproxEqRel(vault.dripPot(), 9_900e18, 1e9);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.claimRewards();
        assertApproxEqRel(imd.balanceOf(alice), 199e18, 1e9);
        // Continuous: half a day pays (1 - sqrt(0.99)) of the 9,801 pot, about 49.13, not a step.
        vm.warp(block.timestamp + 12 hours);
        uint256 p = vault.pendingRewards(alice);
        assertApproxEqRel(p, 49.128128918e18, 1e9);
    }

    function test_dripNotPokeable() public {
        _stake(alice, 10e18);
        vm.warp(block.timestamp + 24 hours);
        _depositDrip(10_000e18);
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.claimRewards();
        uint256 once = imd.balanceOf(alice);
        vm.revertToState(snap);
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vault.sync(0);
            vm.prank(alice);
            vault.claimRewards();
        }
        assertApproxEqRel(imd.balanceOf(alice), once, 1e9);
    }

    function test_dripFactorAccuracy() public pure {
        // 0.99^(1/86400) ^ 86400 is 0.99 within 1e-12.
        uint256 r = 1e18;
        uint256 b = 999999883676675127;
        uint256 n = 86400;
        while (n > 0) {
            if (n & 1 == 1) r = r * b / 1e18;
            b = b * b / 1e18;
            n >>= 1;
        }
        assertApproxEqAbs(r, 0.99e18, 1e6);
    }

    // ----------------------------------------------------------------- game pulls
    function test_backlogStreamsOver30Days() public {
        game.creditStakers(3_000e18);
        imd.mint(address(game), 3_000e18);
        vm.expectRevert(); // not yet the recipient: nothing to withdraw
        vault.pullFromGame();
        game.setStakingRecipient(address(vault));
        _stake(alice, 10e18);
        vm.warp(block.timestamp + 24 hours);
        vault.pullFromGame();
        HamsterVault.RewardsView memory r = vault.rewardsInfo();
        assertEq(r.backlogRemaining, 3_000e18);
        assertEq(r.backlogEnd, block.timestamp + 30 days);
        assertTrue(vault.backlogPulled());
        vm.warp(block.timestamp + 3 days);
        assertApproxEqAbs(vault.pendingRewards(alice), 300e18, 1e6);
        // A later pull joins the 7-day stream.
        game.creditStakers(700e18);
        imd.mint(address(game), 700e18);
        vault.pullFromGame();
        r = vault.rewardsInfo();
        assertEq(r.streamRemaining, 700e18);
        assertEq(r.streamEnd, block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(vault.pendingRewards(alice), 1_000e18 + 700e18, 1e6);
        assertEq(vault.trackedImd(), imd.balanceOf(address(vault)));
    }

    function test_depositRewardsMergesLeftover() public {
        _stake(alice, 10e18);
        vm.warp(block.timestamp + 24 hours);
        _depositRewards(700e18);
        vm.warp(block.timestamp + 3.5 days);
        _depositRewards(350e18);
        HamsterVault.RewardsView memory r = vault.rewardsInfo();
        assertApproxEqAbs(r.streamRemaining, 700e18, 1e6);
        assertEq(r.streamEnd, block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(vault.pendingRewards(alice), 1_050e18, 1e6);
    }

    function test_depositZeroReverts() public {
        vm.expectRevert(HamsterVault.InvalidAmount.selector);
        vault.depositRewards(0);
        vm.expectRevert(HamsterVault.InvalidAmount.selector);
        vault.depositDrip(0);
    }

    // ----------------------------------------------------------------- reserve buckets are not weight
    function test_bucketsNeverCountAsWeight() public {
        assertEq(vault.totalWeight(), 0);
        assertEq(hamster.balanceOf(address(vault)), 8e26);
        _depositRewards(700e18);
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.rewardsInfo().totalRewardsAccrued, 0);
    }

    // ----------------------------------------------------------------- invariants
    function testFuzz_imdConservation(uint256 stakeA, uint256 stakeB, uint256 rewards, uint256 drip, uint32 dt) public {
        stakeA = bound(stakeA, 1e18, 1e24);
        stakeB = bound(stakeB, 1e18, 1e24);
        rewards = bound(rewards, 1, 1e24);
        drip = bound(drip, 1, 1e24);
        _stake(alice, stakeA);
        vm.warp(block.timestamp + 12 hours);
        _stake(bob, stakeB);
        _depositRewards(rewards);
        _depositDrip(drip);
        vm.warp(block.timestamp + uint256(dt));
        uint256 active = vault.stakeInfo(alice).active;
        if (active > 0) {
            vm.prank(alice);
            vault.requestUnstake(active);
        }
        vm.warp(block.timestamp + uint256(dt));
        uint256 a = vault.pendingRewards(alice);
        uint256 b = vault.pendingRewards(bob);
        if (a > 0) {
            vm.prank(alice);
            vault.claimRewards();
        }
        if (b > 0) {
            vm.prank(bob);
            vault.claimRewards();
        }
        assertEq(vault.trackedImd(), imd.balanceOf(address(vault)));
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), rewards + drip);
        assertEq(vault.trackedHamster(), hamster.balanceOf(address(vault)));
    }
}
