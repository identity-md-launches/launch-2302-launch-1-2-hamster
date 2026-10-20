// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTest} from "./helpers/VaultTest.sol";
import {HamsterVault} from "../src/HamsterVault.sol";
import {MockERC20, MockERC721} from "./helpers/Mocks.sol";

contract BoostTest is VaultTest {
    /// @dev Finalizes empty windows until window `k` is the next one, so window starts line up with time.
    function _skipTo(uint256 k) internal {
        while (game.nextFinalizeWindow() < k) {
            game.finalizeEmpty();
        }
    }

    function _registerAt(address who, uint256 id, uint256 when) internal {
        vm.warp(when);
        squeek.mint(who, id);
        vm.prank(who);
        vault.registerSqueek(id);
    }

    // ----------------------------------------------------------------- activation
    function test_activateRequiresScheduleAndTimelock() public {
        vm.prank(team);
        vm.expectRevert(HamsterVault.NothingScheduled.selector);
        vault.activateBoost(address(squeek));
        vm.prank(team);
        vault.scheduleBoost(address(squeek));
        vm.prank(team);
        vm.expectRevert(HamsterVault.TimelockNotReady.selector);
        vault.activateBoost(address(squeek));
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        vm.expectRevert(HamsterVault.NothingScheduled.selector);
        vault.activateBoost(address(0x1234));
        vm.prank(team);
        vault.activateBoost(address(squeek));
        assertTrue(vault.boostActive());
        vm.prank(team);
        vm.expectRevert(HamsterVault.BoostAlreadyActive.selector);
        vault.scheduleBoost(address(squeek));
    }

    function test_activateNotTeamReverts() public {
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NotTeam.selector);
        vault.scheduleBoost(address(squeek));
    }

    function test_activateRejectsNonErc721() public {
        squeek.setSupports(false);
        vm.prank(team);
        vault.scheduleBoost(address(squeek));
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        vm.expectRevert(HamsterVault.BadCollection.selector);
        vault.activateBoost(address(squeek));
        // and an address with no code
        vm.prank(team);
        vault.scheduleBoost(address(0xCAFE));
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        vm.expectRevert(HamsterVault.BadCollection.selector);
        vault.activateBoost(address(0xCAFE));
    }

    function test_registerRequiresActiveAndOwnership() public {
        squeek.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.BoostNotActive.selector);
        vault.registerSqueek(1);
        _activateBoost();
        vm.prank(bob);
        vm.expectRevert(HamsterVault.NotOwnerOfToken.selector);
        vault.registerSqueek(1);
        vm.prank(alice);
        vault.registerSqueek(1);
        vm.prank(alice);
        vm.expectRevert(HamsterVault.AlreadyRegistered.selector);
        vault.registerSqueek(1);
        assertEq(vault.squeeksOf(alice).length, 1);
        vm.prank(alice);
        vault.unregisterSqueek(1);
        assertEq(vault.squeeksOf(alice).length, 0);
        assertEq(vault.registrant(1), address(0));
    }

    // ----------------------------------------------------------------- earning
    function test_boostEarnsOnlyAfterLead() public {
        _activateBoost();
        // Window 300 starts at GENESIS + 300h. Register 23h before: not eligible; window 301 is.
        uint256 start300 = GENESIS + 300 * 3600;
        _registerAt(alice, 1, start300 - 23 hours);
        _skipTo(300);
        vm.warp(start300 + 2 hours);
        _finalize(alice, 1e18); // window 300
        _finalize(alice, 1e18); // window 301
        (uint256 b0, uint256 x0) = vault.claimableMined(300, alice);
        (uint256 b1, uint256 x1) = vault.claimableMined(301, alice);
        assertEq(b0, 20_000e18);
        assertEq(x0, 0);
        assertEq(b1, 20_000e18);
        assertEq(x1, 10_000e18);
        _claim(301, alice);
        assertEq(vault.grantsOf(alice)[0].amount, 30_000e18);
        assertEq(vault.boostCommitted(), 10_000e18);
        assertEq(vault.miningCommitted(), 20_000e18);
    }

    function test_transferVoidsRegistration() public {
        _activateBoost();
        uint256 start300 = GENESIS + 300 * 3600;
        _registerAt(alice, 1, start300 - 2 days);
        _skipTo(300);
        vm.warp(start300 + 2 hours);
        _finalize(alice, 1e18);
        (, uint256 x) = vault.claimableMined(300, alice);
        assertEq(x, 10_000e18);
        squeek.transfer(1, bob);
        (, x) = vault.claimableMined(300, alice);
        assertEq(x, 0);
        assertFalse(vault.squeekEligible(1, alice, 300));
        _claim(300, alice);
        assertEq(vault.grantsOf(alice)[0].amount, 20_000e18);
        // burned token is void too, not a revert
        squeek.burn(1);
        assertFalse(vault.squeekEligible(1, alice, 300));
    }

    function test_newOwnerCanRegisterAfterTransfer() public {
        _activateBoost();
        _registerAt(alice, 1, block.timestamp);
        squeek.transfer(1, bob);
        vm.prank(bob);
        vault.registerSqueek(1);
        assertEq(vault.registrant(1), bob);
        assertFalse(vault.squeekEligible(1, alice, 10_000));
    }

    function test_perNftDailyCap() public {
        _activateBoost();
        uint256 start300 = GENESIS + 300 * 3600;
        _registerAt(alice, 1, start300 - 2 days);
        _skipTo(300);
        vm.warp(start300 + 2 days);
        // Three windows on the same UTC day each want 8,000 of boost (base 16,000). Cap 10,000 per NFT per day.
        uint256 day = start300 / 1 days;
        uint256 k = 300;
        uint256 n;
        while ((GENESIS + k * 3600) / 1 days == day && n < 3) {
            _finalize(alice, 0.8e18);
            ++k;
            ++n;
        }
        assertEq(n, 3);
        _claim(300, alice);
        _claim(301, alice);
        _claim(302, alice);
        assertEq(vault.nftDayUsed(1, day), 10_000e18);
        HamsterVault.Grant[] memory gs = vault.grantsOf(alice);
        assertEq(gs[0].amount, 16_000e18 + 8_000e18);
        assertEq(gs[1].amount, 16_000e18 + 2_000e18);
        assertEq(gs[2].amount, 16_000e18);
        assertEq(vault.boostCommitted(), 10_000e18);
    }

    function test_twoNftsDoubleTheCap() public {
        _activateBoost();
        uint256 start300 = GENESIS + 300 * 3600;
        _registerAt(alice, 1, start300 - 2 days);
        _registerAt(alice, 2, start300 - 2 days);
        _skipTo(300);
        vm.warp(start300 + 2 days);
        _finalize(alice, 1.5e18); // base 30,000, wants 15,000
        _claim(300, alice);
        assertEq(vault.boostCommitted(), 15_000e18);
        uint256 day = start300 / 1 days;
        assertEq(vault.nftDayUsed(1, day), 10_000e18);
        assertEq(vault.nftDayUsed(2, day), 5_000e18);
    }

    function test_globalDailyCap() public {
        _activateBoost();
        uint256 start300 = GENESIS + 300 * 3600;
        // Eleven holders, one NFT each, each wanting 10,000 on the same day: only 100,000 fits.
        address[] memory accs = new address[](11);
        uint256[] memory l = new uint256[](11);
        for (uint256 i; i < 11; ++i) {
            accs[i] = address(uint160(0x1000 + i));
            l[i] = 1e18;
            _registerAt(accs[i], i + 1, start300 - 2 days);
        }
        _skipTo(300);
        vm.warp(start300 + 2 days);
        game.finalizeWindow(accs, l, 11e18);
        for (uint256 i; i < 11; ++i) {
            _claim(300, accs[i]);
        }
        uint256 day = start300 / 1 days;
        assertEq(vault.globalDayUsed(day), 100_000e18);
        assertEq(vault.grantsOf(accs[9])[0].amount, 30_000e18);
        assertEq(vault.grantsOf(accs[10])[0].amount, 20_000e18);
        assertEq(vault.boostCommitted(), 100_000e18);
    }

    function test_boostBucketConservation() public {
        _activateBoost();
        uint256 start300 = GENESIS + 300 * 3600;
        _registerAt(alice, 1, start300 - 2 days);
        _skipTo(300);
        vm.warp(start300 + 2 days);
        _finalize(alice, 1e18);
        _claim(300, alice);
        assertLe(vault.boostCommitted(), vault.boostBucket());
        assertEq(vault.trackedHamster(), hamster.balanceOf(address(vault)));
    }

    // ----------------------------------------------------------------- sweep
    function test_sweepTooEarly() public {
        vm.warp(uint256(vault.DEPLOYED_AT()) + 365 days - 1);
        vm.expectRevert(HamsterVault.TooEarly.selector);
        vault.sweepBoost();
    }

    function test_sweepMovesBucketOnce() public {
        vm.warp(uint256(vault.DEPLOYED_AT()) + 365 days);
        vm.prank(alice);
        vault.sweepBoost();
        assertEq(vault.boostBucket(), 0);
        assertEq(vault.miningBucket(), 800_000_000e18);
        assertTrue(vault.boostSwept());
        vm.expectRevert(HamsterVault.BoostSweptAlready.selector);
        vault.sweepBoost();
        vm.prank(team);
        vm.expectRevert(HamsterVault.BoostSweptAlready.selector);
        vault.scheduleBoost(address(squeek));
        // The curve is unchanged: the mining emission still converges to 750M.
        assertEq(vault.emissionAt(1e30), 750_000_000e18);
        assertEq(vault.trackedHamster(), hamster.balanceOf(address(vault)));
    }

    function test_sweepBlockedOnceActive() public {
        _activateBoost();
        vm.warp(uint256(vault.DEPLOYED_AT()) + 400 days);
        vm.expectRevert(HamsterVault.BoostAlreadyActive.selector);
        vault.sweepBoost();
    }

    function test_sweepBeforeBindThenBind() public {
        HamsterVault v = new HamsterVault(team, address(game));
        vm.warp(block.timestamp + 365 days);
        v.sweepBoost();
        MockERC20 t = new MockERC20("H", "H");
        t.mint(address(v), 8e26);
        t.mint(address(0xBEEF), 2e26);
        vm.prank(team);
        v.bindToken(address(t));
        assertEq(v.miningBucket(), 800_000_000e18);
        assertEq(v.boostBucket(), 0);
    }
}
