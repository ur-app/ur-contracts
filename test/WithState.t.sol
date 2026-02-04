// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IntegrationTest} from "./Integration.t.sol";

contract WithStateTest is IntegrationTest {
    function setUp() public virtual override {
        super.setUp();
        // put contract in a typical state
        // Treasury address is already set in BaseTest, but we need to change it for these tests
        vm.prank(admin);
        marqeta.setTreasuryAddress(address(this));
        vm.prank(admin);
        marqeta.setCryptoTokenPairActive(address(usdc), address(usd), 1e18);
    }
}


