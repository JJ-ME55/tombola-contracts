// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DrandBeacon} from "../src/DrandBeacon.sol";
import {TombolaDraw} from "../src/TombolaDraw.sol";
import {TombolaSplitter, IPonsFeeEscrow, ITombolaDrawPots} from "../src/TombolaSplitter.sol";

/// Deploys TombolaDraw and TombolaSplitter for the Pons launch, reusing the DrandBeacon already on chain.
/// Environment: BEACON (0xaf4f...9A0E on Robinhood Chain), KEEPER, GUARDIAN (0 for none), TEAM_FEE_WALLET,
/// PONS_ESCROW (0xd3AF...Ac9e on Robinhood Chain).
contract DeployPons is Script {
    function run() external returns (TombolaDraw draw, TombolaSplitter splitter) {
        DrandBeacon beacon = DrandBeacon(vm.envAddress("BEACON"));
        address keeper = vm.envAddress("KEEPER");
        address guardian = vm.envOr("GUARDIAN", address(0));
        address teamFee = vm.envAddress("TEAM_FEE_WALLET");
        address escrow = vm.envAddress("PONS_ESCROW");
        require(address(beacon).code.length > 0, "no beacon code");
        require(escrow.code.length > 0, "no escrow code");

        vm.startBroadcast();
        address deployer = msg.sender;
        // the draw pins the splitter and the splitter pins the draw: predict the splitter's address (next nonce)
        address splitterAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        draw = new TombolaDraw(beacon, keeper, guardian, splitterAddr);
        splitter = new TombolaSplitter(ITombolaDrawPots(address(draw)), teamFee, IPonsFeeEscrow(escrow));
        vm.stopBroadcast();
        require(address(splitter) == splitterAddr, "splitter address mismatch");

        console2.log("TombolaDraw     ", address(draw));
        console2.log("TombolaSplitter ", address(splitter));
        console2.log("beacon          ", address(beacon));
        console2.log("keeper          ", keeper);
        console2.log("guardian        ", guardian);
        console2.log("team fee wallet ", teamFee);
        console2.log("Pons escrow     ", escrow);
        console2.log("Launch on Pons with creatorFeeRecipient = the splitter.");
    }
}
