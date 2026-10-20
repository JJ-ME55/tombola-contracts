// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// Pons V2 on Robinhood Chain, the parts the launch needs (hand-checked against the Hive launch, which used
/// exactly this path with native ETH as the pair). Native ETH is pairToken address(0).
struct PonsSocials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

struct PonsTokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    PonsSocials socials;
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    bytes32 expectedEconomics;
    bytes32 salt;
}

interface IPonsFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function launchFee() external view returns (uint256);
    function maxCreatorTaxBps() external view returns (uint256);
    function launchEnabled() external view returns (bool);
    function canLaunch(address) external view returns (bool);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchToken(PonsTokenParams calldata params, uint256 launchConfigId, address pairToken) external payable returns (address token, address curve);
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function feeEscrow() external view returns (address);
}

/// Pure fair launch on Pons V2 (no opening buy): the token and its curve, the creator fee to the TombolaSplitter.
/// Environment: PONS_FACTORY, SPLITTER (creatorFeeRecipient), CREATOR_TAX_BPS (default 500 = 5%, 6% per side to
/// the trader with Pons' 1%), NAME, SYMBOL, LOGO, DESCRIPTION, WEBSITE, TWITTER, TELEGRAM, EXPECT_ECONOMICS
/// (optional pin: refuse if Pons re-priced the curve since the dry run).
contract LaunchOnPons is Script {
    address constant NATIVE = address(0);
    uint256 constant CONFIG = 0;

    function _params(IPonsFactory f) internal view returns (PonsTokenParams memory p) {
        p = PonsTokenParams({
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            logo: vm.envOr("LOGO", string("")),
            description: vm.envOr("DESCRIPTION", string("")),
            socials: PonsSocials({
                twitter: vm.envOr("TWITTER", string("")),
                telegram: vm.envOr("TELEGRAM", string("")),
                discord: vm.envOr("DISCORD", string("")),
                website: vm.envOr("WEBSITE", string("")),
                farcaster: ""
            }),
            creatorFeeRecipient: vm.envAddress("SPLITTER"),
            creatorTaxBps: uint16(vm.envOr("CREATOR_TAX_BPS", uint256(500))),
            buybackEnabled: false,
            expectedEconomics: f.previewLaunchEconomics(CONFIG, NATIVE),
            salt: vm.envOr("SALT", bytes32(0))
        });
    }

    function _checks(IPonsFactory f, PonsTokenParams memory p) internal view returns (uint256 fee) {
        fee = f.launchFee();
        require(f.launchEnabled() || f.canLaunch(msg.sender), "launcher not allowed");
        require(p.creatorTaxBps <= f.maxCreatorTaxBps(), "tax over the cap");
        require(p.creatorFeeRecipient.code.length > 0, "SPLITTER has no code");
        bytes32 expect = vm.envOr("EXPECT_ECONOMICS", bytes32(0));
        require(expect == bytes32(0) || expect == p.expectedEconomics, "Pons re-priced the curve since the dry run");
        require(msg.sender.balance >= fee + 0.002 ether, "launcher needs launchFee + gas");
        console2.log("name / symbol         ", p.name, p.symbol);
        console2.log("creatorFeeRecipient   ", p.creatorFeeRecipient);
        console2.log("creatorTaxBps         ", p.creatorTaxBps);
        console2.log("launchFee (wei)       ", fee);
        console2.log("economics digest      ", vm.toString(p.expectedEconomics));
        console2.log("pair                  : native ETH; buyback off; launch config 0");
    }

    function dryRun() external view {
        IPonsFactory f = IPonsFactory(vm.envAddress("PONS_FACTORY"));
        _checks(f, _params(f));
        console2.log("dry run OK");
    }

    function run() external returns (address token, address curve) {
        IPonsFactory f = IPonsFactory(vm.envAddress("PONS_FACTORY"));
        PonsTokenParams memory p = _params(f);
        uint256 fee = _checks(f, p);
        vm.startBroadcast();
        (token, curve) = f.launchToken{value: fee}(p, CONFIG, NATIVE);
        vm.stopBroadcast();
        IPonsFactory.LaunchedToken memory lt = f.getLaunchedToken(token);
        require(lt.exists && lt.creatorFeeRecipient == p.creatorFeeRecipient && lt.creatorTaxBps == p.creatorTaxBps && lt.pairToken == NATIVE, "launch record mismatch");
        console2.log("TOKEN ", token);
        console2.log("CURVE ", curve);
        console2.log("escrow", f.feeEscrow());
    }
}
