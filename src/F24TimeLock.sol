// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IFiat24Account.sol";

contract F24TimeLock is Initializable, AccessControlUpgradeable {
    struct LockedAmount {
        uint256 lockedAmount;
        uint256 unlockTime;
    }

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IERC20 public token;
    IFiat24Account public fiat24Account;

    mapping(uint256 => LockedAmount) public lockedAmounts;

    uint256 public lockPeriod;

    event Locked(address indexed sender, uint256 amount, uint256 unlockTime);
    event Claimed(address indexed owner, uint256 amount);

    error F24TimeLock__NoToken();
    error F24TimeLock__TokensLocked();
    error F24TimeLock__NotEnoughTokensLocked();
    error F24TimeLock__NoTokensLocked();
    error F24TimeLock__LockTransferFailed();
    error F24TimeLock__ClaimTransferFailed();
    error F24TimeLock__NotOperator();

    function initialize(address admin, address tokenAddress_, address fiat24AccountAddress, uint256 lockPeriod_) public initializer {
        __AccessControl_init_unchained();
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ROLE, admin);
        token = IERC20(tokenAddress_);
        fiat24Account = IFiat24Account(fiat24AccountAddress);
        lockPeriod = lockPeriod_;
    }

    function lock(uint256 amount_) external {
        uint256 tokenId = getTokenId(msg.sender);
        if (tokenId == 0) {
            revert F24TimeLock__NoToken();
        }
        lockedAmounts[tokenId].lockedAmount += amount_;
        lockedAmounts[tokenId].unlockTime = block.timestamp + lockPeriod;
        if (!token.transferFrom(msg.sender, address(this), amount_)) {
            revert F24TimeLock__LockTransferFailed();
        }
        emit Locked(msg.sender, amount_, lockedAmounts[tokenId].unlockTime);
    }

    function claim(uint256 amount_) external {
        uint256 tokenId = getTokenId(msg.sender);
        if (tokenId == 0) {
            revert F24TimeLock__NoToken();
        }
        if (lockedAmounts[tokenId].lockedAmount == 0) {
            revert F24TimeLock__NoTokensLocked();
        }
        if (lockedAmounts[tokenId].unlockTime > block.timestamp) {
            revert F24TimeLock__TokensLocked();
        }
        if (lockedAmounts[tokenId].lockedAmount < amount_) {
            revert F24TimeLock__NotEnoughTokensLocked();
        }
        lockedAmounts[tokenId].lockedAmount -= amount_;
        if (!token.transfer(msg.sender, amount_)) {
            revert F24TimeLock__ClaimTransferFailed();
        }
        emit Claimed(msg.sender, amount_);
    }

    function claimableAmount(uint256 tokenId_) external view returns (uint256) {
        if (lockedAmounts[tokenId_].unlockTime == 0 || lockedAmounts[tokenId_].unlockTime > block.timestamp) {
            return 0;
        } else {
            return lockedAmounts[tokenId_].lockedAmount;
        }
    }

    function setLockPeriod(uint256 lockPeriod_) external {
        if (!(hasRole(OPERATOR_ROLE, msg.sender))) {
            revert F24TimeLock__NotOperator();
        }
        lockPeriod = lockPeriod_;
    }

    function getTokenId(address sender_) internal view returns (uint256 tokenId_) {
        try fiat24Account.tokenOfOwnerByIndex(sender_, 0) returns (uint256 tokenId) {
            return tokenId;
        } catch Error(string memory) {
            return fiat24Account.historicOwnership(sender_);
        } catch (bytes memory) {
            return fiat24Account.historicOwnership(sender_);
        }
    }
}
