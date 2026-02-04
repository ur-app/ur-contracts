// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IntegrationTest} from "./Integration.t.sol";

contract RoleTransferTest is IntegrationTest {
    function testOperatorAdminCanSetTreasury() public {
        vm.prank(admin);
        marqeta.setTreasuryAddress(address(this));
    }
}


