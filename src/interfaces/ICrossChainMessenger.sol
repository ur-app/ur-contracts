// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICrossChainMessenger {
    function sendMessage(address target, bytes memory message) external;
}
