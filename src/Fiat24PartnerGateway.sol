// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/IFiat24Account.sol";
import "./interfaces/IFiat24CryptoRelay.sol";
import "./interfaces/IFiat24CryptoDepositAggregator.sol";
import "./interfaces/IBufferPool.sol";

/**
 * @title Fiat24PartnerGateway
 * @notice Delegation contract for third-party partners (e.g., exchanges) to execute 
 *         Deposit, FX, and Onramp operations on behalf of authorized users
 * @dev Each partner has their own deployed instance of this contract
 */
contract Fiat24PartnerGateway is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant CASH_OPERATOR_ROLE = keccak256("CASH_OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    // Native token marker addresses
    address public constant NATIVE_ETH = address(0);
    address public constant NATIVE_ETH_ALIAS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Parameters for deposit operation (via aggregator swap to Fiat24 token)
    struct DepositParams {
        address user;               // User's address (target Fiat24 account)
        address inputToken;         // Token to deposit (e.g., USDC, MNT)
        address outputToken;        // Target Fiat24 token (e.g., USD24, EUR24)
        uint256 amount;             // Amount of input token
        address aggregator;         // Aggregator contract for swap
        bytes swapCalldata;         // Calldata for aggregator swap
        uint256 minUsdcAmount;      // Minimum USDC after swap (slippage)
        string partnerRefId;        // Partner's reference ID for reconciliation
    }

    /// @notice Parameters for FX operation
    struct FxParams {
        address user;               // User's address
        address tokenIn;            // Input Fiat24 token (e.g., USD24)
        address tokenOut;           // Output Fiat24 token (e.g., EUR24)
        uint256 amountIn;           // Amount of input token
        uint256 minAmountOut;       // Minimum output amount (slippage protection)
        string partnerRefId;        // Partner's reference ID
    }

    /// @notice Parameters for onramp and swap operation (Fiat24 -> USDC -> target token)
    struct OnrampParams {
        address user;               // User's address (depositor)
        address receiver;           // Receiver address for output token (address(0) = user)
        address tokenIn;            // Fiat24 token to convert
        uint256 amountIn;           // Amount of Fiat24 token
        uint256 minUsdcOut;         // Minimum USDC after FX conversion
        uint256 feeAmount;          // Fee amount in USDC
        address tokenOut;           // Target output token (e.g., ETH, WBTC)
        uint256 minAmountOut;       // Minimum output after swap
        address aggregator;         // Aggregator for swap
        bytes swapCalldata;         // Calldata for aggregator
        string partnerRefId;        // Partner's reference ID
    }

    /// @notice Parameters for cross-chain onramp and bridge operation
    struct CrossChainOnrampParams {
        address user;               // User's address
        address tokenIn;            // Fiat24 token to convert
        uint256 amountIn;           // Amount of Fiat24 token
        uint256 minUsdcOut;         // Minimum USDC after FX conversion
        uint256 feeAmount;          // Fee amount in USDC (on source chain)
        uint32 dstEid;              // Destination chain endpoint ID
        address dstAggregator;      // Aggregator on destination chain
        address dstTokenOut;        // Target token on destination chain
        address dstReceiver;        // Final receiver on destination chain
        bytes dstSwapCalldata;      // Swap calldata for destination
        uint256 dstMinAmountOut;    // Minimum output on destination chain
        uint128 dstGasLimit;        // Gas limit for compose call
        uint256 bridgeMinAmount;    // Minimum USDC to receive on bridge (slippage)
        string partnerRefId;        // Partner's reference ID
    }

    /// @notice Partner identifier
    string public partnerId;
    
    /// @notice Fiat24 Account contract for user validation
    IFiat24Account public fiat24Account;
    
    /// @notice BufferPool contract for onramp operations
    IBufferPool public bufferPool;
    
    /// @notice Fiat24CryptoRelay contract for FX operations
    IFiat24CryptoRelay public fiat24CryptoRelay;
    
    /// @notice Fiat24CryptoDeposit contract for deposit operations
    IFiat24CryptoDepositAggregator public fiat24CryptoDeposit;
    
    /// @notice Supported Fiat24 tokens for FX
    mapping(address => bool) public validXXX24Tokens;

    /// @notice Emergency receiver address for stuck tokens
    address public emergencyReceiver;

    /// @notice Global switch to allow custom receiver address in onramp operations
    bool public allowCustomReceiver;

    event DelegateDepositExecuted(
        address indexed user,
        address indexed inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        string partnerRefId,
        string partnerId
    );
    event DelegateFxExecuted(
        address indexed user,
        address indexed fiatTokenIn,
        address indexed fiatTokenOut,
        uint256 fiatAmountIn,
        uint256 fiatAmountOut,
        string partnerRefId,
        string partnerId
    );
    event DelegateOnrampExecuted(
        address indexed user,
        address indexed receiver,
        address indexed fiatTokenIn,
        uint256 fiatAmountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 feeAmount,
        string partnerRefId,
        string partnerId
    );
    event DelegateOnrampAndBridgeExecuted(
        address indexed user,
        address indexed fiatTokenIn,
        uint256 fiatAmountIn,
        uint256 usdcBridged,
        uint256 feeAmount,
        uint32 dstEid,
        address dstReceiver,
        address dstTokenOut,
        string partnerRefId,
        string partnerId
    );
    event TokenSupportUpdated(address indexed token, bool oldSupported, bool newSupported);
    event BufferPoolUpdated(address oldBufferPool, address newBufferPool);
    event Fiat24CryptoRelayUpdated(address oldRelay, address newRelay);
    event Fiat24CryptoDepositUpdated(address oldDeposit, address newDeposit);
    event EmergencyReceiverUpdated(address oldReceiver, address newReceiver);
    event AllowCustomReceiverUpdated(bool oldValue, bool newValue);

    error Gateway__ZeroAddress();
    error Gateway__NoChange();
    error Gateway__AccountNotSupport();
    error Gateway__AccountNotLive();
    error Gateway__InvalidAmount();
    error Gateway__TokenNotSupported();
    error Gateway__SlippageExceeded();
    error Gateway__TransferFailed();
    error Gateway__InsufficientBalance();
    error Gateway__CustomReceiverNotAllowed();

    function initialize(
        address _admin,
        string calldata _partnerId,
        address _fiat24Account,
        address _bufferPool,
        address _fiat24CryptoRelay,
        address _fiat24CryptoDeposit,
        address _emergencyReceiver
    ) public initializer {
        if (_admin == address(0) || _fiat24Account == address(0) || _emergencyReceiver == address(0) ||
            _bufferPool == address(0) || _fiat24CryptoRelay == address(0) || _fiat24CryptoDeposit == address(0)) {
            revert Gateway__ZeroAddress();
        }

        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ADMIN_ROLE, _admin);

        partnerId = _partnerId;
        fiat24Account = IFiat24Account(_fiat24Account);
        bufferPool = IBufferPool(_bufferPool);
        fiat24CryptoRelay = IFiat24CryptoRelay(_fiat24CryptoRelay);
        fiat24CryptoDeposit = IFiat24CryptoDepositAggregator(_fiat24CryptoDeposit);
        emergencyReceiver = _emergencyReceiver;
    }

    /**
     * @notice Execute deposit on behalf of user via aggregator swap
     * @param params Deposit parameters
     */
    function delegateDeposit(DepositParams calldata params) 
        external
        nonReentrant 
        whenNotPaused 
        onlyRole(CASH_OPERATOR_ROLE)
    {
        _validateUserAccount(params.user);
        if (params.amount == 0) revert Gateway__InvalidAmount();
        if (_isNativeToken(params.inputToken)) revert Gateway__TokenNotSupported();

        // Transfer ERC20 tokens from user to this contract
        IERC20Upgradeable(params.inputToken).safeTransferFrom(
            params.user,
            address(this),
            params.amount
        );

        // Execute deposit via Fiat24CryptoDeposit.depositTokenViaAggregator
        uint256 outputAmount = _executeDeposit(params, false);

        emit DelegateDepositExecuted(
            params.user,
            params.inputToken,
            params.outputToken,
            params.amount,
            outputAmount,
            params.partnerRefId,
            partnerId
        );
    }

    /**
     * @notice Execute FX operation on behalf of user
     * @param params FX parameters
     */
    function delegateFx(FxParams calldata params) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyRole(CASH_OPERATOR_ROLE)
    {
        _validateUserAccount(params.user);
        if (params.amountIn == 0) revert Gateway__InvalidAmount();
        if (!validXXX24Tokens[params.tokenIn] || !validXXX24Tokens[params.tokenOut]) {
            revert Gateway__TokenNotSupported();
        }

        IERC20Upgradeable(params.tokenIn).safeTransferFrom(
            params.user,
            address(this),
            params.amountIn
        );

        // Execute FX swap via Fiat24CryptoRelay.moneyExchangeExactIn
        uint256 amountOut = _executeFx(params.tokenIn, params.tokenOut, params.amountIn, params.minAmountOut);

        // Transfer output tokens to user
        IERC20Upgradeable(params.tokenOut).safeTransfer(params.user, amountOut);

        emit DelegateFxExecuted(
            params.user,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            params.partnerRefId,
            partnerId
        );
    }

    /**
     * @notice Execute onramp and swap operation on behalf of user (Fiat24 token -> USDC -> target token)
     * @param params Onramp parameters including swap details
     */
    function delegateOnramp(OnrampParams calldata params)
        external
        nonReentrant
        whenNotPaused
        onlyRole(CASH_OPERATOR_ROLE)
    {
        _validateUserAccount(params.user);
        if (params.amountIn == 0) revert Gateway__InvalidAmount();
        if (!validXXX24Tokens[params.tokenIn]) revert Gateway__TokenNotSupported();

        // Determine receiver: if not specified, use user
        address receiver = params.receiver == address(0) ? params.user : params.receiver;
        
        // Check if custom receiver is allowed
        if (receiver != params.user && !allowCustomReceiver) {
            revert Gateway__CustomReceiverNotAllowed();
        }

        // Transfer Fiat24 token from user to Gateway
        IERC20Upgradeable(params.tokenIn).safeTransferFrom(
            params.user,
            address(this),
            params.amountIn
        );

        // Execute onramp and swap via BufferPool
        uint256 tokenOutAmount = _executeOnramp(params);

        // Transfer result token to receiver
        if (_isNativeToken(params.tokenOut)) {
            _safeTransferETH(receiver, tokenOutAmount);
        } else {
            IERC20Upgradeable(params.tokenOut).safeTransfer(receiver, tokenOutAmount);
        }

        emit DelegateOnrampExecuted(
            params.user,
            receiver,
            params.tokenIn,
            params.amountIn,
            params.tokenOut,
            tokenOutAmount,
            params.feeAmount,
            params.partnerRefId,
            partnerId
        );
    }

    /**
     * @notice Execute cross-chain onramp and bridge on behalf of user
     * @dev Fiat24 token -> USDC -> Stargate bridge -> destination chain swap
     * @param params Cross-chain onramp parameters
     */
    function delegateOnrampAndBridge(CrossChainOnrampParams calldata params)
        external
        payable
        nonReentrant
        whenNotPaused
        onlyRole(CASH_OPERATOR_ROLE)
    {
        _validateUserAccount(params.user);
        if (msg.value == 0 || params.amountIn == 0) revert Gateway__InvalidAmount();
        if (!validXXX24Tokens[params.tokenIn]) revert Gateway__TokenNotSupported();

         // Determine dstReceiver: if not specified, use user
        address dstReceiver = params.dstReceiver == address(0) ? params.user : params.dstReceiver;
        
        // Check if custom receiver is allowed
        if (dstReceiver != params.user && !allowCustomReceiver) {
            revert Gateway__CustomReceiverNotAllowed();
        }

        // Transfer Fiat24 token from user to Gateway
        IERC20Upgradeable(params.tokenIn).safeTransferFrom(
            params.user,
            address(this),
            params.amountIn
        );

        // Execute cross-chain onramp via BufferPool
        uint256 usdcOut = _executeOnrampAndBridge(params, dstReceiver);

        emit DelegateOnrampAndBridgeExecuted(
            params.user,
            params.tokenIn,
            params.amountIn,
            usdcOut,
            params.feeAmount,
            params.dstEid,
            dstReceiver,
            params.dstTokenOut,
            params.partnerRefId,
            partnerId
        );
    }

    function _validateUserAccount(address user) internal view {
        uint256 tokenId = fiat24Account.historicOwnership(user);
        if (tokenId == 0 || !fiat24Account.exists(tokenId)) {
            revert Gateway__AccountNotLive();
        }
        // Exclude internal accounts (9100-9199)
        if (tokenId >= 9100 && tokenId <= 9199) {
            revert Gateway__AccountNotSupport();
        }
        // Status.Live = 5
        if (fiat24Account.status(tokenId) != 5) {
            revert Gateway__AccountNotLive();
        }
    }

    function _isNativeToken(address token) internal pure returns (bool) {
        return token == NATIVE_ETH || token == NATIVE_ETH_ALIAS;
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert Gateway__TransferFailed();
    }

    function _executeDeposit(DepositParams calldata params, bool isNative) internal returns (uint256) {
        if (!isNative) {
            // Approve Fiat24CryptoDeposit contract for ERC20
            IERC20Upgradeable(params.inputToken).safeApprove(address(fiat24CryptoDeposit), 0);
            IERC20Upgradeable(params.inputToken).safeApprove(address(fiat24CryptoDeposit), params.amount);
        }

        // Call depositTokenViaAggregatorToAccount
        // For native: msg.value = amount + lzFee, passed through
        // For ERC20: msg.value = lzFee only
        uint256 outputAmount = fiat24CryptoDeposit.depositTokenViaAggregatorToAccount{value: msg.value}(
            params.user,        // Target Fiat24 account
            params.inputToken,
            params.outputToken,
            params.amount,
            params.aggregator,
            params.swapCalldata,
            params.minUsdcAmount
        );

        // Reset approval
        if (!isNative) {
            IERC20Upgradeable(params.inputToken).safeApprove(address(fiat24CryptoDeposit), 0);
        }

        return outputAmount;
    }

    function _executeFx(
        address tokenIn, 
        address tokenOut, 
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        // Approve Fiat24CryptoRelay
        IERC20Upgradeable(tokenIn).safeApprove(address(fiat24CryptoRelay), 0);
        IERC20Upgradeable(tokenIn).safeApprove(address(fiat24CryptoRelay), amountIn);


        amountOut = fiat24CryptoRelay.moneyExchangeExactIn(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut
        );

        // Reset approval
        IERC20Upgradeable(tokenIn).safeApprove(address(fiat24CryptoRelay), 0);
    }

    function _executeOnramp(OnrampParams calldata params) internal returns (uint256 tokenOutAmount) {
        // Approve BufferPool to transfer tokens from Gateway
        IERC20Upgradeable(params.tokenIn).safeApprove(address(bufferPool), 0);
        IERC20Upgradeable(params.tokenIn).safeApprove(address(bufferPool), params.amountIn);

        bool isNativeOut = _isNativeToken(params.tokenOut);

        // Get balance before
        uint256 balanceBefore = isNativeOut ? address(this).balance : IERC20Upgradeable(params.tokenOut).balanceOf(address(this));

        // Build BufferPool OnrampParams - use Gateway as user
        IBufferPool.OnrampParams memory onrampParams = IBufferPool.OnrampParams({
            user: address(this),  // Gateway receives the result
            tokenIn: params.tokenIn,
            amountIn: params.amountIn,
            minAmountOut: params.minUsdcOut,
            feeAmount: params.feeAmount
        });

        // Build BufferPool SwapParams
        IBufferPool.SwapParams memory swapParams = IBufferPool.SwapParams({
            usdcAmount: 0, // Will be set by BufferPool based on onramp output
            feeAmount: 0,  // Fee already in onrampParams
            tokenOut: params.tokenOut,
            minAmountOut: params.minAmountOut,
            aggregator: params.aggregator,
            swapCalldata: params.swapCalldata
        });

        // Call BufferPool.onrampAndSwap
        // BufferPool transfers from Gateway, sends result to Gateway
        bufferPool.onrampAndSwap(onrampParams, swapParams);

        // Reset approval
        IERC20Upgradeable(params.tokenIn).safeApprove(address(bufferPool), 0);

        // Calculate received amount
        uint256 balanceAfter = isNativeOut ? address(this).balance : IERC20Upgradeable(params.tokenOut).balanceOf(address(this));
        tokenOutAmount = balanceAfter - balanceBefore;
    }

    function _executeOnrampAndBridge(CrossChainOnrampParams calldata params, address dstReceiver) internal returns (uint256 usdcOut) {
        // Approve BufferPool to transfer tokens from Gateway
        IERC20Upgradeable(params.tokenIn).safeApprove(address(bufferPool), 0);
        IERC20Upgradeable(params.tokenIn).safeApprove(address(bufferPool), params.amountIn);

        // Build BufferPool CrossChainOnrampParams
        IBufferPool.CrossChainOnrampParams memory crossChainParams = IBufferPool.CrossChainOnrampParams({
            user: address(this),
            tokenIn: params.tokenIn,
            amountIn: params.amountIn,
            minAmountOut: params.minUsdcOut,
            feeAmount: params.feeAmount,
            dstEid: params.dstEid,
            dstAggregator: params.dstAggregator,
            dstTokenOut: params.dstTokenOut,
            dstReceiver: dstReceiver,
            dstSwapCalldata: params.dstSwapCalldata,
            dstMinAmountOut: params.dstMinAmountOut,
            dstGasLimit: params.dstGasLimit,
            bridgeMinAmount: params.bridgeMinAmount
        });

        // Get quote to return usdcOut for event
        usdcOut = bufferPool.getQuote(params.tokenIn, params.amountIn);

        // Call BufferPool.onrampAndBridge with msg.value for cross-chain fees
        bufferPool.onrampAndBridge{value: msg.value}(crossChainParams);

        // Reset approval
        IERC20Upgradeable(params.tokenIn).safeApprove(address(bufferPool), 0);
    }

    /**
     * @notice Update BufferPool address
     * @param _bufferPool New BufferPool address
     */
    function setBufferPool(address _bufferPool) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_bufferPool == address(0)) revert Gateway__ZeroAddress();
        if (_bufferPool == address(bufferPool)) revert Gateway__NoChange();
        address oldBufferPool = address(bufferPool);
        bufferPool = IBufferPool(_bufferPool);
        emit BufferPoolUpdated(oldBufferPool, _bufferPool);
    }

    /**
     * @notice Update Fiat24CryptoRelay contract address
     * @param _fiat24CryptoRelay New Fiat24CryptoRelay contract address
     */
    function setFiat24CryptoRelay(address _fiat24CryptoRelay) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_fiat24CryptoRelay == address(0)) revert Gateway__ZeroAddress();
        if (_fiat24CryptoRelay == address(fiat24CryptoRelay)) revert Gateway__NoChange();
        address oldRelay = address(fiat24CryptoRelay);
        fiat24CryptoRelay = IFiat24CryptoRelay(_fiat24CryptoRelay);
        emit Fiat24CryptoRelayUpdated(oldRelay, _fiat24CryptoRelay);
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
     * @notice Enable Fiat24 token support for FX
     * @param token Token address to enable
     */
    function enableFiat24Token(address token) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (token == address(0)) revert Gateway__ZeroAddress();
        if (validXXX24Tokens[token]) return; 
        validXXX24Tokens[token] = true;
        emit TokenSupportUpdated(token, false, true);
    }

    /**
     * @notice Disable Fiat24 token support for FX
     * @param token Token address to disable
     */
    function disableFiat24Token(address token) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (token == address(0)) revert Gateway__ZeroAddress();
        if (!validXXX24Tokens[token]) return; 
        validXXX24Tokens[token] = false;
        emit TokenSupportUpdated(token, true, false);
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
     * @param token Token to withdraw (address(0) or NATIVE_ETH_ALIAS for native ETH)
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (amount == 0) revert Gateway__InvalidAmount();
        if (_isNativeToken(token)) {
            _safeTransferETH(emergencyReceiver, amount);
        } else {
            IERC20Upgradeable(token).safeTransfer(emergencyReceiver, amount);
        }
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
     * @notice Enable or disable custom receiver address for onramp operations
     * @param _allow True to allow custom receiver, false to require receiver == user
     */
    function setAllowCustomReceiver(bool _allow) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_allow == allowCustomReceiver) revert Gateway__NoChange();
        bool oldValue = allowCustomReceiver;
        allowCustomReceiver = _allow;
        emit AllowCustomReceiverUpdated(oldValue, _allow);
    }

    receive() external payable {}
}

