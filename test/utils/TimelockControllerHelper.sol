// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

abstract contract TimelockControllerHelper {
    TimelockController public timelock;

    function deployTimelock(address owner) public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;
        timelock = new TimelockController(0, proposers, executors);
    }
}
