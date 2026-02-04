// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFiat24CardReserve {
    function depositReserveByCardAuthorization(uint256 tokenId, address currency, uint256 amount) external;
    function spendReserve(uint256 tokenId, address currency, uint256 amount, address spender) external;
    function cardReserve(uint256 tokenId, address currency) external view returns (uint256);
    function CARD_RESERVED() external view returns (uint256);
}
