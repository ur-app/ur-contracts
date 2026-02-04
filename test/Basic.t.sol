// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IntegrationTest} from "./Integration.t.sol";

contract BasicTest is IntegrationTest {
    function test_setValidXXX24Token_revertsOnNoChange() public {
        // USD token is already true from initialization, so test setting it to true again
        vm.expectRevert(bytes("No state change"));
        vm.prank(admin);
        marqeta.setValidXXX24Token(address(usd), true);
    }
}


