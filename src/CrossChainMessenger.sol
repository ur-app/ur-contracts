// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ICrossChainMessenger } from "./interfaces/ICrossChainMessenger.sol";
import { SafeCall } from "./libraries/SafeCall.sol";

/**
 * @title CrossChainMessenger
 * @notice A simplified contract for sending cross-chain messages between L1 and L2.
 */
contract CrossChainMessenger is AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // Define the role for authorized senders
    bytes32 public constant AUTHORIZED_SENDER_ROLE = keccak256("AUTHORIZED_SENDER_ROLE");
    bytes32 public constant DEPOSIT_SENDER_ROLE = keccak256("DEPOSIT_SENDER_ROLE");

    // Mapping to store successful message relays
    mapping(bytes32 => bool) public successfulMessages;
    // Mapping to send successful message relays
    mapping(bytes32 => bool) public sentMessages;

    // Nonce for generating unique message identifiers
    uint256 private msgNonce;

    // Events to track message sending and receipt
    event SentMessage(address indexed target, address sender, bytes message, uint256 messageNonce);
    event SentMessageHash(bytes32 indexed msgHash);
    event RelayedMessage(bytes32 indexed msgHash);
    event FailedRelayedMessage(bytes32 indexed msgHash);

    /**
     * @dev Initializes the contract and grants the deployer the admin role.
     */
    function initialize() public initializer {
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Modifier to restrict the ability to send messages to authorized addresses only
     */
    modifier onlyAuthorizedSender() {
        require(hasRole(AUTHORIZED_SENDER_ROLE, msg.sender), "Not authorized to send messages");
        _;
    }

    /**
     * @notice Modifier to restrict the ability to send messages by deposit contract addresses only
     */
    modifier onlyDepositContract() {
        require(hasRole(DEPOSIT_SENDER_ROLE, msg.sender), "Not authorized to send messages");
        _;
    }


    /**
     * @notice Sends a message to the target address on the other chain
     * @param _target Address of the contract or wallet on the other chain
     * @param _message Message data to send
     */
    function sendMessage(address _target, bytes calldata _message) external payable whenNotPaused onlyDepositContract {
        bytes32 messageHash = _getMessageHash(_target, msg.sender, _message);

        sentMessages[messageHash] = true;

        emit SentMessageHash(messageHash);
        emit SentMessage(_target, msg.sender, _message, msgNonce);

        // Increment message nonce to ensure unique message identifiers
        unchecked {
            ++msgNonce;
        }
    }

    /**
     * @notice Relays a message from the other chain to this chain
     * @param _messageHash Hash of the message being relayed
     * @param _sender Sender of the message on the other chain
     * @param _target Target address of the message
     * @param _message Message data
     */
    function relayMessage(
        uint256 _nonce,
        address _sender,
        address _target,
        bytes calldata _message,
        bytes32 _messageHash
    ) external whenNotPaused onlyAuthorizedSender {

        bytes32 messageHash = keccak256(abi.encodePacked(_target, _sender, _message, _nonce));

        // Ensure the provided _messageHash matches the generated messageHash
        require(_messageHash == messageHash, "Message hash mismatch");
        require(!successfulMessages[_messageHash], "Message already relayed");

        _handleMessage(_target, _message,messageHash);

        emit RelayedMessage(_messageHash);
    }

    /**
     * @notice Handles the received message (custom logic for handling cross-chain data)
     * @param _target Address of the message target
     * @param _message The actual message data
     */
    function _handleMessage(
        address _target,
        bytes calldata _message,
        bytes32 _messageHash
    ) internal {

        bool success = SafeCall.call(_target, gasleft(), 0, _message);

        if (success) {
            successfulMessages[_messageHash] = true;
            emit RelayedMessage(_messageHash);
        } else {
            successfulMessages[_messageHash] = false;
            emit FailedRelayedMessage(_messageHash);
        }
    }

    /**
     * @notice Generates a unique hash for the message
     * @param _message The message data
     * @return The hash of the message
     */
    function _getMessageHash(address _target, address sender, bytes calldata _message) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_target, sender, _message, msgNonce));
    }

    /**
     * @notice Getter for the current message nonce
     * @return The current message nonce
     */
    function getMessageNonce() external view returns (uint256) {
        return msgNonce;
    }

    /**
     * @notice Checks whether a message has already been successfully relayed
     * @param _messageHash The hash of the message
     * @return True if the message has been successfully relayed, otherwise false
     */
    function isMessageRelayed(bytes32 _messageHash) external view returns (bool) {
        return successfulMessages[_messageHash];
    }

    /**
     * @notice Allows the admin to pause the contract (if necessary)
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Allows the admin to unpause the contract (if necessary)
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Function to authorize the upgrade mechanism
     */
    function _authorizeUpgrade(address newImplementation) internal onlyRole(DEFAULT_ADMIN_ROLE) {}
}