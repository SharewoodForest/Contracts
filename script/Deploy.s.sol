// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SharewoodGifts} from "../src/SharewoodGifts.sol";

/// Usage: forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify
contract Deploy is Script {
    function run() external returns (SharewoodGifts gifts) {
        address owner = vm.envAddress("OWNER");       // use a Safe multisig before mainnet
        address treasury = vm.envAddress("TREASURY");
        uint16 feeBps = uint16(vm.envUint("FEE_BPS")); // 200 = 2%
        vm.startBroadcast();
        gifts = new SharewoodGifts(owner, treasury, feeBps);
        vm.stopBroadcast();
        console.log("SharewoodGifts deployed at", address(gifts));
    }
}
