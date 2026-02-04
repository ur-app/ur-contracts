// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title MockAggregator
 * @notice Simple mock aggregator that transfers output tokens when called
 */
contract MockAggregator {
    function swap(
        address tokenOut,
        address recipient,
        uint256 amountOut
    ) external {
        // Transfer output tokens to recipient (simulating a swap)
        // Note: aggregator must have approved balance or be the owner
        IERC20Upgradeable(tokenOut).transfer(recipient, amountOut);
    }
}

