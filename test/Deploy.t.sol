// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterVault} from "../src/HamsterVault.sol";
import {DeployHamsterVault} from "../script/Deploy.s.sol";

contract DeployTest is Test {
    function test_deployWithRealParamsOnEmptyChain() public {
        DeployHamsterVault d = new DeployHamsterVault();
        HamsterVault v = d.deploy(d.TEAM(), d.GAME());
        assertEq(v.TEAM(), 0x6CBA4751742F6989fA224B2dC5d5d52fCef98a34);
        assertEq(address(v.GAME()), 0xe33AB493249a2Df0D8c4a71aC54F46d1F7778367);
        assertEq(v.IMD(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(address(v.token()), address(0));
        assertEq(v.DEPLOYED_AT(), block.timestamp);
        assertLe(address(v).code.length, 24_576);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(HamsterVault.ZeroAddress.selector);
        new HamsterVault(address(0), address(1));
        vm.expectRevert(HamsterVault.ZeroAddress.selector);
        new HamsterVault(address(1), address(0));
    }

    function test_noOwnerPowersBeyondTwo() public {
        HamsterVault v = new HamsterVault(address(1), address(2));
        // There is no owner(), pause, upgrade or sweep-to-owner entry point; only TEAM-gated calls are
        // bindToken, scheduleBoost and activateBoost, and each reverts for anyone else.
        vm.expectRevert(HamsterVault.NotTeam.selector);
        v.bindToken(address(3));
        vm.expectRevert(HamsterVault.NotTeam.selector);
        v.scheduleBoost(address(3));
        vm.expectRevert(HamsterVault.NotTeam.selector);
        v.activateBoost(address(3));
    }
}
