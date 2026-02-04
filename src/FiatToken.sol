// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Fiat24Token.sol";

contract FiatToken is Fiat24Token {
    function initialize(address admin, address fiat24AccountProxyAddress, string calldata name, string calldata symbol, uint256 limitWalkin, uint256 chfRate, uint256 withdrawCharge) public initializer {
        __Fiat24Token_init_(admin, fiat24AccountProxyAddress, name, symbol, limitWalkin, chfRate, withdrawCharge);
    }
}