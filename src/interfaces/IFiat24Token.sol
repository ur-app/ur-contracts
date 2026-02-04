// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFiat24Token {
    function mint(address account, uint256 amount) external;
    function decimals() external view returns (uint8);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function tokenTransferAllowed(address from, address to, uint256 amount) external view returns (bool);
    function convertToChf(uint256 amount) external view returns (uint256);
    function convertFromChf(uint256 amount) external view returns (uint256);
}
