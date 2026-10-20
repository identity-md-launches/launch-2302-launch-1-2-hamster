// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTest} from "./helpers/VaultTest.sol";
import {HamsterVault} from "../src/HamsterVault.sol";
import {MockERC20, MockGame} from "./helpers/Mocks.sol";

/// @notice Independent edge and failure-path tests: boundaries, repeated calls, wrong callers, empty
/// inputs. Complements the implementation's own suites without repeating their happy paths.
contract VaultEdgesTest is VaultTest {
    function _skipTo(uint256 k) internal {
        while (game.nextFinalizeWindow() < k) {
            game.finalizeEmpty();
        }
    }

    function _windows(uint256 from, uint256 n) internal pure returns (uint256[] memory ws) {
        ws = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ws[i] = from + i;
        }
    }

    // ================================================================= bind
    function test_bindRejectsZeroToken() public {
        HamsterVault v = new HamsterVault(team, address(game));
        vm.prank(team);
        vm.expectRevert(HamsterVault.ZeroAddress.selector);
        v.bindToken(address(0));
    }

    function test_bindRejectsRemainderOneWeiShort() public {
        HamsterVault v = new HamsterVault(team, address(game));
        MockERC20 t = new MockERC20("H", "H");
        t.mint(address(v), 8e26 - 1);
        t.mint(address(1), 2e26 + 1);
        vm.prank(team);
        vm.expectRevert(HamsterVault.WrongRemainder.selector);
        v.bindToken(address(t));
        assertEq(address(v.token()), address(0));
    }

    function test_bindRejectsSupplyOffByOne() public {
        HamsterVault v = new HamsterVault(team, address(game));
        MockERC20 t = new MockERC20("H", "H");
        t.mint(address(v), 8e26);
        t.mint(address(1), 2e26 + 1);
        vm.prank(team);
        vm.expectRevert(HamsterVault.WrongSupply.selector);
        v.bindToken(address(t));
    }

    function test_bindRejectsNonContractToken() public {
        HamsterVault v = new HamsterVault(team, address(game));
        vm.prank(team);
        vm.expectRevert();
        v.bindToken(address(0xC0FFEE));
    }

    function test_failedBindCanBeRetried() public {
        HamsterVault v = new HamsterVault(team, address(game));
        MockERC20 t = new MockERC20("H", "H");
        t.mint(address(1), 2e26);
        vm.prank(team);
        vm.expectRevert(HamsterVault.WrongSupply.selector);
        v.bindToken(address(t));
        t.mint(address(v), 8e26);
        vm.prank(team);
        v.bindToken(address(t));
        assertEq(address(v.token()), address(t));
        assertEq(v.miningBucket(), 750_000_000e18);
        assertEq(v.boostBucket(), 50_000_000e18);
    }

    function test_teamCannotBindASecondTokenEvenIfValid() public {
        MockERC20 t2 = new MockERC20("H2", "H2");
        t2.mint(address(vault), 8e26);
        t2.mint(address(1), 2e26);
        vm.prank(team);
        vm.expectRevert(HamsterVault.AlreadyBound.selector);
        vault.bindToken(address(t2));
        assertEq(address(vault.token()), address(hamster));
    }

    function test_unboundVaultRefusesStakeAndVesting() public {
        HamsterVault v = new HamsterVault(team, address(game));
        vm.expectRevert(HamsterVault.NotBound.selector);
        v.stake(1e18);
        vm.expectRevert(HamsterVault.NotBound.selector);
        v.withdrawVested(1);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        v.withdrawUnstaked();
    }

    // ================================================================= mining claims
    function test_claimZeroAccountReverts() public {
        _finalize(alice, 1e18);
        vm.expectRevert(HamsterVault.ZeroAddress.selector);
        _claim(0, address(0));
    }

    function test_emptyBatchReverts() public {
        _finalize(alice, 1e18);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.claimMined(new uint256[](0), alice);
    }

    function test_duplicateWindowInBatchRevertsAtomically() public {
        _finalize(alice, 1e18);
        uint256[] memory ws = new uint256[](2);
        vm.expectRevert(HamsterVault.AlreadyClaimed.selector);
        vault.claimMined(ws, alice);
        assertFalse(vault.claimed(0, alice));
        assertEq(vault.miningCommitted(), 0);
        _claim(0, alice);
        assertEq(vault.miningCommitted(), 20_000e18);
    }

    function test_batchOfExactly48Accepted() public {
        for (uint256 i; i < 48; ++i) {
            _finalize(alice, 1e18);
        }
        vault.claimMined(_windows(0, 48), alice);
        assertEq(vault.grantCount(alice), 1);
        assertEq(vault.grantsOf(alice)[0].amount, 48 * 20_000e18);
    }

    function test_batchWithOneUnfinalizedWindowRevertsWhole() public {
        _finalize(alice, 1e18);
        uint256[] memory ws = new uint256[](2);
        ws[0] = 0;
        ws[1] = 1;
        vm.expectRevert(HamsterVault.NotFinalized.selector);
        vault.claimMined(ws, alice);
        assertFalse(vault.claimed(0, alice));
    }

    function test_zeroLossWindowInBatchIsMarkedButHarmless() public {
        _finalize(alice, 1e18); // 0
        _finalize(bob, 1e18); // 1: alice has no loss
        uint256[] memory ws = _windows(0, 2);
        vault.claimMined(ws, alice);
        assertTrue(vault.claimed(1, alice));
        // bob's share of window 1 is untouched
        (uint256 b,) = vault.claimableMined(1, bob);
        assertEq(b, 20_000e18);
        _claim(1, bob);
        assertEq(vault.grantsOf(bob)[0].amount, 20_000e18);
    }

    function test_emptyFinalizedWindowGivesNothing() public {
        game.finalizeEmpty();
        assertEq(vault.windowBudget(0), 0);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        _claim(0, alice);
    }

    function test_thirdPartyClaimCannotRedirectButStartsVestingClock() public {
        _finalize(alice, 1e18);
        vm.prank(bob);
        _claim(0, alice);
        assertEq(vault.grantCount(bob), 0);
        assertEq(hamster.balanceOf(bob), 0);
        HamsterVault.Grant[] memory g = vault.grantsOf(alice);
        assertEq(g[0].amount, 20_000e18);
        assertEq(g[0].start, block.timestamp);
    }

    /// @dev A window crossing two halvings at once: the budget equals the sum of its era segments.
    function test_windowCrossingTwoHalvings() public {
        uint256 h = 18_750e18;
        _finalize(bob, h - 10e18); // window 0: era 0, stops 10 IMD short of the first halving
        _finalize(alice, h + 20e18); // window 1: 10 IMD era 0, 18,750 IMD era 1, 10 IMD era 2
        uint256 expected = 10 * 20_000e18 + 375_000_000e18 / 2 + 10 * 5_000e18;
        assertEq(vault.windowBudget(1), expected);
        _claim(1, alice);
        assertEq(vault.grantsOf(alice)[0].amount, expected);
        assertEq(vault.miningInfo().era, 2);
        assertEq(vault.miningInfo().ratePerImd, 5_000);
        assertEq(vault.miningInfo().nextHalvingAtLoss, 3 * h);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_budgetTelescopes(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, 200_000e18);
        b = bound(b, 0, 200_000e18);
        c = bound(c, 0, 200_000e18);
        _finalize(alice, a);
        _finalize(alice, b);
        _finalize(alice, c);
        uint256 sum = vault.windowBudget(0) + vault.windowBudget(1) + vault.windowBudget(2);
        assertEq(sum, vault.emissionAt(a + b + c));
        assertLe(sum, 750_000_000e18);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_claimOrderIndependentAcrossThreeAccounts(
        uint256 la,
        uint256 lb,
        uint256 lc,
        uint256 pre,
        uint8 order
    ) public {
        la = bound(la, 1, 50_000e18);
        lb = bound(lb, 1, 50_000e18);
        lc = bound(lc, 1, 50_000e18);
        pre = bound(pre, 0, 40_000e18);
        if (pre > 0) _finalize(carol, pre);
        uint256 k = game.nextFinalizeWindow();
        address[] memory accs = new address[](3);
        uint256[] memory ls = new uint256[](3);
        (accs[0], accs[1], accs[2]) = (alice, bob, carol);
        (ls[0], ls[1], ls[2]) = (la, lb, lc);
        game.finalizeWindow(accs, ls, la + lb + lc);

        uint256 snap = vm.snapshotState();
        _claim(k, alice);
        _claim(k, bob);
        _claim(k, carol);
        uint256 a1 = vault.grantsOf(alice)[0].amount;
        uint256 b1 = vault.grantsOf(bob)[0].amount;
        uint256 c1 = vault.grantsOf(carol)[0].amount;
        vm.revertToState(snap);

        address[3] memory perm =
            order % 3 == 0 ? [carol, bob, alice] : (order % 3 == 1 ? [bob, carol, alice] : [carol, alice, bob]);
        for (uint256 i; i < 3; ++i) {
            _claim(k, perm[i]);
        }
        assertEq(vault.grantsOf(alice)[0].amount, a1);
        assertEq(vault.grantsOf(bob)[0].amount, b1);
        assertEq(vault.grantsOf(carol)[0].amount, c1);
        assertLe(a1 + b1 + c1, vault.windowBudget(k));
        // rounding loses at most one wei per account
        assertGe(a1 + b1 + c1 + 3, vault.windowBudget(k));
    }

    // ================================================================= vesting
    function test_withdrawVestedAtGrantStartReverts() public {
        _finalize(alice, 1e18);
        _claim(0, alice);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawVested(1);
    }

    function test_withdrawVestedZeroMaxReverts() public {
        _finalize(alice, 1e18);
        _claim(0, alice);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawVested(0);
    }

    function test_withdrawVestedTwiceInSameSecondReverts() public {
        _finalize(alice, 1e18);
        _claim(0, alice);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.withdrawVested(1);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawVested(1);
    }

    function test_vestingBoundaries() public {
        _finalize(alice, 7e18); // 140,000 HAMSTER
        _claim(0, alice);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 7 days - 1);
        uint256 almost = vault.withdrawableVested(alice);
        assertEq(almost, uint256(140_000e18) * (7 days - 1) / 7 days);
        vm.warp(t0 + 7 days);
        assertEq(vault.withdrawableVested(alice), 140_000e18);
        vm.warp(t0 + 700 days);
        vm.prank(alice);
        vault.withdrawVested(1);
        assertEq(hamster.balanceOf(alice), 140_000e18);
        assertEq(vault.stakeInfo(alice).grantBalance, 0);
        assertEq(vault.stakeInfo(alice).grantCursor, 1);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_vestingIsLinearAndMonotone(uint256 loss, uint256 t1, uint256 t2) public {
        loss = bound(loss, 1e15, 10_000e18);
        _finalize(alice, loss);
        _claim(0, alice);
        uint256 amount = vault.grantsOf(alice)[0].amount;
        uint256 t0 = block.timestamp;
        t1 = bound(t1, 0, 10 days);
        t2 = bound(t2, t1, 10 days);
        vm.warp(t0 + t1);
        uint256 v1 = vault.withdrawableVested(alice);
        uint256 expected1 = t1 >= 7 days ? amount : amount * t1 / 7 days;
        assertEq(v1, expected1);
        if (v1 > 0) {
            vm.prank(alice);
            vault.withdrawVested(1);
        }
        vm.warp(t0 + t2);
        uint256 v2 = vault.withdrawableVested(alice);
        uint256 expected2 = t2 >= 7 days ? amount : amount * t2 / 7 days;
        assertEq(v1 + v2, expected2);
        // weight is what has not left the vault
        assertEq(vault.stakeInfo(alice).weight, amount - v1);
    }

    function test_withdrawVestedCapsAt64GrantsPerCall() public {
        for (uint256 i; i < 70; ++i) {
            _finalize(alice, 1e18);
        }
        for (uint256 i; i < 70; ++i) {
            _claim(i, alice);
        }
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        vault.withdrawVested(1000);
        assertEq(hamster.balanceOf(alice), 64 * 20_000e18);
        assertEq(vault.stakeInfo(alice).grantCursor, 64);
        vm.prank(alice);
        vault.withdrawVested(1000);
        assertEq(hamster.balanceOf(alice), 70 * 20_000e18);
        assertEq(vault.totalGrantBalance(), 0);
    }

    // ================================================================= staking
    function test_stakeExactlyMinimumAndOneWeiBelow() public {
        _giveHamster(alice, 2e18);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.BelowMinimum.selector);
        vault.stake(1e18 - 1);
        vm.prank(alice);
        vault.stake(1e18);
        assertEq(vault.stakeInfo(alice).pending, 1e18);
    }

    function test_stakeWithoutAllowanceReverts() public {
        hamster.mint(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.stake(5e18);
        assertEq(vault.totalStaked(), 0);
    }

    function test_requestUnstakeZeroAndPendingRevert() public {
        _stake(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.InvalidAmount.selector);
        vault.requestUnstake(0);
        // still warming up: nothing active to unstake
        vm.prank(alice);
        vm.expectRevert(HamsterVault.InsufficientStake.selector);
        vault.requestUnstake(1);
    }

    function test_cancelPendingWithNothingPendingReverts() public {
        vm.prank(alice);
        vm.expectRevert(HamsterVault.InvalidAmount.selector);
        vault.cancelPendingStake();
        _stake(alice, 10e18);
        vm.warp(vault.activationTime(block.timestamp));
        // already activated: there is no pending left to cancel
        vm.prank(alice);
        vm.expectRevert(HamsterVault.InvalidAmount.selector);
        vault.cancelPendingStake();
        assertEq(vault.stakeInfo(alice).active, 10e18);
    }

    function test_warmupBoundaryExactSecond() public {
        _stake(alice, 10e18);
        uint64 at = vault.stakeInfo(alice).pendingActivateAt;
        assertGe(at, block.timestamp + 24 hours);
        assertLt(at, block.timestamp + 25 hours);
        assertEq((at - GENESIS) % 3600, 0);
        vm.warp(at - 1);
        vault.sync();
        assertEq(vault.totalWeight(), 0);
        vm.warp(at);
        vault.sync();
        assertEq(vault.totalWeight(), 10e18);
    }

    function test_unstakeReleaseBoundaryExactSecond() public {
        _stake(alice, 10e18);
        vm.warp(vault.activationTime(block.timestamp));
        vm.prank(alice);
        vault.requestUnstake(4e18);
        uint256 release = block.timestamp + 24 hours;
        assertEq(vault.totalWeight(), 6e18);
        vm.warp(release - 1);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawUnstaked();
        vm.warp(release);
        vm.prank(alice);
        vault.withdrawUnstaked();
        assertEq(hamster.balanceOf(alice), 4e18);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.withdrawUnstaked();
    }

    function test_cancelledPendingEarnsNothing() public {
        _stake(alice, 10e18);
        _depositRewards(700e18);
        vm.prank(alice);
        vault.cancelPendingStake();
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vault.withdrawUnstaked();
        assertEq(hamster.balanceOf(alice), 10e18);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.claimRewards();
        // the stream waited: still all there, nothing paid out
        assertEq(vault.totalRewardsAccrued(), 0);
        assertEq(imd.balanceOf(address(vault)), 700e18);
    }

    function test_unstakedTokensEarnNothingDuringDelay() public {
        _stake(alice, 10e18);
        _stake(bob, 10e18);
        vm.warp(vault.activationTime(block.timestamp));
        vault.sync();
        vm.prank(alice);
        vault.requestUnstake(10e18);
        _depositRewards(7e18);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.claimRewards();
        vm.prank(bob);
        vault.claimRewards();
        assertApproxEqAbs(imd.balanceOf(bob), 7e18, 1e6);
    }

    function test_claimRewardsTwiceSecondReverts() public {
        _stake(alice, 10e18);
        vm.warp(vault.activationTime(block.timestamp));
        _depositRewards(7e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.claimRewards();
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.claimRewards();
    }

    /// @dev Mining grants are weight from the claim on; a liquid staker with equal stake waits out
    /// its warm-up. Both are paid strictly pro-rata over the time each held weight.
    function test_grantWeightAndStakeShareProRata() public {
        _finalize(alice, 1e18); // 20,000 HAMSTER grant
        _claim(0, alice);
        _stake(bob, 20_000e18);
        uint64 at = vault.stakeInfo(bob).pendingActivateAt;
        _depositRewards(700e18);
        vm.warp(at);
        vault.sync();
        uint256 aliceBefore = vault.pendingRewards(alice);
        // alice alone held weight until bob activated
        assertApproxEqAbs(aliceBefore, vault.totalRewardsAccrued(), 1e6);
        vm.warp(block.timestamp + 1 days);
        uint256 aDelta = vault.pendingRewards(alice) - aliceBefore;
        uint256 bDelta = vault.pendingRewards(bob);
        assertApproxEqAbs(aDelta, bDelta, 1e6);
    }

    // ================================================================= reward sources
    function test_depositRewardsWithoutAllowanceReverts() public {
        imd.mint(address(this), 5e18);
        vm.expectRevert();
        vault.depositRewards(5e18);
        vm.expectRevert(HamsterVault.InvalidAmount.selector);
        vault.depositDrip(0);
    }

    function test_pullFromGameBeforeRecipientReverts() public {
        imd.mint(address(game), 100e18);
        game.creditStakers(100e18);
        vm.expectRevert();
        vault.pullFromGame();
        assertFalse(vault.backlogPulled());
    }

    function test_backlogThenLaterPullsJoinStream() public {
        imd.mint(address(game), 300e18);
        game.creditStakers(300e18); // before the vault is the recipient: backlog
        game.setStakingRecipient(address(vault));
        vault.pullFromGame();
        (uint256 rem, uint64 end) = vault.backlog();
        assertEq(rem, 300e18);
        assertEq(end, block.timestamp + 30 days);
        assertTrue(vault.backlogPulled());
        // nothing more: second pull reverts
        vm.expectRevert();
        vault.pullFromGame();
        imd.mint(address(game), 70e18);
        game.creditStakers(70e18);
        vault.pullFromGame();
        (rem, end) = vault.stream();
        assertEq(rem, 70e18);
        assertEq(end, block.timestamp + 7 days);
        (rem,) = vault.backlog();
        assertEq(rem, 300e18);
    }

    function test_backlogStreamsOverThirtyDaysOfWeight() public {
        imd.mint(address(game), 3000e18);
        game.creditStakers(3000e18);
        game.setStakingRecipient(address(vault));
        vault.pullFromGame();
        _stake(alice, 10e18);
        uint64 at = vault.stakeInfo(alice).pendingActivateAt;
        vm.warp(at + 10 days);
        vault.sync();
        // 10 of 30 days of weight: one third, not more, and nothing for the pre-weight wait
        assertApproxEqRel(vault.pendingRewards(alice), 1000e18, 1e12);
        vm.warp(at + 30 days);
        vault.sync();
        assertApproxEqAbs(vault.pendingRewards(alice), 3000e18, 1e6);
    }

    function test_dripPausesWithoutWeight() public {
        _depositDrip(1000e18);
        vm.warp(block.timestamp + 50 days);
        vault.sync();
        assertEq(vault.dripPot(), 1000e18);
        assertEq(vault.totalRewardsAccrued(), 0);
    }

    function test_dripOneDayIsOnePercent() public {
        _stake(alice, 10e18);
        vm.warp(vault.activationTime(block.timestamp));
        _depositDrip(1_000_000e18);
        vm.warp(block.timestamp + 1 days);
        vault.sync();
        assertApproxEqRel(vault.dripPot(), 990_000e18, 1e9);
        vm.warp(block.timestamp + 99 days);
        vault.sync();
        // 0.99^100
        assertApproxEqRel(vault.dripPot(), 366_032_341_273_229_000_000_000, 1e12);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_dripSplitSyncMatchesSingle(uint256 amount, uint32 d1, uint32 d2) public {
        amount = bound(amount, 1e18, 1e27);
        uint256 a = bound(d1, 1, 200 days);
        uint256 b = bound(d2, 1, 200 days);
        _stake(alice, 10e18);
        vm.warp(vault.activationTime(block.timestamp));
        _depositDrip(amount);
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();
        vm.warp(t0 + a + b);
        vault.sync();
        uint256 single = vault.dripPot();
        vm.revertToState(snap);
        vm.warp(t0 + a);
        vault.sync();
        vm.warp(t0 + a + b);
        vault.sync();
        // poking cannot move the drip by more than rounding
        assertApproxEqRel(vault.dripPot(), single, 1e6);
        assertApproxEqAbs(vault.dripPot(), single, 1e9 + single / 1e12);
    }

    /// @dev No first-staker windfall: whatever wait precedes the first weight, the first staker's
    /// reward right after activation is at most the stream rate times the elapsed earning time.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_noFirstStakerWindfall(uint256 amount, uint256 wait, uint256 after_) public {
        amount = bound(amount, 7e18, 1e26);
        wait = bound(wait, 0, 60 days);
        after_ = bound(after_, 0, 2 days);
        _depositRewards(amount);
        _depositDrip(amount);
        vm.warp(block.timestamp + wait);
        _stake(alice, 1e18);
        uint64 at = vault.stakeInfo(alice).pendingActivateAt;
        vm.warp(at + after_);
        vault.sync();
        uint256 got = vault.pendingRewards(alice);
        uint256 streamMax = amount * after_ / 7 days + 1;
        // continuous 0.99 per day pays ln(1/0.99) = 1.00503% per day at the start
        uint256 dripMax = amount * after_ * 10_051 / 86400 / 1_000_000 + 1;
        assertLe(got, streamMax + dripMax);
        if (after_ == 0) assertEq(got, 0);
    }

    // ================================================================= boost: activation and sweep
    function test_scheduleBoostChecks() public {
        vm.prank(team);
        vm.expectRevert(HamsterVault.ZeroAddress.selector);
        vault.scheduleBoost(address(0));
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NotTeam.selector);
        vault.activateBoost(address(squeek));
    }

    function test_activateOneSecondEarlyReverts() public {
        vm.prank(team);
        vault.scheduleBoost(address(squeek));
        uint256 ready = vault.boostReadyAt();
        vm.warp(ready - 1);
        vm.prank(team);
        vm.expectRevert(HamsterVault.TimelockNotReady.selector);
        vault.activateBoost(address(squeek));
        vm.warp(ready);
        vm.prank(team);
        vault.activateBoost(address(squeek));
        assertTrue(vault.boostActive());
        vm.prank(team);
        vm.expectRevert(HamsterVault.BoostAlreadyActive.selector);
        vault.activateBoost(address(squeek));
    }

    function test_rescheduleRestartsTimelock() public {
        vm.prank(team);
        vault.scheduleBoost(address(0xAAAA));
        vm.warp(block.timestamp + 11 hours);
        vm.prank(team);
        vault.scheduleBoost(address(squeek));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(team);
        vm.expectRevert(HamsterVault.TimelockNotReady.selector);
        vault.activateBoost(address(squeek));
        vm.prank(team);
        vm.expectRevert(HamsterVault.NothingScheduled.selector);
        vault.activateBoost(address(0xAAAA));
    }

    function test_sweepBoundaryAndOnce() public {
        uint256 deadline = uint256(vault.DEPLOYED_AT()) + 365 days;
        vm.warp(deadline - 1);
        vm.expectRevert(HamsterVault.TooEarly.selector);
        vault.sweepBoost();
        vm.warp(deadline);
        vm.prank(carol);
        vault.sweepBoost();
        assertEq(vault.miningBucket(), 800_000_000e18);
        assertEq(vault.boostBucket(), 0);
        vm.expectRevert(HamsterVault.BoostSweptAlready.selector);
        vault.sweepBoost();
        vm.prank(team);
        vm.expectRevert(HamsterVault.BoostSweptAlready.selector);
        vault.scheduleBoost(address(squeek));
        // the curve is unchanged after the sweep
        assertEq(vault.emissionAt(18_750e18), 375_000_000e18);
        assertEq(hamster.balanceOf(address(vault)), vault.trackedHamster());
    }

    function test_sweepCancelsPendingSchedule() public {
        vm.prank(team);
        vault.scheduleBoost(address(squeek));
        vm.warp(uint256(vault.DEPLOYED_AT()) + 365 days);
        vault.sweepBoost();
        vm.prank(team);
        vm.expectRevert(HamsterVault.BoostSweptAlready.selector);
        vault.activateBoost(address(squeek));
        assertFalse(vault.boostActive());
    }

    // ================================================================= boost: registration
    function test_registerBurnedTokenReverts() public {
        _activateBoost();
        vm.prank(alice);
        vm.expectRevert();
        vault.registerSqueek(77);
    }

    function test_maxTwentyRegistrationsAndUnregisterFreesSlot() public {
        _activateBoost();
        for (uint256 i = 1; i <= 20; ++i) {
            squeek.mint(alice, i);
            vm.prank(alice);
            vault.registerSqueek(i);
        }
        squeek.mint(alice, 21);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.TooManyRegistrations.selector);
        vault.registerSqueek(21);
        vm.prank(alice);
        vault.unregisterSqueek(5);
        vm.prank(alice);
        vault.registerSqueek(21);
        assertEq(vault.squeeksOf(alice).length, 20);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NotRegistered.selector);
        vault.unregisterSqueek(5);
    }

    function test_soldTokensFreeSlotsForNewOnes() public {
        _activateBoost();
        for (uint256 i = 1; i <= 20; ++i) {
            squeek.mint(alice, i);
            vm.prank(alice);
            vault.registerSqueek(i);
        }
        squeek.transfer(3, bob);
        vm.prank(bob);
        vault.registerSqueek(3);
        squeek.mint(alice, 21);
        vm.prank(alice);
        vault.registerSqueek(21); // the entry bob took over is pruned
        assertEq(vault.squeeksOf(alice).length, 20);
        assertEq(vault.registrant(3), bob);
    }

    function test_voidSqueekOnBurnedToken() public {
        _activateBoost();
        squeek.mint(alice, 9);
        vm.prank(alice);
        vault.registerSqueek(9);
        vm.expectRevert(HamsterVault.AlreadyRegistered.selector);
        vault.voidSqueek(9);
        squeek.burn(9);
        vm.prank(carol);
        vault.voidSqueek(9);
        assertEq(vault.registrant(9), address(0));
        vm.expectRevert(HamsterVault.NotRegistered.selector);
        vault.voidSqueek(9);
    }

    function test_registrationLeadExactBoundary() public {
        _activateBoost();
        uint256 k = 400;
        uint256 start = GENESIS + k * 3600;
        // exactly 24h before the window start: eligible
        vm.warp(start - 24 hours);
        squeek.mint(alice, 1);
        vm.prank(alice);
        vault.registerSqueek(1);
        // one second later: not eligible
        vm.warp(start - 24 hours + 1);
        squeek.mint(bob, 2);
        vm.prank(bob);
        vault.registerSqueek(2);
        _skipTo(k);
        vm.warp(start + 2 hours);
        _finalize2(alice, 1e18, bob, 1e18);
        assertTrue(vault.squeekEligible(1, alice, k));
        assertFalse(vault.squeekEligible(2, bob, k));
        (, uint256 xa) = vault.claimableMined(k, alice);
        (, uint256 xb) = vault.claimableMined(k, bob);
        // budget 40,000 split evenly: base 20,000, boost +50%
        assertEq(xa, 10_000e18);
        assertEq(xb, 0);
    }

    function test_windowsBeforeActivationNeverBoosted() public {
        _finalize(alice, 1e18); // window 0, long before activation
        _activateBoost();
        squeek.mint(alice, 1);
        vm.prank(alice);
        vault.registerSqueek(1);
        vm.warp(block.timestamp + 2 days);
        (, uint256 x) = vault.claimableMined(0, alice);
        assertEq(x, 0);
        _claim(0, alice);
        assertEq(vault.boostCommitted(), 0);
    }

    function test_nftDailyCapResetsOnNextUtcDayByWindowStart() public {
        _activateBoost();
        // windows start at hh:20 UTC; pick two consecutive windows on different UTC days
        uint256 k = 432;
        uint256 start = GENESIS + k * 3600;
        while ((start + 3600) / 1 days == start / 1 days) {
            ++k;
            start += 3600;
        }
        // window k starts 23:20, k + 1 starts 00:20 of the next UTC day
        vm.warp(start - 2 days);
        squeek.mint(alice, 1);
        vm.prank(alice);
        vault.registerSqueek(1);
        _skipTo(k);
        vm.warp(start + 3 hours);
        _finalize(alice, 2e18); // 40,000 base -> 20,000 wanted, capped 10,000
        _finalize(alice, 2e18);
        vault.claimMined(_windows(k, 2), alice);
        assertEq(vault.boostCommitted(), 20_000e18);
        assertEq(vault.nftDayUsed(1, start / 1 days), 10_000e18);
        assertEq(vault.nftDayUsed(1, (start + 3600) / 1 days), 10_000e18);
    }

    function test_unregisterAfterOwnershipChangeKeepsNewRegistrant() public {
        _activateBoost();
        squeek.mint(alice, 1);
        vm.prank(alice);
        vault.registerSqueek(1);
        squeek.transfer(1, bob);
        vm.prank(bob);
        vault.registerSqueek(1);
        vm.prank(alice);
        vault.unregisterSqueek(1);
        assertEq(vault.registrant(1), bob);
    }

    // ================================================================= views
    function test_viewsReportStreamAndDripState() public {
        _depositRewards(70e18);
        _depositDrip(500e18);
        HamsterVault.RewardsView memory r = vault.rewardsInfo();
        assertEq(r.streamRemaining, 70e18);
        assertEq(r.streamEnd, block.timestamp + 7 days);
        assertEq(r.dripPot, 500e18);
        assertEq(r.dripPerDay, 5e18);
        assertEq(r.totalWeight, 0);
        _stake(alice, 3e18);
        r = vault.rewardsInfo();
        assertEq(r.pendingActivations, 1);
        HamsterVault.MiningView memory m = vault.miningInfo();
        assertEq(m.ratePerImd, 20_000);
        assertEq(m.miningLeft, 750_000_000e18);
        assertEq(m.boostLeft, 50_000_000e18);
        assertEq(vault.trackedImd(), imd.balanceOf(address(vault)));
    }
}
