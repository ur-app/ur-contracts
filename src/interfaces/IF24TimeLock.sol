// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

interface IF24TimeLock {
    struct LockedAmount {
        uint256 lockedAmount;
        uint256 unlockTime;
    }

    function lockedAmounts(uint256) external view returns (LockedAmount memory);
    function claimableAmount() external view returns (uint256);
}
