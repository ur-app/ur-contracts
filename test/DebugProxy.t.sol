// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockControllerHelper} from "./utils/TimelockControllerHelper.sol";
import {Fiat24Account} from "../src/Fiat24Account.sol";
import {Fiat24CardAuthorizationMarqeta} from "../src/Fiat24CardAuthorizationMarqeta.sol";

contract DebugProxyTest is Test, TimelockControllerHelper {
    address internal admin = address(0xA11CE);
    
    function test_debugAccountProxy() public {
        vm.startPrank(admin);
        deployTimelock(admin);
        
        // Deploy Fiat24Account with proxy
        address accountImpl = address(new Fiat24Account());
        Fiat24Account account = Fiat24Account(address(new TransparentUpgradeableProxy(
            accountImpl,
            address(timelock),
            abi.encodeWithSelector(Fiat24Account.initialize.selector, admin)
        )));
        
        // Test basic functionality
        assertEq(account.hasRole(account.DEFAULT_ADMIN_ROLE(), admin), true);
        vm.stopPrank();
    }
    
    function test_debugMarqetaProxy() public {
        vm.startPrank(admin);
        deployTimelock(admin);
        
        // Deploy Fiat24Account first
        address accountImpl = address(new Fiat24Account());
        Fiat24Account account = Fiat24Account(address(new TransparentUpgradeableProxy(
            accountImpl,
            address(timelock),
            abi.encodeWithSelector(Fiat24Account.initialize.selector, admin)
        )));
        
        // Deploy CardAuthorizationMarqeta with proxy
        address marqetaImpl = address(new Fiat24CardAuthorizationMarqeta());
        Fiat24CardAuthorizationMarqeta marqeta = Fiat24CardAuthorizationMarqeta(address(new TransparentUpgradeableProxy(
            marqetaImpl,
            address(timelock),
            abi.encodeWithSelector(
                Fiat24CardAuthorizationMarqeta.initialize.selector,
                admin,
                address(account),
                address(0x1), // eur24Address
                address(0x2), // usd24Address  
                address(0x3), // chf24Address
                address(0x4), // gbp24Address
                address(0x5), // cnh24Address
                address(0x6)  // fiat24CryptoRelayAddress
            )
        )));
        
        // Test basic functionality
        assertEq(marqeta.hasRole(marqeta.DEFAULT_ADMIN_ROLE(), admin), true);
        vm.stopPrank();
    }
}
