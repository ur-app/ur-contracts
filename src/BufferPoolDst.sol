// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

/**
 * @title BufferPoolDst
 * @notice Destination chain contract for receiving USDC from Stargate and executing aggregator swaps
 * @dev Implements ILayerZeroComposer for Stargate V2 composed messages
 *      Reference: https://stargateprotocol.gitbook.io/stargate/v/v2-developer-docs/integrate-with-stargate/composability
 */
contract BufferPoolDst is 
    Initializable, 
    ILayerZeroComposer,
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CASH_OPERATOR_ROLE = keccak256("CASH_OPERATOR_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    struct DstSwapPayload {
        address user;           // Final recipient
        address tokenOut;       // Target output token
        uint256 minAmountOut;   // Minimum output amount (slippage protection)
        address aggregator;     // Aggregator contract (1inch, Odos, etc.)
        bytes swapCalldata;     // Swap calldata for aggregator
        address srcTokenIn;     // Source chain input token (Fiat24 token)
        uint256 srcAmountIn;    // Source chain input amount
    }

    /// @notice EIP-2612 permit signature parameters
    struct PermitParams {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Parameters for swapUsdcToToken
    struct SwapParams {
        bytes32 refId;          // Reference ID for tracking (optional, can be 0)
        address user;           // User address (source of USDC, recipient of output token)
        uint256 usdcAmount;     // Amount of USDC to swap
        uint256 feeAmount;      // Fee amount in USDC to send to feeReceiver
        address tokenOut;       // Target output token
        uint256 minAmountOut;   // Minimum output amount (slippage protection)
        address aggregator;     // Aggregator contract (must be approved)
        bytes swapCalldata;     // Calldata for aggregator (from 1inch/Odos API)
    }

    /// @notice Record of failed decode attempts for recovery
    struct FailedDecode {
        uint256 usdcAmount;
        bytes composeMsg;
        uint256 timestamp;
    }

    // Native ETH marker addresses
    address public constant NATIVE_ETH = address(0);
    address public constant NATIVE_ETH_ALIAS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    IERC20Upgradeable public usdc;

    // LayerZero endpoint (for verification)
    address public lzEndpoint;

    // Stargate USDC pool address (for verification)
    address public stargateUsdc;

    // Fee receiver address
    address public feeReceiver;

    // Aggregator whitelist for secure swap execution
    mapping(address => bool) public whitelistedAggregators;

    // Whitelisted function selectors for each aggregator (aggregator => selector => allowed)
    mapping(address => mapping(bytes4 => bool)) public whitelistedSelectors;

    // Mapping of guid => FailedDecode for recovery
    mapping(bytes32 => FailedDecode) public failedDecodes;

    event DirectSwapExecuted(
        bytes32 indexed refId,
        address indexed user,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    );

    event CrossChainSwapExecuted(
        bytes32 indexed guid,
        address indexed user,
        address srcTokenIn,
        uint256 srcAmountIn,
        uint256 usdcBridged,
        address tokenOut,
        uint256 amountOut
    );

    event CrossChainSwapFailedAndRefunded(
        bytes32 indexed guid,
        address indexed user,
        address srcTokenIn,
        uint256 srcAmountIn,
        uint256 usdcAmount,
        string reason
    );

    event DecodeFailed(
        bytes32 indexed swapId,
        uint256 usdcAmount,
        bytes composeMsg
    );

    event FailedDecodeRecovered(
        bytes32 indexed guid,
        address indexed recipient,
        uint256 usdcAmount
    );

    event AggregatorWhitelistUpdated(address indexed aggregator, bool isWhitelisted);
    event FunctionSelectorWhitelisted(address indexed aggregator, bytes4 indexed selector, bool isWhitelisted);
    event StargateUsdcUpdated(address oldStargate, address newStargate);
    event LzEndpointUpdated(address oldEndpoint, address newEndpoint);
    event FeeReceiverUpdated(address oldReceiver, address newReceiver);
    event PermitFailed(address indexed user, address indexed token, uint256 amount);

    error BufferPoolDst__ZeroAddress();              // 0x01b1b942
    error BufferPoolDst__NoChange();                 // 0x3c6c5c5f
    error BufferPoolDst__NotEndpoint();              // 0x484c1268
    error BufferPoolDst__NotStargate();              // 0x2b77b070
    error BufferPoolDst__InvalidPayload();           // 0x1c9303a9
    error BufferPoolDst__NotWhitelistedAggregator(); // 0xef86c9c8
    error BufferPoolDst__FunctionNotWhitelisted();   // 0x293248c6
    error BufferPoolDst__SwapFailed();               // 0x45c70317
    error BufferPoolDst__SlippageExceeded();         // 0x74d0ee99
    error BufferPoolDst__NativeTransferFailed();     // 0x36925928


    function initialize(
        address _admin,
        address _usdc,
        address _lzEndpoint,
        address _stargateUsdc
    ) public initializer {
        if (_admin == address(0) || _usdc == address(0) || _lzEndpoint == address(0) || _stargateUsdc == address(0)) {
            revert BufferPoolDst__ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ADMIN_ROLE, _admin);

        usdc = IERC20Upgradeable(_usdc);
        lzEndpoint = _lzEndpoint;
        stargateUsdc = _stargateUsdc;
    }

    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override nonReentrant whenNotPaused {
        // Verify caller is LayerZero endpoint
        if (msg.sender != lzEndpoint) revert BufferPoolDst__NotEndpoint();
        
        // Verify the compose call is from Stargate USDC pool
        if (_from != stargateUsdc) revert BufferPoolDst__NotStargate();

        // Decode the message using OFTComposeMsgCodec
        uint256 amountUsdcReceived = OFTComposeMsgCodec.amountLD(_message);
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // Decode payload
        DstSwapPayload memory payload;
        try this.decodePayload(composeMsg) returns (DstSwapPayload memory decoded) {
            payload = decoded;
        } catch {
            // Store failed decode for recovery
            failedDecodes[_guid] = FailedDecode({
                usdcAmount: amountUsdcReceived,
                composeMsg: composeMsg,
                timestamp: block.timestamp
            });
            emit DecodeFailed(_guid, amountUsdcReceived, composeMsg);
            return;
        }

        // Execute swap - if fails, refund USDC to user
        try this.executeSwap(_guid, payload, amountUsdcReceived) {
            // Success
        } catch {
            usdc.safeTransfer(payload.user, amountUsdcReceived);
            emit CrossChainSwapFailedAndRefunded(_guid, payload.user, payload.srcTokenIn, payload.srcAmountIn, amountUsdcReceived, "Swap execution failed");
        }
    }

    /// @notice Execute swap (external for try-catch)
    function executeSwap(
        bytes32 swapId,
        DstSwapPayload calldata payload,
        uint256 amountUsdcReceived
    ) external {
        require(msg.sender == address(this), "Only internal");
        _executeSwap(swapId, payload, amountUsdcReceived);
    }

    function _executeSwap(
        bytes32 swapId,
        DstSwapPayload memory payload,
        uint256 amountUsdcReceived
    ) internal {
        uint256 amountOut;
        bool isNativeOut = _isNativeToken(payload.tokenOut);

        // If tokenOut is USDC, skip swap and transfer directly
        if (payload.tokenOut == address(usdc)) {
            if (amountUsdcReceived < payload.minAmountOut) revert BufferPoolDst__SlippageExceeded();
            usdc.safeTransfer(payload.user, amountUsdcReceived);
            amountOut = amountUsdcReceived;
        } else {
            if (!whitelistedAggregators[payload.aggregator]) revert BufferPoolDst__NotWhitelistedAggregator();

            // Validate function selector
            bytes4 selector = bytes4(payload.swapCalldata);
            if (!whitelistedSelectors[payload.aggregator][selector]) revert BufferPoolDst__FunctionNotWhitelisted();

            // Track balance before - for native token, track ETH balance directly
            uint256 balanceBefore = isNativeOut ? address(this).balance : _getTokenBalance(payload.tokenOut);

            usdc.safeApprove(payload.aggregator, 0);
            usdc.safeApprove(payload.aggregator, amountUsdcReceived);

            (bool success,) = payload.aggregator.call(payload.swapCalldata);

            usdc.safeApprove(payload.aggregator, 0);
            
            if (!success) revert BufferPoolDst__SwapFailed();

            // Calculate output amount
            uint256 balanceAfter = isNativeOut ? address(this).balance : _getTokenBalance(payload.tokenOut);
            amountOut = balanceAfter - balanceBefore;

            // Check slippage
            if (amountOut < payload.minAmountOut) revert BufferPoolDst__SlippageExceeded();

            // Transfer output token to user
            if (isNativeOut) {
                _safeTransferETH(payload.user, amountOut);
            } else {
                IERC20Upgradeable(payload.tokenOut).safeTransfer(payload.user, amountOut);
            }
        }

        emit CrossChainSwapExecuted(
            swapId,
            payload.user,
            payload.srcTokenIn,
            payload.srcAmountIn,
            amountUsdcReceived,
            payload.tokenOut,
            amountOut
        );
    }

    function _getTokenBalance(address token) internal view returns (uint256) {
        if (_isNativeToken(token)) {
            return address(this).balance;
        }
        return IERC20Upgradeable(token).balanceOf(address(this));
    }

    /// @notice Check if token address represents native ETH
    function _isNativeToken(address token) internal pure returns (bool) {
        return token == NATIVE_ETH || token == NATIVE_ETH_ALIAS;
    }

    /// @notice Safely transfer native ETH to recipient
    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert BufferPoolDst__NativeTransferFailed();
    }

    /**
     * @notice Swap USDC to any token via approved aggregator
     * @dev User calls this directly. User must approve USDC to this contract first.
     * @param params Swap parameters
     */
    function swapUsdcToToken(SwapParams calldata params) external nonReentrant whenNotPaused {
        require(params.user == msg.sender, "User must be msg.sender");
        _executeUserSwap(params);
    }

    /**
     * @notice Swap USDC to any token via approved aggregator with permit
     * @dev User calls this directly. Uses EIP-2612 permit for gasless approval.
     * @param params Swap parameters
     * @param permit Permit signature parameters
     */
    function permitAndSwapUsdcToToken(
        SwapParams calldata params,
        PermitParams calldata permit
    ) external nonReentrant whenNotPaused onlyRole(CASH_OPERATOR_ROLE) {
        // Execute permit (with try-catch for already approved cases)
        try IERC20PermitUpgradeable(address(usdc)).permit(
            params.user, address(this), params.usdcAmount,
            permit.deadline, permit.v, permit.r, permit.s
        ) {} catch {
            emit PermitFailed(params.user, address(usdc), params.usdcAmount);
        }

        _executeUserSwap(params);
    }

    /**
     * @notice Internal function to execute user swap
     * @param params Swap parameters
     */
    function _executeUserSwap(SwapParams calldata params) internal {
        if (params.usdcAmount == 0 || params.usdcAmount <= params.feeAmount) revert BufferPoolDst__InvalidPayload();
        if (!whitelistedAggregators[params.aggregator]) revert BufferPoolDst__NotWhitelistedAggregator();
        
        bytes4 selector = bytes4(params.swapCalldata);
        if (!whitelistedSelectors[params.aggregator][selector]) revert BufferPoolDst__FunctionNotWhitelisted();

        bool isNativeOut = _isNativeToken(params.tokenOut);

        // Transfer total USDC from user
        usdc.safeTransferFrom(params.user, address(this), params.usdcAmount);

        // Transfer fee to feeReceiver
        if (params.feeAmount > 0 && feeReceiver != address(0)) {
            usdc.safeTransfer(feeReceiver, params.feeAmount);
        }

        // Calculate actual swap amount after fee
        uint256 swapAmount = params.usdcAmount - params.feeAmount;

        // Get balance before - for native token, track ETH balance directly
        uint256 balanceBefore = isNativeOut ? address(this).balance : _getTokenBalance(params.tokenOut);

        // Approve USDC to aggregator
        usdc.safeApprove(params.aggregator, 0);
        usdc.safeApprove(params.aggregator, swapAmount);

        // Execute swap via aggregator
        (bool success,) = params.aggregator.call(params.swapCalldata);
        if (!success) revert BufferPoolDst__SwapFailed();

        // Reset approval
        usdc.safeApprove(params.aggregator, 0);

        // Calculate output amount
        uint256 balanceAfter = isNativeOut ? address(this).balance : _getTokenBalance(params.tokenOut);
        uint256 amountOut = balanceAfter - balanceBefore;

        // Check slippage
        if (amountOut < params.minAmountOut) revert BufferPoolDst__SlippageExceeded();

        // Transfer output token to user
        if (isNativeOut) {
            _safeTransferETH(params.user, amountOut);
        } else {
            IERC20Upgradeable(params.tokenOut).safeTransfer(params.user, amountOut);
        }

        emit DirectSwapExecuted(params.refId, params.user, address(usdc), swapAmount, params.tokenOut, amountOut);
    }

    /**
     * @notice Add or remove aggregator from whitelist
     * @param _aggregator The aggregator contract address
     * @param _isWhitelisted True to whitelist, false to remove
     */
    function setAggregatorWhitelist(
        address _aggregator,
        bool _isWhitelisted
    ) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_aggregator != address(0), "Invalid aggregator address");
        if (_isWhitelisted == whitelistedAggregators[_aggregator]) revert BufferPoolDst__NoChange();
        whitelistedAggregators[_aggregator] = _isWhitelisted;
        emit AggregatorWhitelistUpdated(_aggregator, _isWhitelisted);
    }

    /**
     * @notice Add or remove function selector for a specific aggregator
     * @param _aggregator The aggregator contract address
     * @param _selector The function selector (first 4 bytes of function signature)
     * @param _isWhitelisted True to whitelist, false to remove
     */
    function setFunctionSelector(
        address _aggregator,
        bytes4 _selector,
        bool _isWhitelisted
    ) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_aggregator != address(0), "Invalid aggregator address");
        require(_selector != bytes4(0), "Invalid selector");
        require(whitelistedAggregators[_aggregator], "Aggregator not whitelisted");
        if (_isWhitelisted == whitelistedSelectors[_aggregator][_selector]) revert BufferPoolDst__NoChange();
        whitelistedSelectors[_aggregator][_selector] = _isWhitelisted;
        emit FunctionSelectorWhitelisted(_aggregator, _selector, _isWhitelisted);
    }

    /**
     * @notice Update Stargate USDC pool address
     * @param _stargateUsdc New Stargate USDC address
     */
    function setStargateUsdc(address _stargateUsdc) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_stargateUsdc == address(0)) revert BufferPoolDst__ZeroAddress();
        if (_stargateUsdc == stargateUsdc) revert BufferPoolDst__NoChange();
        address oldStargate = stargateUsdc;
        stargateUsdc = _stargateUsdc;
        emit StargateUsdcUpdated(oldStargate, _stargateUsdc);
    }

    /**
     * @notice Update LayerZero endpoint address
     * @param _lzEndpoint New endpoint address
     */
    function setLzEndpoint(address _lzEndpoint) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_lzEndpoint == address(0)) revert BufferPoolDst__ZeroAddress();
        if (_lzEndpoint == lzEndpoint) revert BufferPoolDst__NoChange();
        address oldEndpoint = lzEndpoint;
        lzEndpoint = _lzEndpoint;
        emit LzEndpointUpdated(oldEndpoint, _lzEndpoint);
    }

    /**
     * @notice Update fee receiver address
     * @param _feeReceiver New fee receiver address
     */
    function setFeeReceiver(address _feeReceiver) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (_feeReceiver == address(0)) revert BufferPoolDst__ZeroAddress();
        if (_feeReceiver == feeReceiver) revert BufferPoolDst__NoChange();
        address oldReceiver = feeReceiver;
        feeReceiver = _feeReceiver;
        emit FeeReceiverUpdated(oldReceiver, _feeReceiver);
    }

    /**
     * @notice Recover USDC from failed decode attempts
     * @param guid The guid of the failed decode
     * @param recipient Address to receive the recovered USDC
     */
    function recoverFailedDecode(bytes32 guid, address recipient) external onlyRole(OPERATOR_ROLE) {
        if (recipient == address(0)) revert BufferPoolDst__ZeroAddress();
        
        FailedDecode memory failed = failedDecodes[guid];
        
        // Delete the record before transfer
        delete failedDecodes[guid];
        
        if (failed.usdcAmount == 0) {
            emit FailedDecodeRecovered(guid, recipient, 0);
            return;
        }
        
        usdc.safeTransfer(recipient, failed.usdcAmount);
        
        emit FailedDecodeRecovered(guid, recipient, failed.usdcAmount);
    }

    /**
     * @notice Withdraw stuck tokens or native ETH (emergency)
     * @param token Token to withdraw (address(0) or NATIVE_ETH_ALIAS for native ETH)
     * @param to Recipient
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(OPERATOR_ADMIN_ROLE) {
        if (to == address(0)) revert BufferPoolDst__ZeroAddress();
        if (_isNativeToken(token)) {
            _safeTransferETH(to, amount);
        } else {
            IERC20Upgradeable(token).safeTransfer(to, amount);
        }
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
     * @notice Decode payload (external for try/catch)
     * @param data Encoded payload
     * @return payload Decoded payload
     */
    function decodePayload(bytes calldata data) external pure returns (DstSwapPayload memory payload) {
        payload = abi.decode(data, (DstSwapPayload));
    }

    /**
     * @notice Check if aggregator is whitelisted
     * @param _aggregator Aggregator address
     * @return isWhitelisted Whether whitelisted
     */
    function isAggregatorWhitelisted(address _aggregator) external view returns (bool) {
        return whitelistedAggregators[_aggregator];
    }

    /**
     * @notice Check if selector is whitelisted for aggregator
     * @param _aggregator Aggregator address
     * @param _selector Function selector
     * @return isWhitelisted Whether whitelisted
     */
    function isSelectorWhitelisted(address _aggregator, bytes4 _selector) external view returns (bool) {
        return whitelistedSelectors[_aggregator][_selector];
    }

    receive() external payable {}
}
