// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterVault} from "../../src/HamsterVault.sol";
import {MockERC20, MockGame, MockERC721} from "../helpers/Mocks.sol";
import {VaultTest} from "../helpers/VaultTest.sol";

/// @notice Drives mining claims with the Squeek boost active: registrations, NFT transfers and burns,
/// finalized windows lined up with time, batch claims by third parties, vesting withdrawals and stakes.
contract BoostHandler is Test {
    uint64 internal constant GENESIS = 1791847200;
    uint256 public constant IDS = 24;

    HamsterVault internal vault;
    MockERC20 internal hamster;
    MockGame internal game;
    MockERC721 internal squeek;
    address[] public actors;

    uint256[] public touchedDays;
    mapping(uint256 => bool) internal _dayTouched;
    uint256 public ghostBase;
    uint256 public ghostBoost;
    uint256 public boostOverHalf; // claims where boost exceeded 50% of base
    uint256 public hamsterOut; // HAMSTER withdrawn by actors (vesting and unstake)
    uint256 public hamsterStakedIn;

    constructor(HamsterVault v, MockERC20 h, MockGame g, MockERC721 s) {
        vault = v;
        hamster = h;
        game = g;
        squeek = s;
        for (uint256 j; j < 4; ++j) {
            address a = makeAddr(string(abi.encodePacked("boostActor", j)));
            actors.push(a);
            vm.prank(a);
            hamster.approve(address(vault), type(uint256).max);
        }
        for (uint256 id = 1; id <= IDS; ++id) {
            squeek.mint(actors[id % 4], id);
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
    }

    function register(uint256 id) external {
        id = bound(id, 1, IDS);
        address o;
        try squeek.ownerOf(id) returns (address x) {
            o = x;
        } catch {
            return;
        }
        if (vault.registrant(id) == o) return;
        if (vault.squeeksOf(o).length >= 20) return;
        vm.prank(o);
        vault.registerSqueek(id);
    }

    function transferNft(uint256 id, uint256 to) external {
        id = bound(id, 1, IDS);
        try squeek.ownerOf(id) returns (address) {
            squeek.transfer(id, _actor(to));
        } catch {}
    }

    function burnOrRemint(uint256 id, uint256 to) external {
        id = bound(id, 1, IDS);
        try squeek.ownerOf(id) returns (address) {
            squeek.burn(id);
        } catch {
            squeek.mint(_actor(to), id);
        }
    }

    function voidSqueek(uint256 id) external {
        id = bound(id, 1, IDS);
        try vault.voidSqueek(id) {} catch {}
    }

    /// @dev Finalizes the next window once it has ended, with up to two losing actors. Windows that
    /// fell more than two hours behind the clock are finalized empty first, so window starts track time.
    function finalize(uint256 s1, uint256 l1, uint256 s2, uint256 l2) external {
        while (GENESIS + (game.nextFinalizeWindow() + 3) * 3600 <= block.timestamp) {
            game.finalizeEmpty();
        }
        uint256 k = game.nextFinalizeWindow();
        uint256 end = GENESIS + (k + 1) * 3600;
        if (block.timestamp < end) vm.warp(end);
        address[] memory accs = new address[](2);
        uint256[] memory ls = new uint256[](2);
        accs[0] = _actor(s1);
        accs[1] = _actor(s2);
        ls[0] = bound(l1, 0, 20e18);
        ls[1] = bound(l2, 0, 20e18);
        game.finalizeWindow(accs, ls, ls[0] + ls[1]);
    }

    function claim(uint256 s, uint256 from, uint256 n) external {
        uint256 next = game.nextFinalizeWindow();
        if (next == 0) return;
        uint256 first = game.nextFinalizeWindow() > 30 ? next - 30 : 0;
        from = bound(from, first, next - 1);
        n = bound(n, 1, next - from);
        if (n > 6) n = 6;
        uint256[] memory ws = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ws[i] = from + i;
        }
        uint256 m0 = vault.miningCommitted();
        uint256 b0 = vault.boostCommitted();
        try vault.claimMined(ws, _actor(s)) {
            uint256 dm = vault.miningCommitted() - m0;
            uint256 db = vault.boostCommitted() - b0;
            ghostBase += dm;
            ghostBoost += db;
            if (db > dm / 2) ++boostOverHalf;
            for (uint256 i; i < n; ++i) {
                uint256 d = (GENESIS + ws[i] * 3600) / 1 days;
                if (!_dayTouched[d]) {
                    _dayTouched[d] = true;
                    touchedDays.push(d);
                }
            }
        } catch {}
    }

    function withdrawVested(uint256 s) external {
        address a = _actor(s);
        uint256 before = hamster.balanceOf(a);
        vm.prank(a);
        try vault.withdrawVested(64) {
            hamsterOut += hamster.balanceOf(a) - before;
        } catch {}
    }

    function stakeFromBalance(uint256 s, uint256 amt) external {
        address a = _actor(s);
        uint256 bal = hamster.balanceOf(a);
        if (bal < 1e18) return;
        amt = bound(amt, 1e18, bal);
        vm.prank(a);
        vault.stake(amt);
        hamsterStakedIn += amt;
    }

    function unstakeAll(uint256 s) external {
        address a = _actor(s);
        uint256 active = vault.stakeInfo(a).active;
        if (active > 0) {
            vm.prank(a);
            vault.requestUnstake(active);
        }
        uint256 before = hamster.balanceOf(a);
        vm.prank(a);
        try vault.withdrawUnstaked() {
            hamsterOut += hamster.balanceOf(a) - before;
        } catch {}
    }

    function touchedDayCount() external view returns (uint256) {
        return touchedDays.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract BoostInvariantTest is VaultTest {
    BoostHandler internal handler;

    function setUp() public override {
        super.setUp();
        // line the mock game's window index up with the clock, then activate the boost
        while (GENESIS + (game.nextFinalizeWindow() + 1) * 3600 <= block.timestamp) {
            game.finalizeEmpty();
        }
        _activateBoost();
        handler = new BoostHandler(vault, hamster, game, squeek);
        // every NFT starts registered by its holder with the 24-hour lead already served
        for (uint256 id = 1; id <= handler.IDS(); ++id) {
            vm.prank(squeek.ownerOf(id));
            vault.registerSqueek(id);
        }
        vm.warp(block.timestamp + 25 hours);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_boostWithinBucketAndCaps() public view {
        assertLe(vault.boostCommitted(), vault.boostBucket());
        assertEq(vault.boostCommitted(), handler.ghostBoost());
        assertEq(vault.miningCommitted(), handler.ghostBase());
        uint256 n = handler.touchedDayCount();
        for (uint256 i; i < n; ++i) {
            uint256 d = handler.touchedDays(i);
            assertLe(vault.globalDayUsed(d), 100_000e18);
            for (uint256 id = 1; id <= handler.IDS(); ++id) {
                assertLe(vault.nftDayUsed(id, d), 10_000e18);
            }
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_boostNeverAboveHalfOfBase() public view {
        assertEq(handler.boostOverHalf(), 0);
        assertLe(vault.boostCommitted(), vault.miningCommitted() / 2 + 1);
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_hamsterAccountedAndConserved() public view {
        assertEq(hamster.balanceOf(address(vault)), vault.trackedHamster());
        // what left the vault is exactly what was committed out of the buckets, plus stakes returned
        assertEq(hamster.balanceOf(address(vault)) + handler.hamsterOut(), 8e26 + handler.hamsterStakedIn());
        assertEq(
            vault.totalGrantBalance() + vault.miningBucket() + vault.boostBucket() - vault.miningCommitted()
                - vault.boostCommitted() + vault.totalStaked() + vault.totalUnstaking(),
            vault.trackedHamster()
        );
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_weightMatchesBalances() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            HamsterVault.StakeView memory sv = vault.stakeInfo(handler.actors(i));
            sum += sv.grantBalance;
        }
        assertEq(sum, vault.totalGrantBalance());
        // weight never includes the buckets: it is at most grants plus liquid stake
        assertLe(vault.totalWeight(), vault.totalGrantBalance() + vault.totalStaked());
    }
}
