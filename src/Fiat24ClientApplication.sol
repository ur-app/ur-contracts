// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./interfaces/IFiat24Account.sol";

error Fiat24ClientApplication__NotTokenOwner();
error Fiat24ClientApplication__NotOperator(address sender);
error Fiat24ClientApplication__NotClientApplicationRole(address sender);
error Fiat24ClientApplication__TokenDoesNotExist(uint256 tokenId);
error Fiat24ClientApplication__ClientApplicationNotAvailable();
error Fiat24ClientApplication__BankInfoNotAvailable();
error Fiat24ClientApplication__BlockedForUpdate();
error Fiat24ClientApplication__CurrencyNotAvailable();
error Fiat24ClientApplication__ClientApplicationSuspended();

contract Fiat24ClientApplication is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CLIENT_APPLICATION_ROLE = keccak256("CLIENT_APPLICATION_ROLE");

    struct ClientApplication {
        bool available;
        string clientApplicationData;
        uint256 blockedUntil;
    }

    struct AddressProof {
        bool available;
        string geolocation;
        uint256 blockedUntil;
    }

    uint256 public blockingPeriod;

    // mapping tokenId => clientApplication (encrypted)
    mapping(uint256 => ClientApplication) public clientApplication;

    IFiat24Account public fiat24Account;

    event ClientApplicationAdded(uint256 indexed tokenId, address indexed sender, string clientApplication);
    event AddressProofAdded(uint256 indexed tokenId, address indexed sender, string geolocation);

    mapping(uint256 => AddressProof) public addressProof;

    function initialize(address admin, address fiat24AccountAddress_, uint256 blockingPeriod_) public initializer {
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        _setupRole(OPERATOR_ROLE, admin);
        fiat24Account = IFiat24Account(fiat24AccountAddress_);
        blockingPeriod = blockingPeriod_;
    }

    function addClientApplication(uint256 tokenId_, string memory clientApplicationData_) external {
        if (paused()) {
            revert Fiat24ClientApplication__ClientApplicationSuspended();
        }
        if (!(tokenExists(tokenId_) && (fiat24Account.ownerOf(tokenId_) == msg.sender || fiat24Account.historicOwnership(msg.sender) == tokenId_))) {
            revert Fiat24ClientApplication__NotTokenOwner();
        }
        ClientApplication storage clientApplication_ = clientApplication[tokenId_];
        if (clientApplication_.available && block.timestamp < clientApplication_.blockedUntil) {
            revert Fiat24ClientApplication__BlockedForUpdate();
        }
        clientApplication_.available = true;
        clientApplication_.clientApplicationData = clientApplicationData_;
        clientApplication_.blockedUntil = block.timestamp + blockingPeriod;
        emit ClientApplicationAdded(tokenId_, msg.sender, clientApplicationData_);
    }

    function operatorAddClientApplication(uint256 tokenId_, string memory clientApplicationData_) external {
        if (!(hasRole(CLIENT_APPLICATION_ROLE, msg.sender))) {
            revert Fiat24ClientApplication__NotClientApplicationRole(msg.sender);
        }
        if (paused()) {
            revert Fiat24ClientApplication__ClientApplicationSuspended();
        }
        if (!tokenExists(tokenId_)) {
            revert Fiat24ClientApplication__TokenDoesNotExist(tokenId_);
        }
        ClientApplication storage clientApplication_ = clientApplication[tokenId_];

        clientApplication_.available = true;
        clientApplication_.clientApplicationData = clientApplicationData_;
        clientApplication_.blockedUntil = block.timestamp + blockingPeriod;
        emit ClientApplicationAdded(tokenId_, msg.sender, clientApplicationData_);
    }

    function setBlockingPeriod(uint256 blockingPeriod_) external {
        if (!(hasRole(OPERATOR_ROLE, msg.sender))) {
            revert Fiat24ClientApplication__NotOperator(msg.sender);
        }
        blockingPeriod = blockingPeriod_;
    }

    function addAddressProof(uint256 tokenId_, string memory geolocation_) external {
        if (paused()) {
            revert Fiat24ClientApplication__ClientApplicationSuspended();
        }
        if (!(tokenExists(tokenId_) && (fiat24Account.ownerOf(tokenId_) == msg.sender || fiat24Account.historicOwnership(msg.sender) == tokenId_))) {
            revert Fiat24ClientApplication__NotTokenOwner();
        }
        ClientApplication storage clientApplication_ = clientApplication[tokenId_];
        if (!clientApplication_.available) {
            revert Fiat24ClientApplication__ClientApplicationNotAvailable();
        }
        AddressProof storage addressProof_ = addressProof[tokenId_];
        if (addressProof_.available && block.timestamp < addressProof_.blockedUntil) {
            revert Fiat24ClientApplication__BlockedForUpdate();
        }
        addressProof_.available = true;
        addressProof_.geolocation = geolocation_;
        addressProof_.blockedUntil = clientApplication_.blockedUntil;
        emit AddressProofAdded(tokenId_, msg.sender, geolocation_);
    }

    function operatorAddAddressProof(uint256 tokenId_, string memory geolocation_) external {
        if (!(hasRole(CLIENT_APPLICATION_ROLE, msg.sender))) {
            revert Fiat24ClientApplication__NotClientApplicationRole(msg.sender);
        }
        if (paused()) {
            revert Fiat24ClientApplication__ClientApplicationSuspended();
        }
        if (!tokenExists(tokenId_)) {
            revert Fiat24ClientApplication__TokenDoesNotExist(tokenId_);
        }
        ClientApplication storage clientApplication_ = clientApplication[tokenId_];
        if (!clientApplication_.available) {
            revert Fiat24ClientApplication__ClientApplicationNotAvailable();
        }

        AddressProof storage addressProof_ = addressProof[tokenId_];

        addressProof_.available = true;
        addressProof_.geolocation = geolocation_;
        addressProof_.blockedUntil = clientApplication_.blockedUntil;
        emit AddressProofAdded(tokenId_, msg.sender, geolocation_);
    }

    function tokenExists(uint256 tokenId_) internal view returns (bool) {
        try fiat24Account.ownerOf(tokenId_) returns (address) {
            return true;
        } catch Error(string memory) {
            return false;
        } catch (bytes memory) {
            return false;
        }
    }

    function pause() external {
        if (!(hasRole(OPERATOR_ROLE, msg.sender))) {
            revert Fiat24ClientApplication__NotOperator(msg.sender);
        }
        _pause();
    }

    function unpause() external {
        if (!(hasRole(OPERATOR_ROLE, msg.sender))) {
            revert Fiat24ClientApplication__NotOperator(msg.sender);
        }
        _unpause();
    }

    function setupRole(bytes32 role_, address owner_) external {
        if (!(hasRole(OPERATOR_ROLE, msg.sender))) {
            revert Fiat24ClientApplication__NotOperator(msg.sender);
        }
        _setupRole(role_, owner_);
    }
}
