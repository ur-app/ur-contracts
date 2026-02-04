// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IF24Sales {
    enum Status {
        Na,
        SoftBlocked,
        Tourist,
        Blocked,
        Closed,
        Live
    }

    function quotePerEther() external view returns (uint256);
    function buy() external payable returns (uint256);
}
