// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IPeripheryPaymentsWithFee.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {ICrossChainMessenger} from "./interfaces/ICrossChainMessenger.sol";
import "./interfaces/IFiat24CryptoDeposit.sol";
import "./libraries/DigitsOfUint.sol";
import "./Fiat24CryptoRelay.sol";
import { OApp } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OAppOptionsType3Upgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/libs/OAppOptionsType3Upgradeable.sol";


contract Fiat24CryptoDeposit2 is OAppUpgradeable,OAppOptionsType3Upgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable,IFiat24CryptoDeposit {
    using SafeMath for uint256;
    using DigitsOfUint for uint256;
    using OptionsBuilder for bytes;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CASH_OPERATOR_ROLE = keccak256("CASH_OPERATOR_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");


    //Pancake ADDRESSES BSC MAINNET
    address public constant UNISWAP_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address public constant UNISWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address public constant UNISWAP_PERIPHERY_PAYMENTS = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address public constant UNISWAP_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 public constant MAX_DIGITS = 5;
    uint256 public constant MAX_FEE_AMOUNT_USDC = 5_000_000;
    uint256 public constant MAX_RETRY_COUNT = 3;

    address public usdc;
    address public weth;

    uint128 public relay_gas_limit;

    //Max and min USDC top-up amount
    uint256 public maxUsdcDepositAmount;
    uint256 public minUsdcDepositAmount;

    mapping(address => bool) public validXXX24Tokens;

    address public usdcDepositAddress;
    address public feeReceiver;

    address public cnh24;
    uint32 public dstId;

    mapping(bytes32 => FailedRefund) public failedMessages;

    // Aggregator whitelist for secure swap execution
    mapping(address => bool) public whitelistedAggregators;

    // Whitelisted function selectors for each aggregator (aggregator => selector => allowed)
    mapping(address => mapping(bytes4 => bool)) public whitelistedSelectors;

    event FeeReceiverChanged(address indexed oldFeeReceiver, address indexed newFeeReceiver);
    event AggregatorWhitelistUpdated(address indexed aggregator, bool isWhitelisted);
    event FunctionSelectorWhitelisted(address indexed aggregator, bytes4 indexed selector, bool isWhitelisted);
    event SentDepositedTokenViaAggregator(address indexed sender, address indexed inputToken, address indexed outputToken, uint256 inputAmount, uint256 usdcAmount, address aggregator);

    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(
        address admin,
        address _delegate,
        address _usd24,
        address _eur24,
        address _chf24,
        address _cnh24,
        address _usdc,
        address _weth,
        address _usdcDepositAddress,
        address _feeReceiver,
        uint32 _dstId
    ) public initializer {

        require(admin != address(0), "admin is zero");
        require(_delegate != address(0), "delegate is zero");
        require(_usd24 != address(0), "usd24 is zero");
        require(_eur24 != address(0), "eur24 is zero");
        require(_chf24 != address(0), "chf24 is zero");
        require(_cnh24 != address(0), "cnh24 is zero");
        require(_usdc != address(0), "usdc is zero");
        require(_weth != address(0), "weth is zero");
        require(_usdcDepositAddress != address(0), "usdcDepositAddress is zero");
        require(_feeReceiver != address(0), "_feeReceiver is zero");

        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init();
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ROLE, admin);
        __OApp_init(_delegate);
        __Ownable_init();
        _transferOwnership(admin);
        usdc = _usdc;
        weth = _weth;
        usdcDepositAddress = _usdcDepositAddress;
        feeReceiver = _feeReceiver;
        maxUsdcDepositAmount = 50000000000;
        minUsdcDepositAmount = 3000000;
        relay_gas_limit = 500000;
        dstId = _dstId;
        validXXX24Tokens[_cnh24] = true;
        validXXX24Tokens[_usd24] = true;
        validXXX24Tokens[_eur24] = true;
        validXXX24Tokens[_chf24] = true;
    }


    // Deposit ETH, convert to USDC, send cross-chain message using LayerZero OApp
    function depositETH(address _outputToken, uint256 nativeFee, uint256 _amountOutMinimum) nonReentrant external payable returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (msg.value == 0) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);

        uint256 amountIn = msg.value - nativeFee;
        uint256 usdcAmount = _swapToUsdc(weth, amountIn, _amountOutMinimum, true);

        if (usdcAmount > maxUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountHigherMaxDepositAmount(usdcAmount, maxUsdcDepositAmount);
        if (usdcAmount < minUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountLowerMinDepositAmount(usdcAmount, minUsdcDepositAmount);

        TransferHelper.safeTransfer(usdc, usdcDepositAddress, usdcAmount);
        _sendLayerZeroMessage(_msgSender(), address(0), amountIn, usdcAmount, _outputToken, nativeFee, payable(msg.sender));

        emit SentDepositedEth(_msgSender(), weth, _outputToken, amountIn, usdcAmount);
        return usdcAmount;
    }

    // Deposit token via USDC, swap to target token and send cross-chain message
    function depositTokenViaUsdc(address _inputToken, address _outputToken, uint256 _amount, uint256 _amountOutMinimum) nonReentrant payable external returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (_amount == 0) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);

        TransferHelper.safeTransferFrom(_inputToken, _msgSender(), address(this), _amount);
        uint256 usdcAmount = _swapToUsdc(_inputToken, _amount, _amountOutMinimum, false);

        if (usdcAmount > maxUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountHigherMaxDepositAmount(usdcAmount, maxUsdcDepositAmount);
        if (usdcAmount < minUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountLowerMinDepositAmount(usdcAmount, minUsdcDepositAmount);

        TransferHelper.safeTransfer(usdc, usdcDepositAddress, usdcAmount);
        _sendLayerZeroMessage(_msgSender(), _inputToken, _amount, usdcAmount, _outputToken, msg.value, payable(msg.sender));

        emit SentDepositedTokenViaUsd(_msgSender(), _inputToken, _outputToken, _amount, usdcAmount);
        return usdcAmount;
    }

    /// @notice Deposit token via aggregator (1inch, odos, etc.), swap to USDC and send cross-chain message
    /// @param _inputToken The token to deposit (address(0) for ETH)
    /// @param _outputToken The target fiat24 token (EUR24, USD24, etc.)
    /// @param _amount The amount of input token to deposit (for ETH, this is the ETH amount to swap, msg.value = _amount + lzFee)
    /// @param _aggregator The whitelisted aggregator contract address
    /// @param _swapCalldata The calldata for the aggregator swap
    /// @param _minUsdcAmount The minimum acceptable USDC amount after swap
    /// @param _feeAmountViaUsdc The fee amount in USDC to charge
    function depositTokenViaAggregator(
        address _inputToken,
        address _outputToken,
        uint256 _amount,
        address _aggregator,
        bytes calldata _swapCalldata,
        uint256 _minUsdcAmount,
        uint256 _feeAmountViaUsdc
    ) nonReentrant payable external returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (_amount == 0) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);

        address sender = _msgSender();
        uint256 lzFee;

        // Handle ETH deposit
        if (_inputToken == address(0) || _inputToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            if (msg.value <= _amount) revert Fiat24CryptoDeposit__ValueZero();
            lzFee = msg.value - _amount;
            // ETH is already in msg.value, will be used in swap
        } else {
            if (msg.value == 0) revert Fiat24CryptoDeposit__ValueZero();  // Validate LayerZero fee
            lzFee = msg.value;
            TransferHelper.safeTransferFrom(_inputToken, sender, address(this), _amount);
        }

        uint256 usdcFactAmount;
        {
            uint256 usdcAmount = _swapViaAggregator(_inputToken, _amount, _aggregator, _swapCalldata, _minUsdcAmount);
            usdcFactAmount = _processFeeAndValidation(usdcAmount, _feeAmountViaUsdc);
            TransferHelper.safeTransfer(usdc, usdcDepositAddress, usdcFactAmount);
        }

        _sendLayerZeroMessage(sender, _inputToken, _amount, usdcFactAmount, _outputToken, lzFee, payable(feeReceiver));

        emit SentDepositedTokenViaAggregator(sender, _inputToken, _outputToken, _amount, usdcFactAmount, _aggregator);
        return usdcFactAmount;
    }

    /// @notice Deposit token via aggregator to another account owned by the sender
    /// @param _targetAccount The target Fiat24 account address to deposit to
    /// @param _inputToken The token to deposit (address(0) for ETH)
    /// @param _outputToken The target fiat24 token (EUR24, USD24, etc.)
    /// @param _amount The amount of input token to deposit (for ETH, msg.value = _amount + lzFee)
    /// @param _aggregator The whitelisted aggregator contract address
    /// @param _swapCalldata The calldata for the aggregator swap
    /// @param _minUsdcAmount The minimum acceptable USDC amount after swap
    function depositTokenViaAggregatorToAccount(
        address _targetAccount,
        address _inputToken,
        address _outputToken,
        uint256 _amount,
        address _aggregator,
        bytes calldata _swapCalldata,
        uint256 _minUsdcAmount
    ) nonReentrant payable external returns (uint256) {
        if (_amount == 0 || msg.value == 0) revert Fiat24CryptoDeposit__ValueZero();
        _validateDepositToAccountParams(_targetAccount, _outputToken);

        address sender = _msgSender();
        uint256 lzFee;

        // Handle ETH deposit
        if (_inputToken == address(0) || _inputToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            if (msg.value <= _amount) revert Fiat24CryptoDeposit__ValueZero();
            lzFee = msg.value - _amount;
            // ETH is already in msg.value, will be used in swap
        } else {
            lzFee = msg.value;
            TransferHelper.safeTransferFrom(_inputToken, sender, address(this), _amount);
        }

        uint256 usdcAmount = _swapViaAggregator(_inputToken, _amount, _aggregator, _swapCalldata, _minUsdcAmount);

        if (usdcAmount == 0) revert Fiat24CryptoDeposit__SwapOutputAmountZero();

        // Process deposit to account via LayerZero
        _processDepositToAccountLayerZero(_targetAccount, _inputToken, _amount, usdcAmount, _outputToken, lzFee);

        emit SentDepositedTokenViaUsd(_targetAccount, _inputToken, _outputToken, _amount, usdcAmount);
        emit DepositToAccount(sender, _targetAccount, _inputToken, _amount);
        return usdcAmount;
    }

//    // Deposit ETH to another account owned by the sender
//    function depositETHToAccount(address _targetAccount, address _outputToken, uint256 nativeFee, uint256 _amountOutMinimum) nonReentrant external payable returns (uint256) {
//        if (msg.value == 0) revert Fiat24CryptoDeposit__ValueZero();
//        _validateDepositToAccountParams(_targetAccount, _outputToken);
//
//        uint256 amountIn = msg.value - nativeFee;
//        uint256 usdcAmount = _swapToUsdc(weth, amountIn, _amountOutMinimum, true);
//
//        _processDepositToAccountLayerZero(_targetAccount, address(0), amountIn, usdcAmount, _outputToken, nativeFee);
//        emit SentDepositedEth(_targetAccount, weth, _outputToken, amountIn, usdcAmount);
//        emit DepositToAccount(_msgSender(),_targetAccount, weth, amountIn);
//        return usdcAmount;
//    }
//
//    // Deposit token to another account owned by the sender
//    function depositTokenViaUsdcToAccount(address _targetAccount, address _inputToken, address _outputToken, uint256 _amount, uint256 _amountOutMinimum) nonReentrant payable external returns (uint256) {
//        if (_amount == 0 || msg.value == 0) revert Fiat24CryptoDeposit__ValueZero();
//        _validateDepositToAccountParams(_targetAccount, _outputToken);
//
//        TransferHelper.safeTransferFrom(_inputToken, _msgSender(), address(this), _amount);
//        uint256 usdcAmount = _swapToUsdc(_inputToken, _amount, _amountOutMinimum, false);
//
//        _processDepositToAccountLayerZero(_targetAccount, _inputToken, _amount, usdcAmount, _outputToken, msg.value);
//        emit SentDepositedTokenViaUsd(_targetAccount, _inputToken, _outputToken, _amount, usdcAmount);
//        emit DepositToAccount(_msgSender(),_targetAccount, _inputToken, _amount);
//        return usdcAmount;
//    }

    function permitAndDepositTokenViaUsdc(
        address userAddress,
        address _inputToken,
        address _outputToken,
        uint256 _amount,
        uint256 _amountOutMinimum,
        uint256 _feeAmountViaUsdc,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external nonReentrant payable returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (!hasRole(CASH_OPERATOR_ROLE, _msgSender())) revert Fiat24Token__NotCashOperator(_msgSender());
        if (_amount == 0) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);

        try IERC20PermitUpgradeable(_inputToken).permit(
            userAddress,
            address(this),
            _amount,
            _deadline,
            _v, _r, _s
        ) {
        } catch {
            emit PermitFailed(userAddress, _inputToken, _amount);
        }

        TransferHelper.safeTransferFrom(_inputToken, userAddress, address(this), _amount);
        uint256 usdcAmount = _swapToUsdc(_inputToken, _amount, _amountOutMinimum, false);

        uint256 usdcFactAmount = _processFeeAndValidation(usdcAmount, _feeAmountViaUsdc);
        TransferHelper.safeTransfer(usdc, usdcDepositAddress, usdcFactAmount);

        _sendLayerZeroMessage(userAddress, _inputToken, _amount, usdcFactAmount, _outputToken, msg.value, payable(msg.sender));

        emit SentDepositedTokenViaUsd(userAddress, _inputToken, _outputToken, _amount, usdcFactAmount);
        return usdcFactAmount;
    }

    /**
     * @notice Quotes the gas needed to pay for the full omnichain transaction in native gas.
     */
    function quoteLayerzeroFee(
        uint32 _dstEid,
        address _userAddress,
        address _inputToken,
        uint256 _inputAmount,
        uint256 _usdcAmount,
        address _outputToken
    ) public view returns (MessagingFee memory fee) {
        bytes memory payload = abi.encode(
            _userAddress,
            _inputToken,
            _inputAmount,
            _usdcAmount,
            _outputToken
        );

        bytes memory defaultWorkerOptions = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(relay_gas_limit, 0);

        fee = _quote(_dstEid, payload, defaultWorkerOptions, false);
    }


//    function getQuote(address _inputToken, address _outputToken, uint24 _fee, uint256 _amount) public returns (uint256) {
//        return IQuoter(UNISWAP_QUOTER).quoteExactInputSingle(_inputToken, _outputToken, _fee, _amount, 0);
//    }

    function getPoolFeeOfMostLiquidPool(address _inputToken, address _outputToken) public view returns (uint24) {
        uint24 feeOfMostLiquidPool = 0;
        uint128 highestLiquidity = 0;
        uint128 liquidity;
        IUniswapV3Pool pool;
        address poolAddress = IUniswapV3Factory(UNISWAP_FACTORY).getPool(_inputToken, _outputToken, 100);
        if (poolAddress != address(0)) {
            pool = IUniswapV3Pool(poolAddress);
            liquidity = pool.liquidity();
            if (liquidity > highestLiquidity) {
                highestLiquidity = liquidity;
                feeOfMostLiquidPool = 100;
            }
        }
        poolAddress = IUniswapV3Factory(UNISWAP_FACTORY).getPool(_inputToken, _outputToken, 500);
        if (poolAddress != address(0)) {
            pool = IUniswapV3Pool(poolAddress);
            liquidity = pool.liquidity();
            if (liquidity > highestLiquidity) {
                highestLiquidity = liquidity;
                feeOfMostLiquidPool = 500;
            }
        }
        poolAddress = IUniswapV3Factory(UNISWAP_FACTORY).getPool(_inputToken, _outputToken, 3000);
        if (poolAddress != address(0)) {
            pool = IUniswapV3Pool(poolAddress);
            liquidity = pool.liquidity();
            if (liquidity > highestLiquidity) {
                highestLiquidity = liquidity;
                feeOfMostLiquidPool = 3000;
            }
        }
        poolAddress = IUniswapV3Factory(UNISWAP_FACTORY).getPool(_inputToken, _outputToken, 10000);
        if (poolAddress != address(0)) {
            pool = IUniswapV3Pool(poolAddress);
            liquidity = pool.liquidity();
            if (liquidity > highestLiquidity) {
                highestLiquidity = liquidity;
                feeOfMostLiquidPool = 10000;
            }
        }
        return feeOfMostLiquidPool;
    }

    function withdrawETH(address payable to, uint256 amount) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(to != address(0), "Invalid recipient");
        require(address(this).balance >= amount, "Insufficient ETH balance");

        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH withdrawal failed");
    }

    function changeMaxUsdcDepositAmount(uint256 _maxUsdcDepositAmount) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_maxUsdcDepositAmount >= minUsdcDepositAmount, "Max must be >= min");
        maxUsdcDepositAmount = _maxUsdcDepositAmount;
    }

    function changeMinUsdcDepositAmount(uint256 _minUsdcDepositAmount) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_minUsdcDepositAmount <= maxUsdcDepositAmount, "Min must be <= max");
        minUsdcDepositAmount = _minUsdcDepositAmount;
    }

    function changeUsdcAddress(address _usdcAddress) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_usdcAddress != address(0), "Invalid usdc address");
        usdc = _usdcAddress;
    }

    function changeUsdcDepositAddress(address _usdcDepositAddress) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        address oldUsdcDepositAddress = usdcDepositAddress;
        usdcDepositAddress = _usdcDepositAddress;
        emit UsdcDepositAddressChanged(oldUsdcDepositAddress, usdcDepositAddress);
    }

    function setFeeReceiver(address _feeReceiver) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_feeReceiver != address(0), "Invalid fee receiver address");
        address oldFeeReceiver = feeReceiver;
        feeReceiver = _feeReceiver;
        emit FeeReceiverChanged(oldFeeReceiver, feeReceiver);
    }

    function setRelayGasLimit(uint128 _newLimit) external {
        require(_newLimit > 0, "Gas limit must be positive");
        if (!hasRole(OPERATOR_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperator(_msgSender());
        relay_gas_limit = _newLimit;
    }

    /// @notice Add or remove aggregator from whitelist
    /// @param _aggregator The aggregator contract address
    /// @param _isWhitelisted True to whitelist, false to remove
    /// @dev Only OPERATOR_ADMIN_ROLE can manage aggregator whitelist
    function setAggregatorWhitelist(address _aggregator, bool _isWhitelisted) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_aggregator != address(0), "Invalid aggregator address");
        whitelistedAggregators[_aggregator] = _isWhitelisted;
        emit AggregatorWhitelistUpdated(_aggregator, _isWhitelisted);
    }

    /// @notice Add or remove function selector for a specific aggregator
    /// @param _aggregator The aggregator contract address
    /// @param _selector The function selector (first 4 bytes of function signature)
    /// @param _isWhitelisted True to whitelist, false to remove
    function setFunctionSelector(address _aggregator, bytes4 _selector, bool _isWhitelisted) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_aggregator != address(0), "Invalid aggregator address");
        require(_selector != bytes4(0), "Invalid selector");
        require(whitelistedAggregators[_aggregator], "Aggregator not whitelisted");
        whitelistedSelectors[_aggregator][_selector] = _isWhitelisted;
        emit FunctionSelectorWhitelisted(_aggregator, _selector, _isWhitelisted);
    }

    /// @notice Add a token in validXXX24Tokens
    /// @param _fiatToken The address of the Token to be added.
    function addFiatToken(address _fiatToken) external {

        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());

        require(_fiatToken != address(0), "Zero address");
        require(!validXXX24Tokens[_fiatToken], "Already exists token");
        validXXX24Tokens[_fiatToken] = true;
        emit FiatTokenAdded(_fiatToken);
    }

    function pause() external {
        if (!(hasRole(PAUSE_ROLE, _msgSender()))) revert Fiat24CryptoDeposit__NotPauser(_msgSender());
        _pause();
    }

    function unpause() external {
        if (!(hasRole(UNPAUSE_ROLE, _msgSender()))) revert Fiat24CryptoDeposit__NotUnpauser(_msgSender());
        _unpause();
    }

    function _lzReceive(
        Origin calldata /*_origin*/,
        bytes32 /*_guid*/,
        bytes calldata /*payload*/,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
    }

    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        return _nativeFee;
    }

    // Internal function to validate common parameters for deposit to account
    function _validateDepositToAccountParams(address _targetAccount, address _outputToken) internal view {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (_targetAccount == address(0)) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);
    }

    /// @notice Internal function to swap tokens to USDC via Uniswap
    /// @param _inputToken The input token address (WETH for ETH swaps, ERC20 address for token swaps)
    /// @param _amount The input token amount
    /// @param _amountOutMinimum The minimum USDC amount expected
    /// @param _isETH True if swapping ETH, false for ERC20 tokens
    /// @return usdcAmount The actual USDC amount received
    function _swapToUsdc(
        address _inputToken,
        uint256 _amount,
        uint256 _amountOutMinimum,
        bool _isETH
    ) internal returns (uint256 usdcAmount) {
        // If input is USDC, return as is
        if (_inputToken == usdc) {
            return _amount;
        }

        uint24 poolFee = getPoolFeeOfMostLiquidPool(_inputToken, usdc);
        if (poolFee == 0) revert Fiat24CryptoDeposit__NoPoolAvailable(_inputToken, usdc);

        if (!_isETH) {
            TransferHelper.safeApprove(_inputToken, UNISWAP_ROUTER, _amount);
        }

        // Setup swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _inputToken,
            tokenOut: usdc,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: _amount,
            amountOutMinimum: _amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        // Execute swap
        if (_isETH) {
            usdcAmount = ISwapRouter(UNISWAP_ROUTER).exactInputSingle{value: _amount}(params);
            if (usdcAmount == 0) revert Fiat24CryptoDeposit__SwapOutputAmountZero();
            // Refund excess ETH
            uint256 beforeBalance = address(this).balance;
            IPeripheryPaymentsWithFee(UNISWAP_PERIPHERY_PAYMENTS).refundETH();
            uint256 refundAmount = address(this).balance - beforeBalance;
            if (refundAmount > 0) {
                (bool success, ) = msg.sender.call{value: refundAmount}("");
                if (!success) revert Fiat24CryptoDeposit__EthRefundFailed();
            }
        } else {
            usdcAmount = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params);
            if (usdcAmount == 0) revert Fiat24CryptoDeposit__SwapOutputAmountZero();
        }

        return usdcAmount;
    }

    /// @notice Internal function to swap tokens via aggregator
    /// @param _inputToken The input token address (address(0) for ETH)
    /// @param _amount The input token amount
    /// @param _aggregator The aggregator contract address
    /// @param _swapCalldata The swap calldata
    /// @param _minUsdcAmount The minimum USDC amount expected
    /// @return usdcAmount The actual USDC amount received
    function _swapViaAggregator(
        address _inputToken,
        uint256 _amount,
        address _aggregator,
        bytes calldata _swapCalldata,
        uint256 _minUsdcAmount
    ) internal returns (uint256 usdcAmount) {

        if (_inputToken == usdc) {
            return _amount;
        }

        // Validate aggregator and function selector
        if (!whitelistedAggregators[_aggregator]) revert Fiat24CryptoDeposit__NotWhitelistedAggregator(_aggregator);
        if (_swapCalldata.length < 4) revert Fiat24CryptoDeposit__InvalidCalldata();

        bytes4 selector = bytes4(_swapCalldata[0:4]);
        if (!whitelistedSelectors[_aggregator][selector]) revert Fiat24CryptoDeposit__FunctionNotWhitelisted(selector);

        uint256 usdcBalanceBefore = IERC20Upgradeable(usdc).balanceOf(address(this));

        if (_inputToken == address(0) || _inputToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            (bool success, ) = _aggregator.call{value: _amount}(_swapCalldata);
            if (!success) revert Fiat24CryptoDeposit__AggregatorSwapFailed();
        } else {
            // For ERC20 tokens, approve and call
            TransferHelper.safeApprove(_inputToken, _aggregator, _amount);
            (bool success, ) = _aggregator.call(_swapCalldata);
            if (!success) revert Fiat24CryptoDeposit__AggregatorSwapFailed();
            TransferHelper.safeApprove(_inputToken, _aggregator, 0);
        }

        uint256 usdcBalanceAfter = IERC20Upgradeable(usdc).balanceOf(address(this));
        usdcAmount = usdcBalanceAfter - usdcBalanceBefore;

        // Validate user-specified minimum amount
        if (usdcAmount < _minUsdcAmount) revert Fiat24CryptoDeposit__SlippageExceeded(usdcAmount, _minUsdcAmount);

        return usdcAmount;
    }

    /// @notice Internal function to process fee and validate deposit amounts
    /// @param _usdcAmount The total USDC amount before fee
    /// @param _feeAmountViaUsdc The fee amount to charge
    /// @return usdcFactAmount The final USDC amount after fee deduction
    function _processFeeAndValidation(
        uint256 _usdcAmount,
        uint256 _feeAmountViaUsdc
    ) internal returns (uint256 usdcFactAmount) {
        if (_feeAmountViaUsdc >= MAX_FEE_AMOUNT_USDC) {
            _feeAmountViaUsdc = MAX_FEE_AMOUNT_USDC;
        }

        if (_feeAmountViaUsdc >= _usdcAmount) {
            revert Fiat24CryptoDeposit__FeeAmountExceedsOutput(_feeAmountViaUsdc, _usdcAmount);
        }

        usdcFactAmount = _usdcAmount - _feeAmountViaUsdc;

        if (usdcFactAmount > maxUsdcDepositAmount) {
            revert Fiat24CryptoDeposit__UsdcAmountHigherMaxDepositAmount(usdcFactAmount, maxUsdcDepositAmount);
        }
        if (usdcFactAmount < minUsdcDepositAmount) {
            revert Fiat24CryptoDeposit__UsdcAmountLowerMinDepositAmount(usdcFactAmount, minUsdcDepositAmount);
        }

        // Transfer fee to feeReceiver if > 0
        if (_feeAmountViaUsdc > 0) {
            TransferHelper.safeTransfer(usdc, feeReceiver, _feeAmountViaUsdc);
        }

        return usdcFactAmount;
    }

    /// @notice Internal function to send LayerZero message
    /// @param _recipient The recipient address (user or target account)
    /// @param _inputToken The input token address
    /// @param _inputAmount The input token amount
    /// @param _usdcAmount The USDC amount
    /// @param _outputToken The output token address
    /// @param _nativeFee The native fee for LayerZero
    /// @param _refundAddress The address to refund excess fees
    function _sendLayerZeroMessage(
        address _recipient,
        address _inputToken,
        uint256 _inputAmount,
        uint256 _usdcAmount,
        address _outputToken,
        uint256 _nativeFee,
        address payable _refundAddress
    ) internal {
        bytes memory payload = abi.encode(
            _recipient,
            _inputToken,
            _inputAmount,
            _usdcAmount,
            _outputToken
        );

        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(relay_gas_limit, 0);

        MessagingFee memory fee = MessagingFee({
            nativeFee: _nativeFee,
            lzTokenFee: 0
        });

        _lzSend(dstId, payload, options, fee, _refundAddress);
    }

    // Internal function to process LayerZero sending for deposit to account
    function _processDepositToAccountLayerZero(
        address _targetAccount,
        address _inputToken,
        uint256 _inputAmount,
        uint256 _usdcAmount,
        address _outputToken,
        uint256 _nativeFee
    ) internal {
        if (_usdcAmount > maxUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountHigherMaxDepositAmount(_usdcAmount, maxUsdcDepositAmount);
        if (_usdcAmount < minUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountLowerMinDepositAmount(_usdcAmount, minUsdcDepositAmount);

        // Transfer USDC to the designated deposit address
        TransferHelper.safeTransfer(usdc, usdcDepositAddress, _usdcAmount);

        _sendLayerZeroMessage(_targetAccount, _inputToken, _inputAmount, _usdcAmount, _outputToken, _nativeFee, payable(msg.sender));
    }

    receive() external payable {}
}
