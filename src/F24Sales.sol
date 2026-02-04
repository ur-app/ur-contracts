// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./interfaces/IFiat24Account.sol";

error F24Sales__NotAuthorizer(address sender);
error F24Sales__Paused();
error F24Sales__MsgValueZero(uint256 msgvalue);
error F24Sales__NotEnoughF24(uint256 balance, uint256 amount);
error F24Sales__F24AmountTooSmall(uint256 amount, address sender);
error F24Sales__ETHTransferFailed(address to, uint256 amount);

contract F24Sales is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant TREASURY = 9100;
    address public f24Address;
    address public fiat24AccountAddress;

    event SoldF24(address indexed sender, uint256 msgvalue, uint256 f24Amount);

    function initialize(address fiat24AccountAddress_, address f24Address_) public initializer {
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(OPERATOR_ROLE, _msgSender());
        fiat24AccountAddress = fiat24AccountAddress_;
        f24Address = f24Address_;
    }

    function quotePerEther() public view returns (uint256) {
        if (block.timestamp > 1782856800) {
            return 10000; // 2026-07-01
        } else if (block.timestamp > 1774994400) {
            return 15000; // 2026-04-01
        } else if (block.timestamp > 1767222000) {
            return 20000; // 2026-01-01
        } else if (block.timestamp > 1759269600) {
            return 25000; // 2025-10-01
        } else if (block.timestamp > 1751320800) {
            return 30000; // 2025-07-01
        } else if (block.timestamp > 1743458400) {
            return 35000; // 2025-04-01
        } else if (block.timestamp > 1735686000) {
            return 40000; // 2025-01-01
        } else if (block.timestamp > 1727733600) {
            return 45000; // 2024-10-01
        } else if (block.timestamp > 1719784800) {
            return 50000; // 2024-07-01
        } else {
            return 150000;
        }
    }

    function buy() external payable returns (uint256) {
        if (paused()) revert F24Sales__Paused();
        if (msg.value == 0) revert F24Sales__MsgValueZero(msg.value);
        uint256 f24Amount = msg.value * quotePerEther() / 10 ** 18;
        if (f24Amount == 0) revert F24Sales__F24AmountTooSmall(f24Amount, _msgSender());
        address treasury = IFiat24Account(fiat24AccountAddress).ownerOf(TREASURY);
        uint256 treasuryF24Balance = IERC20Upgradeable(f24Address).balanceOf(treasury);
        if (treasuryF24Balance < f24Amount) revert F24Sales__NotEnoughF24(treasuryF24Balance, f24Amount);
        (bool success,) = treasury.call{value: msg.value}("");
        if (!success) revert F24Sales__ETHTransferFailed(treasury, msg.value);
        IERC20Upgradeable(f24Address).safeTransferFrom(treasury, _msgSender(), f24Amount);
        emit SoldF24(_msgSender(), msg.value, f24Amount);
        return f24Amount;
    }

    function pause() external {
        if (!(hasRole(OPERATOR_ROLE, _msgSender()))) revert F24Sales__NotAuthorizer(_msgSender());
        _pause();
    }

    function unpause() external {
        if (!(hasRole(OPERATOR_ROLE, _msgSender()))) revert F24Sales__NotAuthorizer(_msgSender());
        _unpause();
    }
}
