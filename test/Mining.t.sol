// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTest} from "./helpers/VaultTest.sol";
import {HamsterVault} from "../src/HamsterVault.sol";
import {MockERC20} from "./helpers/Mocks.sol";

contract MiningTest is VaultTest {
    uint256 constant H = 18_750e18;

    // ----------------------------------------------------------------- bind
    function test_bindSetsBuckets() public view {
        assertEq(address(vault.token()), address(hamster));
        assertEq(vault.miningBucket(), 750_000_000e18);
        assertEq(vault.boostBucket(), 50_000_000e18);
        assertEq(vault.trackedHamster(), 8e26);
    }

    function test_bindTwiceReverts() public {
        vm.prank(team);
        vm.expectRevert(HamsterVault.AlreadyBound.selector);
        vault.bindToken(address(hamster));
    }

    function test_bindNotTeamReverts() public {
        HamsterVault v = new HamsterVault(team, address(game));
        vm.prank(alice);
        vm.expectRevert(HamsterVault.NotTeam.selector);
        v.bindToken(address(hamster));
    }

    function test_bindWrongSupplyReverts() public {
        HamsterVault v = new HamsterVault(team, address(game));
        MockERC20 t = new MockERC20("x", "x");
        t.mint(address(v), 8e26);
        vm.prank(team);
        vm.expectRevert(HamsterVault.WrongSupply.selector);
        v.bindToken(address(t));
    }

    function test_bindWrongRemainderReverts() public {
        HamsterVault v = new HamsterVault(team, address(game));
        MockERC20 t = new MockERC20("x", "x");
        t.mint(address(v), 8e26 - 1);
        t.mint(address(0xBEEF), 2e26 + 1);
        vm.prank(team);
        vm.expectRevert(HamsterVault.WrongRemainder.selector);
        v.bindToken(address(t));
    }

    function test_bindAcceptsDonatedSurplus() public {
        HamsterVault v = new HamsterVault(team, address(game));
        MockERC20 t = new MockERC20("x", "x");
        t.mint(address(v), 8e26);
        t.mint(address(0xBEEF), 2e26);
        vm.prank(address(0xBEEF));
        t.transfer(address(v), 1); // a griefer front-runs the bind with 1 wei
        vm.prank(team);
        v.bindToken(address(t));
        assertEq(v.miningBucket(), 750_000_000e18);
        assertEq(v.boostBucket(), 50_000_000e18);
        assertEq(v.trackedHamster(), 8e26); // surplus is untracked
    }

    function test_claimBeforeBindReverts() public {
        HamsterVault v = new HamsterVault(team, address(game));
        _finalize(alice, 1e18);
        uint256[] memory ws = new uint256[](1);
        vm.expectRevert(HamsterVault.NotBound.selector);
        v.claimMined(ws, alice);
    }

    // ----------------------------------------------------------------- curve
    function test_curveEra0Rate() public view {
        assertEq(vault.emissionAt(1e18), 20_000e18);
        assertEq(vault.emissionAt(H), 375_000_000e18);
    }

    function test_curveHalves() public view {
        // One IMD into era 1 earns 10,000.
        assertEq(vault.emissionAt(H + 1e18), 375_000_000e18 + 10_000e18);
        assertEq(vault.emissionAt(2 * H), 375_000_000e18 + 187_500_000e18);
        assertEq(vault.emissionAt(3 * H), 750_000_000e18 - 93_750_000e18);
    }

    function test_curveConvergesToBucket() public view {
        assertEq(vault.emissionAt(1000 * H), 750_000_000e18);
        assertEq(vault.emissionAt(type(uint256).max / 20_000), 750_000_000e18);
    }

    function testFuzz_curveMonotoneAndBounded(uint256 a, uint256 b) public view {
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);
        if (a > b) (a, b) = (b, a);
        uint256 fa = vault.emissionAt(a);
        uint256 fb = vault.emissionAt(b);
        assertLe(fa, fb);
        assertLe(fb, 750_000_000e18);
    }

    function test_rateView() public {
        HamsterVault.MiningView memory v = vault.miningInfo();
        assertEq(v.ratePerImd, 20_000);
        assertEq(v.nextHalvingAtLoss, H);
        _finalize(alice, H + 5e18);
        v = vault.miningInfo();
        assertEq(v.era, 1);
        assertEq(v.ratePerImd, 10_000);
        assertEq(v.nextHalvingAtLoss, 2 * H);
        assertEq(v.emitted, 375_000_000e18 + 50_000e18);
    }

    // ----------------------------------------------------------------- claims
    function test_retroactiveClaimFromWindowZero() public {
        // Windows finalized long before the token existed are claimable after bind.
        HamsterVault v = new HamsterVault(team, address(game));
        _finalize(alice, 2e18); // window 0
        _finalize2(alice, 1e18, bob, 3e18); // window 1
        vm.warp(block.timestamp + 60 days);
        MockERC20 t = new MockERC20("H", "H");
        t.mint(address(v), 8e26);
        t.mint(address(0xBEEF), 2e26);
        vm.prank(team);
        v.bindToken(address(t));
        uint256[] memory ws = new uint256[](2);
        ws[0] = 0;
        ws[1] = 1;
        vm.prank(carol); // permissionless
        v.claimMined(ws, alice);
        HamsterVault.Grant[] memory gs = v.grantsOf(alice);
        assertEq(gs.length, 1);
        assertEq(gs[0].amount, 40_000e18 + 20_000e18);
        assertEq(v.stakeInfo(alice).grantBalance, 60_000e18);
        assertEq(v.windowClaimed(0), 40_000e18);
    }

    function test_claimTwiceReverts() public {
        _finalize(alice, 1e18);
        _claim(0, alice);
        uint256[] memory ws = new uint256[](1);
        vm.expectRevert(HamsterVault.AlreadyClaimed.selector);
        vault.claimMined(ws, alice);
    }

    function test_claimUnfinalizedReverts() public {
        _finalize(alice, 1e18);
        uint256[] memory ws = new uint256[](1);
        ws[0] = 1;
        vm.expectRevert(HamsterVault.NotFinalized.selector);
        vault.claimMined(ws, alice);
    }

    function test_claimNothingReverts() public {
        _finalize(alice, 1e18);
        uint256[] memory ws = new uint256[](1);
        vm.expectRevert(HamsterVault.NothingToClaim.selector);
        vault.claimMined(ws, bob);
    }

    function test_claimBatchTooLargeReverts() public {
        uint256[] memory ws = new uint256[](49);
        vm.expectRevert(HamsterVault.BatchTooLarge.selector);
        vault.claimMined(ws, alice);
    }

    function test_claimAlwaysPaysAccountNotCaller() public {
        _finalize(alice, 1e18);
        vm.prank(bob);
        _claim(0, alice);
        assertEq(vault.grantsOf(bob).length, 0);
        assertEq(vault.grantsOf(alice).length, 1);
    }

    function test_halvingCrossingWithinWindow() public {
        // Window 0 takes cumulative loss from 18,000 to 19,500 IMD: 750 IMD at 20k and 750 at 10k.
        _finalize(alice, 18_000e18);
        _finalize2(alice, 1_000e18, bob, 500e18);
        assertEq(vault.windowBudget(1), 750 * 20_000e18 + 750 * 10_000e18);
        (uint256 a,) = vault.claimableMined(1, alice);
        (uint256 b,) = vault.claimableMined(1, bob);
        assertEq(a, 22_500_000e18 * 2 / 3);
        assertEq(b, 22_500_000e18 / 3);
    }

    function test_claimOrderIndependence() public {
        _finalize2(alice, 7e18, bob, 3e18);
        _finalize2(alice, 1e18, bob, 9e18);
        uint256 snap = vm.snapshotState();
        _claim(0, alice);
        _claim(1, alice);
        _claim(0, bob);
        _claim(1, bob);
        uint256 aliceA = vault.stakeInfo(alice).grantBalance;
        uint256 bobA = vault.stakeInfo(bob).grantBalance;
        vm.revertToState(snap);
        _claim(1, bob);
        _claim(0, bob);
        _claim(1, alice);
        _claim(0, alice);
        assertEq(vault.stakeInfo(alice).grantBalance, aliceA);
        assertEq(vault.stakeInfo(bob).grantBalance, bobA);
        assertEq(aliceA, 140_000e18 + 20_000e18);
        assertEq(bobA, 60_000e18 + 180_000e18);
    }

    function test_hedgedTotalDoesNotOverDistribute() public {
        // total eligible loss above the sum of lossOf: shares are diluted, never inflated.
        address[] memory accs = new address[](2);
        uint256[] memory l = new uint256[](2);
        accs[0] = alice;
        accs[1] = bob;
        l[0] = 1e18;
        l[1] = 1e18;
        game.finalizeWindow(accs, l, 4e18);
        _claim(0, alice);
        _claim(0, bob);
        assertEq(vault.windowClaimed(0), 40_000e18);
        assertEq(vault.windowBudget(0), 80_000e18);
    }

    function test_dustTracked() public {
        // Within one era a window budget is an exact multiple of its total loss: no dust.
        address[] memory accs = new address[](3);
        uint256[] memory l = new uint256[](3);
        accs[0] = alice;
        accs[1] = bob;
        accs[2] = carol;
        l[0] = 1;
        l[1] = 1;
        l[2] = 1;
        game.finalizeWindow(accs, l, 3); // budget 60,000 wei; 20,000 each
        _claim(0, alice);
        _claim(0, bob);
        _claim(0, carol);
        assertEq(vault.miningDust(), 0);
        // A window crossing the halving has budget 20,000 * 1 + 10,000 * 2 = 40,000 over a total of 3.
        _finalize(carol, H - 4);
        accs = new address[](2);
        l = new uint256[](2);
        accs[0] = alice;
        accs[1] = bob;
        l[0] = 1;
        l[1] = 2;
        game.finalizeWindow(accs, l, 3); // 13,333 + 26,666 = 39,999 -> 1 wei of dust
        assertEq(vault.windowBudget(2), 40_000);
        _claim(2, alice);
        assertEq(vault.miningDust(), 0);
        _claim(2, bob);
        assertEq(vault.miningDust(), 1);
        assertEq(vault.windowClaimed(2), 39_999);
        assertEq(vault.miningCommitted() + vault.miningDust(), 60_000 + 40_000);
    }

    function testFuzz_conservationOfMiningBucket(uint256[8] memory losses, uint8 claimMask) public {
        address[3] memory accs = [alice, bob, carol];
        uint256 totalBudget;
        for (uint256 k; k < 8; ++k) {
            uint256 loss = bound(losses[k], 0, 40_000e18);
            address[] memory a = new address[](3);
            uint256[] memory l = new uint256[](3);
            for (uint256 i; i < 3; ++i) {
                a[i] = accs[i];
                l[i] = loss * (i + 1) / 7;
            }
            game.finalizeWindow(a, l, loss);
            totalBudget += vault.windowBudget(k);
        }
        assertEq(totalBudget, vault.emissionAt(game.cumulativeLoss()));
        uint256 committed;
        for (uint256 k; k < 8; ++k) {
            for (uint256 i; i < 3; ++i) {
                if ((claimMask >> ((k + i) % 8)) & 1 == 0) continue;
                (uint256 b,) = vault.claimableMined(k, accs[i]);
                if (b == 0) continue;
                _claim(k, accs[i]);
                committed += b;
            }
        }
        assertEq(vault.miningCommitted(), committed);
        assertLe(vault.miningCommitted(), vault.miningBucket());
        assertLe(vault.miningCommitted() + vault.miningDust(), totalBudget);
        assertEq(vault.trackedHamster(), hamster.balanceOf(address(vault)));
    }

    function test_fullCurveNeverExceedsBucket() public {
        // Many eras of loss: everything claimed by one account.
        for (uint256 k; k < 20; ++k) {
            _finalize(alice, 10_000e18);
        }
        uint256[] memory ws = new uint256[](20);
        for (uint256 k; k < 20; ++k) {
            ws[k] = k;
        }
        vault.claimMined(ws, alice);
        assertEq(vault.miningCommitted(), vault.emissionAt(200_000e18));
        assertLe(vault.miningCommitted(), 750_000_000e18);
    }

    // ----------------------------------------------------------------- views
    function test_claimableViewMatchesClaim() public {
        _finalize2(alice, 3e18, bob, 2e18);
        (uint256 base, uint256 boost) = vault.claimableMined(0, alice);
        assertEq(boost, 0);
        _claim(0, alice);
        assertEq(vault.grantsOf(alice)[0].amount, base);
        (base,) = vault.claimableMined(0, alice);
        assertEq(base, 0);
    }
}
