// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterVault} from "../../src/HamsterVault.sol";
import {MockERC20, MockGame, MockERC721} from "./Mocks.sol";

abstract contract VaultTest is Test {
    address internal constant IMD_ADDR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint64 internal constant GENESIS = 1791847200;

    address internal team = makeAddr("team");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockERC20 internal imd;
    MockERC20 internal hamster;
    MockGame internal game;
    MockERC721 internal squeek;
    HamsterVault internal vault;

    function setUp() public virtual {
        vm.warp(GENESIS + 10 days);
        MockERC20 impl = new MockERC20("IMD", "IMD");
        vm.etch(IMD_ADDR, address(impl).code);
        imd = MockERC20(IMD_ADDR);
        game = new MockGame(IMD_ADDR);
        squeek = new MockERC721();
        vault = new HamsterVault(team, address(game));
        hamster = new MockERC20("HAMSTER", "HAMSTER");
        _bind();
    }

    function _bind() internal virtual {
        hamster.mint(address(vault), 8e26);
        hamster.mint(address(0xBEEF), 2e26);
        vm.prank(team);
        vault.bindToken(address(hamster));
    }

    function _finalize(address a, uint256 lossA) internal {
        address[] memory accs = new address[](1);
        uint256[] memory l = new uint256[](1);
        accs[0] = a;
        l[0] = lossA;
        game.finalizeWindow(accs, l, lossA);
    }

    function _finalize2(address a, uint256 lossA, address b, uint256 lossB) internal {
        address[] memory accs = new address[](2);
        uint256[] memory l = new uint256[](2);
        accs[0] = a;
        accs[1] = b;
        l[0] = lossA;
        l[1] = lossB;
        game.finalizeWindow(accs, l, lossA + lossB);
    }

    function _claim(uint256 k, address a) internal {
        uint256[] memory ws = new uint256[](1);
        ws[0] = k;
        vault.claimMined(ws, a);
    }

    function _giveHamster(address to, uint256 amount) internal {
        hamster.mint(to, amount);
        vm.prank(to);
        hamster.approve(address(vault), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        _giveHamster(who, amount);
        vm.prank(who);
        vault.stake(amount);
    }

    function _depositRewards(uint256 amount) internal {
        imd.mint(address(this), amount);
        imd.approve(address(vault), amount);
        vault.depositRewards(amount);
    }

    function _depositDrip(uint256 amount) internal {
        imd.mint(address(this), amount);
        imd.approve(address(vault), amount);
        vault.depositDrip(amount);
    }

    function _activateBoost() internal {
        vm.prank(team);
        vault.scheduleBoost(address(squeek));
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        vault.activateBoost(address(squeek));
    }
}
