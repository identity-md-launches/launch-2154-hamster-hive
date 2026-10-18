// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HamsterHive} from "../src/HamsterHive.sol";

/// @title Deploy script for Hamster Hive (HAMSTER)
/// @notice Reviewable reference deployment. The IdentityMD launch deploys the token itself from the
/// built bytecode through its factory, so this script is for local and test-network use only.
/// @dev The token has no constructor arguments and no post-deployment configuration, so there is no
/// config to read from the environment. `deploy()` is the unit tests call directly; `run()` only wraps
/// it in a broadcast.
contract DeployHamsterHive is Script {
    /// @notice Deploys the token. Whoever calls this (the broadcaster in `run()`) receives the supply.
    function deploy() public returns (HamsterHive token) {
        token = new HamsterHive();
    }

    function run() external returns (HamsterHive token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
