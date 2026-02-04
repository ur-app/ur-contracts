// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/IFiat24CryptoDepositAggregator.sol";

/**
 * @title DepositGateway
 * @notice Lightweight delegation contract for deposit operations on behalf of users
 * @dev Wraps Fiat24CryptoDeposit2 for partner integrations, designed for BeaconProxy deployment
 */
contract DepositGateway is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant DEPOSIT_OPERATOR_ROLE = keccak256("DEPOSIT_OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    // Native token marker addresses
    address public constant NATIVE_TOKEN = address(0);
    address public constant NATIVE_TOKEN_ALIAS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Parameters for deposit operation
    struct DepositParams {
        address user;               // User's address (target Fiat24 account)
        address inputToken;         // Token to deposit
        address outputToken;        // Target Fiat24 token (e.g., USD24, EUR24)
        uint256 amount;             // Total amount of input token (including fee)
        uint256 feeAmount;          // Fee amount to deduct from input token
        address aggregator;         // Aggregator contract for swap
        bytes swapCalldata;         // Calldata for aggregator swap
        uint256 minUsdcAmount;      // Minimum USDC after swap (slippage)
        string partnerRefId;        // Partner's reference ID for reconciliation
    }

    /// @notice Partner identifier
    string public partnerId;
    
    /// @notice Fiat24CryptoDeposit contract for deposit operations
    IFiat24CryptoDepositAggregator public fiat24CryptoDeposit;

    /// @notice Emergency receiver address
    address public emergencyReceiver;

    /// @notice Fee receiver address
    address public feeReceiver;

    // Events
    event DelegateDepositExecuted(
        address indexed user,
        address indexed inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 feeAmount,
        uint256 outputAmount,
        string partnerRefId,
        string partnerId
    );
    event Fiat24CryptoDepositUpdated(address oldDeposit, address newDeposit);
    event EmergencyReceiverUpdated(address oldReceiver, address newReceiver);
    event FeeReceiverUpdated(address oldReceiver, address newReceiver);

    // Errors
    error Gateway__ZeroAddress();
    error Gateway__NoChange();
    error Gateway__InvalidAmount();
    error Gateway__TokenNotSupported();
    error Gateway__TransferFailed();
    error Gateway__FeeExceedsAmount();

    function initialize(
        address _admin,
        string calldata _partnerId,
        address _fiat24CryptoDeposit,
        address _emergencyReceiver,
        address _feeReceiver
    ) public initializer {
        if (_admin == address(0) || _fiat24CryptoDeposit == address(0) || 
            _emergencyReceiver == address(0) || _feeReceiver == address(0)) {
            revert Gateway__ZeroAddress();
        }

        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ADMIN_ROLE, _admin);

        partnerId = _partnerId;
        fiat24CryptoDeposit = IFiat24CryptoDepositAggregator(_fiat24CryptoDeposit);
        emergencyReceiver = _emergencyReceiver;
        feeReceiver = _feeReceiver;
    }

    /**
     * @notice Execute deposit on behalf of user via aggregator swap
     * @dev msg.value = lzFee for LayerZero cross-chain message
     *      Fee is deducted from inputToken and sent to feeReceiver
     * @param params Deposit parameters
     * @return outputAmount The amount of USDC deposited after swap
     */
    function delegateDeposit(DepositParams calldata params)
        external
        payable
        nonReentrant
        whenNotPaused
        onlyRole(DEPOSIT_OPERATOR_ROLE)
        returns (uint256 outputAmount)
    {
        if (params.amount == 0) revert Gateway__InvalidAmount();
        if (_isNativeToken(params.inputToken)) revert Gateway__TokenNotSupported();
        if (params.feeAmount >= params.amount) revert Gateway__FeeExceedsAmount();

        // Transfer ERC20 from user to this contract
        IERC20Upgradeable(params.inputToken).safeTransferFrom(
            params.user,
            address(this),
            params.amount
        );

        // Deduct fee and transfer to feeReceiver
        uint256 depositAmount = params.amount;
        if (params.feeAmount > 0) {
            IERC20Upgradeable(params.inputToken).safeTransfer(feeReceiver, params.feeAmount);
            depositAmount = params.amount - params.feeAmount;
        }

        // Execute deposit via Fiat24CryptoDeposit
        outputAmount = _executeDeposit(params, depositAmount);

        emit DelegateDepositExecuted(
            params.user,
            params.inputToken,
            params.outputToken,
            params.amount,
            params.feeAmount,
            outputAmount,
            params.partnerRefId,
            partnerId
        );
    }

    function _executeDeposit(DepositParams memory params, uint256 depositAmount) internal returns (uint256) {
        // Approve Fiat24CryptoDeposit to transfer tokens
        IERC20Upgradeable(params.inputToken).safeApprove(address(fiat24CryptoDeposit), 0);
        IERC20Upgradeable(params.inputToken).safeApprove(address(fiat24CryptoDeposit), depositAmount);

        // Call depositTokenViaAggregatorToAccount on Fiat24CryptoDeposit2
        // msg.value = lzFee for LayerZero cross-chain message
        uint256 outputAmount = fiat24CryptoDeposit.depositTokenViaAggregatorToAccount{value: msg.value}(
            params.user,        // Target Fiat24 account
            params.inputToken,
            params.outputToken,
            depositAmount,      // Amount after fee deduction
            params.aggregator,
            params.swapCalldata,
            params.minUsdcAmount
        );

        // Reset approval
        IERC20Upgradeable(params.inputToken).safeApprove(address(fiat24CryptoDeposit), 0);

        return outputAmount;
    }

    function _isNativeToken(address token) internal pure returns (bool) {
        return token == NATIVE_TOKEN || token == NATIVE_TOKEN_ALIAS;
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert Gateway__TransferFailed();
    }

    /**
     * @notice Update Fiat24CryptoDeposit contract address
     * @param _fiat24CryptoDeposit New Fiat24CryptoDeposit contract address
     */
    function setFiat24CryptoDeposit(address _fiat24CryptoDeposit) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_fiat24CryptoDeposit == address(0)) revert Gateway__ZeroAddress();
        if (_fiat24CryptoDeposit == address(fiat24CryptoDeposit)) revert Gateway__NoChange();
        address oldDeposit = address(fiat24CryptoDeposit);
        fiat24CryptoDeposit = IFiat24CryptoDepositAggregator(_fiat24CryptoDeposit);
        emit Fiat24CryptoDepositUpdated(oldDeposit, _fiat24CryptoDeposit);
    }

    /**
     * @notice Update emergency receiver address
     * @param _emergencyReceiver New emergency receiver address
     */
    function setEmergencyReceiver(address _emergencyReceiver) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_emergencyReceiver == address(0)) revert Gateway__ZeroAddress();
        if (_emergencyReceiver == emergencyReceiver) revert Gateway__NoChange();
        address oldReceiver = emergencyReceiver;
        emergencyReceiver = _emergencyReceiver;
        emit EmergencyReceiverUpdated(oldReceiver, _emergencyReceiver);
    }

    /**
     * @notice Update fee receiver address
     * @param _feeReceiver New fee receiver address
     */
    function setFeeReceiver(address _feeReceiver) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_feeReceiver == address(0)) revert Gateway__ZeroAddress();
        if (_feeReceiver == feeReceiver) revert Gateway__NoChange();
        address oldReceiver = feeReceiver;
        feeReceiver = _feeReceiver;
        emit FeeReceiverUpdated(oldReceiver, _feeReceiver);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(UNPAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdraw stuck tokens or native ETH to emergencyReceiver
     * @param token Token to withdraw (address(0) or NATIVE_TOKEN_ALIAS for native ETH)
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (amount == 0) revert Gateway__InvalidAmount();
        if (_isNativeToken(token)) {
            _safeTransferETH(emergencyReceiver, amount);
        } else {
            IERC20Upgradeable(token).safeTransfer(emergencyReceiver, amount);
        }
    }

    receive() external payable {}
}
