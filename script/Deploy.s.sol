// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HamsterVault} from "../src/HamsterVault.sol";

/// @notice Deployment parameters for Ethereum mainnet. The IMD launch factory deploys the contract
/// from its bytecode with these constructor arguments; this script only documents and rehearses them.
contract DeployHamsterVault is Script {
    /// @notice TEAM: the launch wallet ($owner).
    address public constant TEAM = 0x6CBA4751742F6989fA224B2dC5d5d52fCef98a34;
    /// @notice HamsterHour v2 on Ethereum mainnet.
    address public constant GAME = 0xe33AB493249a2Df0D8c4a71aC54F46d1F7778367;

    function deploy(address team, address game) public returns (HamsterVault vault) {
        vault = new HamsterVault(team, game);
    }

    function run() external returns (HamsterVault vault) {
        vm.startBroadcast();
        vault = deploy(TEAM, GAME);
        vm.stopBroadcast();
    }
}
