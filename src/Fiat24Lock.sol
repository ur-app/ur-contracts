// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./interfaces/IFiat24Account.sol";

error Fiat24Lock__NotOperator(address sender);
error Fiat24Lock__NotLocker(address sender);
error Fiat24Lock__Suspended();
error Fiat24Lock__NotSufficientBalance(address sender, address currency);
error Fiat24Lock__NotValidToken(address currency);
error Fiat24Lock__TokenIdNotLive(uint256 tokenId);

contract Fiat24Lock is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant LOCKER_ROLE = keccak256("LOCKER_ROLE");

    uint256 public constant CASHDESK = 9101;
    uint256 public constant SUNDRY = 9103;

    // currency => (tokenId => amount)
    mapping(address => mapping(uint256 => uint256)) public userLockedAmount;
    // currency => totalAmount
    mapping(address => uint256) public currencyTotalLockedAmount;
    // address of Fiat24Token => true/false
    mapping(address => bool) public validXXX24Tokens;

    address public fiat24AccountAddress;

    event Locked(uint256 indexed tokenId, address indexed currency, uint256 amount);
    event Claimed(address indexed sender, uint256 indexed tokenId, address indexed currency, uint256 amount);

    function initialize(address admin, address fiat24AccountAddress_, address usd24_, address eur24_, address chf24_, address gbp24_) public initializer {
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ROLE, admin);
        fiat24AccountAddress = fiat24AccountAddress_;
        validXXX24Tokens[usd24_] = true;
        validXXX24Tokens[eur24_] = true;
        validXXX24Tokens[chf24_] = true;
        validXXX24Tokens[gbp24_] = true;
    }

    function lock(uint256 tokenId_, address currency_, uint256 amount_) external {
        if (paused()) revert Fiat24Lock__Suspended();
        if (!hasRole(LOCKER_ROLE, _msgSender())) revert Fiat24Lock__NotLocker(_msgSender());
        if (!validXXX24Tokens[currency_]) revert Fiat24Lock__NotValidToken(currency_);
        userLockedAmount[currency_][tokenId_] += amount_;
        currencyTotalLockedAmount[currency_] += amount_;
        IERC20Upgradeable(currency_).safeTransferFrom(
            IFiat24Account(fiat24AccountAddress).ownerOf(CASHDESK), IFiat24Account(fiat24AccountAddress).ownerOf(SUNDRY), amount_
        );
        emit Locked(tokenId_, currency_, amount_);
    }

    function claim(address currency_, uint256 amount_) external {
        if (paused()) revert Fiat24Lock__Suspended();
        if (!validXXX24Tokens[currency_]) revert Fiat24Lock__NotValidToken(currency_);
        uint256 tokenId = IFiat24Account(fiat24AccountAddress).tokenOfOwnerByIndex(_msgSender(), 0);
        if (IFiat24Account(fiat24AccountAddress).status(tokenId) != 5) revert Fiat24Lock__TokenIdNotLive(tokenId);
        if (userLockedAmount[currency_][tokenId] < amount_) revert Fiat24Lock__NotSufficientBalance(_msgSender(), currency_);
        userLockedAmount[currency_][tokenId] -= amount_;
        currencyTotalLockedAmount[currency_] -= amount_;
        IERC20Upgradeable(currency_).safeTransferFrom(IFiat24Account(fiat24AccountAddress).ownerOf(SUNDRY), _msgSender(), amount_);
        emit Claimed(_msgSender(), tokenId, currency_, amount_);
    }

    function setLockedAmount(uint256 tokenId_, address currency_, uint256 amount_) external {
        if (!hasRole(OPERATOR_ROLE, _msgSender())) revert Fiat24Lock__NotOperator(_msgSender());
        if (paused()) revert Fiat24Lock__Suspended();
        if (!validXXX24Tokens[currency_]) revert Fiat24Lock__NotValidToken(currency_);
        currencyTotalLockedAmount[currency_] -= userLockedAmount[currency_][tokenId_];
        userLockedAmount[currency_][tokenId_] = amount_;
        currencyTotalLockedAmount[currency_] += amount_;
    }

    function pause() external {
        if (!hasRole(OPERATOR_ROLE, _msgSender())) revert Fiat24Lock__NotOperator(_msgSender());
        _pause();
    }

    function unpause() external {
        if (!hasRole(OPERATOR_ROLE, _msgSender())) revert Fiat24Lock__NotOperator(_msgSender());
        _unpause();
    }
}
