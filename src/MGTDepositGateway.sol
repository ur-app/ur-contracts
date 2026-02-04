// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/**
 * @title IMetraGoldSwap
 * @notice Interface for MetraGoldSwap contract
 */
interface IMetraGoldSwap {
    function swapMGTForToken(
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function quoteMGTForToken(
        address token,
        uint256 amountIn
    ) external view returns (uint256 amountOut, bool valid);

}

/**
 * @title IFiat24CryptoDepositAggregator
 * @notice Interface for Fiat24CryptoDeposit contract with aggregator support
 */
interface IFiat24CryptoDepositAggregator {
    function depositTokenViaAggregatorToAccount(
        address _targetAccount,
        address _inputToken,
        address _outputToken,
        uint256 _amount,
        address _aggregator,
        bytes calldata _swapCalldata,
        uint256 _minUsdcAmount
    ) external payable returns (uint256);

}

/**
 * @title MGTDepositGateway
 * @notice Gateway contract to swap MGT to USDC via MetraGoldSwap and deposit to Fiat24
 * @dev Combines MGT -> USDC swap and USDC -> FiatToken deposit in a single transaction
 *      Uses depositTokenViaAggregatorToAccount for flexibility
 */
contract MGTDepositGateway is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    /// @notice MetraGoldSwap contract for MGT -> USDC swap
    IMetraGoldSwap public metraGoldSwap;

    /// @notice Fiat24CryptoDeposit contract for USDC -> FiatToken deposit
    IFiat24CryptoDepositAggregator public fiat24CryptoDeposit;

    /// @notice MGT token address
    IERC20Upgradeable public mgtToken;

    /// @notice USDC token address
    IERC20Upgradeable public usdc;

    /// @notice Emergency receiver address
    address public emergencyReceiver;

    // Events
    event MGTDeposited(
        address indexed user,
        uint256 mgtAmountIn,
        uint256 usdcAmount,
        address outputToken,
        uint256 fiatTokenAmount
    );
    event MetraGoldSwapUpdated(address oldSwap, address newSwap);
    event Fiat24CryptoDepositUpdated(address oldDeposit, address newDeposit);
    event EmergencyReceiverUpdated(address oldReceiver, address newReceiver);
    event MgtTokenUpdated(address oldToken, address newToken);
    event UsdcUpdated(address oldToken, address newToken);

    // Errors
    error Gateway__ZeroAddress();
    error Gateway__NoChange();
    error Gateway__InvalidAmount();
    error Gateway__SwapFailed();
    error Gateway__DepositFailed();
    error Gateway__TransferFailed();
    error Gateway__DeadlineExpired();
    error Gateway__SlippageExceeded();

    /**
     * @notice Initialize the contract
     * @param _admin Admin address
     * @param _metraGoldSwap MetraGoldSwap contract address
     * @param _fiat24CryptoDeposit Fiat24CryptoDeposit contract address
     * @param _emergencyReceiver Emergency receiver address
     * @param _mgtToken MGT token address
     * @param _usdc USDC token address
     */
    function initialize(
        address _admin,
        address _metraGoldSwap,
        address _fiat24CryptoDeposit,
        address _emergencyReceiver,
        address _mgtToken,
        address _usdc
    ) public initializer {
        if (_admin == address(0) || _metraGoldSwap == address(0) || 
            _fiat24CryptoDeposit == address(0) || _emergencyReceiver == address(0) ||
            _mgtToken == address(0) || _usdc == address(0)) {
            revert Gateway__ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ADMIN_ROLE, _admin);

        metraGoldSwap = IMetraGoldSwap(_metraGoldSwap);
        fiat24CryptoDeposit = IFiat24CryptoDepositAggregator(_fiat24CryptoDeposit);
        emergencyReceiver = _emergencyReceiver;
        mgtToken = IERC20Upgradeable(_mgtToken);
        usdc = IERC20Upgradeable(_usdc);
    }

    /**
     * @notice Simplified deposit - MGT to USDC to FiatToken without aggregator params
     * @dev Convenience function when no intermediate swap is needed
     * @param mgtAmount Amount of MGT to swap
     * @param minUsdcAmount Minimum USDC amount expected
     * @param outputToken Target Fiat24 token
     * @param minFiatAmount Minimum fiat token amount expected
     * @param deadline Transaction deadline timestamp
     */
    function depositMGT(
        uint256 mgtAmount,
        uint256 minUsdcAmount,
        address outputToken,
        uint256 minFiatAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 fiatTokenAmount) {
        if (mgtAmount == 0) revert Gateway__InvalidAmount();

        address user = msg.sender;

        mgtToken.safeTransferFrom(user, address(this), mgtAmount);

        mgtToken.safeApprove(address(metraGoldSwap), 0);
        mgtToken.safeApprove(address(metraGoldSwap), mgtAmount);

        uint256 usdcAmount = metraGoldSwap.swapMGTForToken(
            address(usdc),
            mgtAmount,
            minUsdcAmount,
            deadline
        );

        mgtToken.safeApprove(address(metraGoldSwap), 0);

        if (usdcAmount < minUsdcAmount) revert Gateway__SlippageExceeded();

        usdc.safeApprove(address(fiat24CryptoDeposit), 0);
        usdc.safeApprove(address(fiat24CryptoDeposit), usdcAmount);

        // Use USDC address as dummy aggregator (won't be called since inputToken == USDC)
        fiatTokenAmount = fiat24CryptoDeposit.depositTokenViaAggregatorToAccount(
            user,
            address(usdc),
            outputToken,
            usdcAmount,
            address(0),  // dummy aggregator (not used)
            "",             // empty calldata (not used)
            minFiatAmount
        );

        usdc.safeApprove(address(fiat24CryptoDeposit), 0);

        emit MGTDeposited(user, mgtAmount, usdcAmount, outputToken, fiatTokenAmount);
    }

    /**
     * @notice Get quote for depositing MGT
     * @param mgtAmount Amount of MGT to swap
     * @return usdcAmount Expected USDC amount
     * @return valid Whether the MGT price is valid
     */
    function quoteDeposit(uint256 mgtAmount) external view returns (uint256 usdcAmount, bool valid) {
        return metraGoldSwap.quoteMGTForToken(address(usdc), mgtAmount);
    }

    /**
     * @notice Update MetraGoldSwap contract address
     */
    function setMetraGoldSwap(address _metraGoldSwap) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_metraGoldSwap == address(0)) revert Gateway__ZeroAddress();
        if (_metraGoldSwap == address(metraGoldSwap)) revert Gateway__NoChange();
        address oldSwap = address(metraGoldSwap);
        metraGoldSwap = IMetraGoldSwap(_metraGoldSwap);
        emit MetraGoldSwapUpdated(oldSwap, _metraGoldSwap);
    }

    /**
     * @notice Update Fiat24CryptoDeposit contract address
     */
    function setFiat24CryptoDeposit(address _fiat24CryptoDeposit) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_fiat24CryptoDeposit == address(0)) revert Gateway__ZeroAddress();
        if (_fiat24CryptoDeposit == address(fiat24CryptoDeposit)) revert Gateway__NoChange();
        address oldDeposit = address(fiat24CryptoDeposit);
        fiat24CryptoDeposit = IFiat24CryptoDepositAggregator(_fiat24CryptoDeposit);
        emit Fiat24CryptoDepositUpdated(oldDeposit, _fiat24CryptoDeposit);
    }

    /**
     * @notice Update MGT token address
     */
    function setMgtToken(address _mgtToken) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_mgtToken == address(0)) revert Gateway__ZeroAddress();
        if (_mgtToken == address(mgtToken)) revert Gateway__NoChange();
        address oldToken = address(mgtToken);
        mgtToken = IERC20Upgradeable(_mgtToken);
        emit MgtTokenUpdated(oldToken, _mgtToken);
    }

    /**
     * @notice Update USDC token address
     */
    function setUsdc(address _usdc) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_usdc == address(0)) revert Gateway__ZeroAddress();
        if (_usdc == address(usdc)) revert Gateway__NoChange();
        address oldToken = address(usdc);
        usdc = IERC20Upgradeable(_usdc);
        emit UsdcUpdated(oldToken, _usdc);
    }

    /**
     * @notice Update emergency receiver address
     */
    function setEmergencyReceiver(address _emergencyReceiver) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_emergencyReceiver == address(0)) revert Gateway__ZeroAddress();
        if (_emergencyReceiver == emergencyReceiver) revert Gateway__NoChange();
        address oldReceiver = emergencyReceiver;
        emergencyReceiver = _emergencyReceiver;
        emit EmergencyReceiverUpdated(oldReceiver, _emergencyReceiver);
    }

    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdraw stuck tokens
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (amount == 0) revert Gateway__InvalidAmount();
        IERC20Upgradeable(token).safeTransfer(emergencyReceiver, amount);
    }

    receive() external payable {}
}
