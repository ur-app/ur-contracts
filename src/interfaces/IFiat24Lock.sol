// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFiat24Lock {
    function lock(uint256 tokenId, address tokenAddress, uint256 amount) external;
}
