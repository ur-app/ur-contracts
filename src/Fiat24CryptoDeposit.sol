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
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "./interfaces/IFiat24Account.sol";
import "./interfaces/IF24.sol";
import "./interfaces/IF24TimeLock.sol";
import "./libraries/DigitsOfUint.sol";
import "./interfaces/IFiat24CryptoRelay.sol";
import "./interfaces/IFiat24CryptoDeposit.sol";
import "./interfaces/IPeripheryPayments.sol";

contract Fiat24CryptoDeposit is Initializable, AccessControlUpgradeable,ReentrancyGuardUpgradeable, PausableUpgradeable, IFiat24CryptoDeposit  {
    using SafeMath for uint256;
    using DigitsOfUint for uint256;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CASH_OPERATOR_ROLE = keccak256("CASH_OPERATOR_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant RATES_UPDATER_OPERATOR_ROLE = keccak256("RATES_UPDATER_OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    uint256 public constant USDC_DIVISOR = 10000;
    uint256 public constant XXX24_DIVISOR = 10000;
    uint256 public constant MAX_FEE_AMOUNT_USDC = 5_000_000;

    uint256 public constant CRYPTO_DESK = 9105;
    uint256 public constant TREASURY_DESK = 9100;
    uint256 public constant FEE_DESK = 9203;

    uint256 public constant MAX_DIGITS = 5;

    //Agni ADDRESSES
    address public immutable UNISWAP_FACTORY;
    address public immutable UNISWAP_ROUTER;
    address public immutable UNISWAP_PERIPHERY_PAYMENTS;
    address public immutable UNISWAP_QUOTER;
    address public immutable WMNT;

    address public usdc;
    address public usd24;

    //Max and min USDC top-up amount
    uint256 public maxUsdcDepositAmount;
    uint256 public minUsdcDepositAmount;

    mapping(address => bool) public validXXX24Tokens;
    mapping(address => mapping(address => uint256)) public exchangeRates;

    address public usdcDepositAddress;
    address public feeReceiver;
    address public fiat24account;
    address public fiat24CryptoRelayAddress;

    // Aggregator whitelist for secure swap execution
    mapping(address => bool) public whitelistedAggregators;
    
    // Whitelisted function selectors for each aggregator (aggregator => selector => allowed)
    mapping(address => mapping(bytes4 => bool)) public whitelistedSelectors;

    event FeeReceiverChanged(address indexed oldFeeReceiver, address indexed newFeeReceiver);
    event AggregatorWhitelistUpdated(address indexed aggregator, bool isWhitelisted);
    event FunctionSelectorWhitelisted(address indexed aggregator, bytes4 indexed selector, bool isWhitelisted);
    event SentDepositedTokenViaAggregator(address indexed sender, address indexed inputToken, address indexed outputToken, uint256 inputAmount, uint256 usdcAmount, address aggregator);

    constructor(
        address _uniswapFactory,
        address _uniswapRouter,
        address _uniswapPeripheryPayments,
        address _uniswapQuoter,
        address _wmnt
    ) {
        require(_uniswapFactory != address(0), "uniswapFactory is zero");
        require(_uniswapRouter != address(0), "uniswapRouter is zero");
        require(_uniswapPeripheryPayments != address(0), "uniswapPeripheryPayments is zero");
        require(_uniswapQuoter != address(0), "uniswapQuoter is zero");
        require(_wmnt != address(0), "wmnt is zero");

        UNISWAP_FACTORY = _uniswapFactory;
        UNISWAP_ROUTER = _uniswapRouter;
        UNISWAP_PERIPHERY_PAYMENTS = _uniswapPeripheryPayments;
        UNISWAP_QUOTER = _uniswapQuoter;
        WMNT = _wmnt;
    }

    //     function initialize(
    //     address admin,
    //     address _fiat24account,
    //     address _usd24,
    //     address _eur24,
    //     address _chf24,
    //     address _gbp24,
    //     address _cnh24,
    //     address _usdc,
    //     address _usdcDepositAddress,
    //     address _feeReceiver,
    //     address _fiat24CryptoRelayAddress
    // ) public initializer {

    //     require(admin != address(0), "admin is zero");
    //     require(_fiat24account != address(0), "fiat24account is zero");
    //     require(_usd24 != address(0), "usd24 is zero");
    //     require(_eur24 != address(0), "eur24 is zero");
    //     require(_chf24 != address(0), "chf24 is zero");
    //     require(_gbp24 != address(0), "gbp24 is zero");
    //     require(_cnh24 != address(0), "cnh24 is zero");
    //     require(_usdc != address(0), "usdc is zero");

    //     __AccessControl_init_unchained();
    //     __Pausable_init_unchained();
    //     _setupRole(DEFAULT_ADMIN_ROLE, admin);
    //     _setupRole(OPERATOR_ROLE, admin);
    //     __ReentrancyGuard_init();

    //     fiat24account = _fiat24account;
    //     usd24 = _usd24;
    //     usdc = _usdc;
    //     usdcDepositAddress = _usdcDepositAddress;
    //     feeReceiver = _feeReceiver;
    //     maxUsdcDepositAmount = 50000000000;
    //     minUsdcDepositAmount = 3000000;

    //     validXXX24Tokens[_usd24] = true;
    //     validXXX24Tokens[_eur24] = true;
    //     validXXX24Tokens[_chf24] = true;
    //     validXXX24Tokens[_gbp24] = true;
    //     validXXX24Tokens[_cnh24] = true;
    //     exchangeRates[usdc][usd24] = 10000;
    //     fiat24CryptoRelayAddress = _fiat24CryptoRelayAddress;
    // }


    function depositTokenViaUsdc(address _inputToken, address _outputToken, uint256 _amount, uint256 _amountOutMinimum) nonReentrant external returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (_amount == 0) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);
        uint256 tokenId = IFiat24Account(fiat24account).historicOwnership(_msgSender());
        if (tokenId == 0) revert Fiat24CryptoDeposit__AddressHasNoToken(_msgSender());

        // Transfer token from user
        TransferHelper.safeTransferFrom(_inputToken, _msgSender(), address(this), _amount);

        uint256 usdcAmount;
        if (_inputToken != usdc) {
            // Convert input token to USDC via Uniswap
            usdcAmount = _swapExactInputSingle(_inputToken, usdc, _amount, _amountOutMinimum, address(this), false);
        } else {
            usdcAmount = _amount;
        }

        return _processDeposit(_msgSender(), _inputToken, _outputToken, _amount, usdcAmount, tokenId);
    }

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

        uint256 tokenId = IFiat24Account(fiat24account).historicOwnership(userAddress);
        if (tokenId == 0) revert Fiat24CryptoDeposit__AddressHasNoToken(userAddress);

        TransferHelper.safeTransferFrom(_inputToken, userAddress, address(this), _amount);

        uint256 usdcAmount;
        if (_inputToken != usdc) {
            usdcAmount = _swapExactInputSingle(_inputToken, usdc, _amount, _amountOutMinimum, address(this), false);
        } else {
            usdcAmount = _amount;
        }

        uint256 usdcFactAmount = _processFeeAndValidation(usdcAmount, _feeAmountViaUsdc);

        return _processDeposit(userAddress, _inputToken, _outputToken, _amount, usdcFactAmount, tokenId);
    }

    /// @notice Deposit token via aggregator (1inch, odos, etc.), swap to USDC and process deposit
    /// @param _inputToken The token to deposit (address(0) or 0xEeee...eEeE for MNT)
    /// @param _outputToken The target fiat24 token (EUR24, USD24, etc.)
    /// @param _amount The amount of input token to deposit (for MNT, this is the MNT amount to swap)
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
        uint256 tokenId = IFiat24Account(fiat24account).historicOwnership(_msgSender());
        if (tokenId == 0) revert Fiat24CryptoDeposit__AddressHasNoToken(_msgSender());

        address sender = _msgSender();

        // Handle MNT deposit
        if (_inputToken == address(0) || _inputToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            if (msg.value != _amount) revert Fiat24CryptoDeposit__ValueZero();
        } else {
            if (msg.value != 0) revert Fiat24CryptoDeposit__ValueZero();
            TransferHelper.safeTransferFrom(_inputToken, sender, address(this), _amount);
        }

        uint256 usdcAmount = _swapViaAggregator(_inputToken, _amount, _aggregator, _swapCalldata, _minUsdcAmount);
        uint256 usdcFactAmount = _processFeeAndValidation(usdcAmount, _feeAmountViaUsdc);
        
        emit SentDepositedTokenViaAggregator(sender, _inputToken, _outputToken, _amount, usdcFactAmount, _aggregator);
        return _processDeposit(sender, _inputToken, _outputToken, _amount, usdcFactAmount, tokenId);
    }

    /// @notice Deposit token via aggregator to another account owned by the sender
    /// @param _targetAccount The target Fiat24 account address to deposit to
    /// @param _inputToken The token to deposit (address(0) or 0xEeee...eEeE for MNT)
    /// @param _outputToken The target fiat24 token (EUR24, USD24, etc.)
    /// @param _amount The amount of input token to deposit (for MNT, msg.value should equal _amount)
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
        if (_amount == 0) revert Fiat24CryptoDeposit__ValueZero();
        uint256 targetTokenId = _validateDepositToAccountParams(_targetAccount, _outputToken);

        address sender = _msgSender();

        // Handle MNT deposit
        if (_inputToken == address(0) || _inputToken == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            if (msg.value != _amount) revert Fiat24CryptoDeposit__ValueZero();
            // MNT is already in msg.value, will be used in swap
        } else {
            if (msg.value != 0) revert Fiat24CryptoDeposit__ValueZero();
            TransferHelper.safeTransferFrom(_inputToken, sender, address(this), _amount);
        }

        uint256 usdcAmount = _swapViaAggregator(_inputToken, _amount, _aggregator, _swapCalldata, _minUsdcAmount);
        
        if (usdcAmount == 0) revert Fiat24CryptoDeposit__SwapOutputAmountZero();
        
        emit SentDepositedTokenViaAggregator(sender, _inputToken, _outputToken, _amount, usdcAmount, _aggregator);
        emit DepositToAccount(sender, _targetAccount, _inputToken, _amount);
        return _processDeposit(_targetAccount, _inputToken, _outputToken, _amount, usdcAmount, targetTokenId);
    }

    // Deposit MNT, convert to USDC, and process deposit
    function depositMNT(address _outputToken, uint256 _amountOutMinimum) nonReentrant external payable returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (msg.value == 0) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);
        uint256 tokenId = IFiat24Account(fiat24account).historicOwnership(_msgSender());
        if (tokenId == 0) revert Fiat24CryptoDeposit__AddressHasNoToken(_msgSender());

        // MNT -> USDC Conversion (via Uniswap)
        uint256 amountIn = msg.value;
        uint256 usdcAmount = _swapExactInputSingle(WMNT, usdc, amountIn, _amountOutMinimum, address(this), true);

        // Refund any remaining MNT
        uint256 beforeBalance = address(this).balance;
        IPeripheryPayments(UNISWAP_PERIPHERY_PAYMENTS).refundMNT();
        uint256 refundAmount = address(this).balance - beforeBalance;
        if (refundAmount > 0) {
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            if (!success) revert Fiat24CryptoDeposit__MNTRefundFailed();
        }


        
        return _processDeposit(_msgSender(), WMNT, _outputToken, amountIn, usdcAmount, tokenId);
    }

    // Deposit MNT to another account owned by the sender
    function depositMNTToAccount(address _targetAccount, address _outputToken, uint256 _amountOutMinimum) nonReentrant external payable returns (uint256) {
        if (msg.value == 0) revert Fiat24CryptoDeposit__ValueZero();
        uint256 targetTokenId = _validateDepositToAccountParams(_targetAccount, _outputToken);

        // MNT -> USDC Conversion (via Uniswap)
        uint256 amountIn = msg.value;
        uint256 usdcAmount = _swapExactInputSingle(WMNT, usdc, amountIn, _amountOutMinimum, address(this), true);

        // Refund any remaining MNT
        uint256 beforeBalance = address(this).balance;
        IPeripheryPayments(UNISWAP_PERIPHERY_PAYMENTS).refundMNT();
        uint256 refundAmount = address(this).balance - beforeBalance;
        if (refundAmount > 0) {
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            if (!success) revert Fiat24CryptoDeposit__MNTRefundFailed();
        }
        
        emit DepositToAccount(_msgSender(), _targetAccount, WMNT, amountIn);
        return _processDeposit(_targetAccount, WMNT, _outputToken, amountIn, usdcAmount, targetTokenId);
    }

    // Deposit token to another account owned by the sender
    function depositTokenViaUsdcToAccount(address _targetAccount, address _inputToken, address _outputToken, uint256 _amount, uint256 _amountOutMinimum) nonReentrant external returns (uint256) {
        if (_amount == 0) revert Fiat24CryptoDeposit__ValueZero();
        uint256 targetTokenId = _validateDepositToAccountParams(_targetAccount, _outputToken);

        // Transfer token from user
        TransferHelper.safeTransferFrom(_inputToken, _msgSender(), address(this), _amount);

        uint256 usdcAmount;
        if (_inputToken != usdc) {
            // Convert input token to USDC via Uniswap
            usdcAmount = _swapExactInputSingle(_inputToken, usdc, _amount, _amountOutMinimum, address(this), false);
        } else {
            usdcAmount = _amount;
        }

        emit DepositToAccount(_msgSender(), _targetAccount, _inputToken, _amount);
        return _processDeposit(_targetAccount, _inputToken, _outputToken, _amount, usdcAmount, targetTokenId);
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

    function updateUsdcUsd24ExchangeRate(uint256 _usdc_usd24) external {
        if (!hasRole(RATES_UPDATER_OPERATOR_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotRateUpdater((_msgSender()));
        exchangeRates[usdc][usd24] = _usdc_usd24;
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

    function withdrawMNT(address payable to, uint256 amount) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(to != address(0), "Invalid recipient");
        require(address(this).balance >= amount, "Insufficient MNT balance");

        (bool success, ) = to.call{value: amount}("");
        require(success, "MNT withdrawal failed");
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

    function getQuote(address _inputToken, address _outputToken, uint24 _fee, uint256 _amount) public returns (uint256) {
        return IQuoter(UNISWAP_QUOTER).quoteExactInputSingle(_inputToken, _outputToken, _fee, _amount, 0);
    }

    /// @notice permit and swap USDC to any ERC20 token via Agni
    function permitAndSwapUsdcToToken(
        address _userAddress,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMinimum,
        uint256 _feeAmountViaUsdc,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external nonReentrant payable returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (!hasRole(CASH_OPERATOR_ROLE, _msgSender())) revert Fiat24Token__NotCashOperator(_msgSender());
        if (_tokenOut == address(0)) revert Fiat24CryptoDeposit__ValueZero();
        if (_tokenOut == usdc) revert Fiat24CryptoDeposit__InputTokenOutputTokenSame(usdc, _tokenOut);

        // Execute permit for USDC
        try IERC20PermitUpgradeable(usdc).permit(
            _userAddress,
            address(this),
            _amountIn,
            _deadline,
            _v, _r, _s
        ) {
        } catch {
            emit PermitFailed(_userAddress, usdc, _amountIn);
        }

        TransferHelper.safeTransferFrom(usdc, _userAddress, address(this), _amountIn);

        if (_feeAmountViaUsdc >= MAX_FEE_AMOUNT_USDC) {
            _feeAmountViaUsdc = MAX_FEE_AMOUNT_USDC;
        }

        if (_feeAmountViaUsdc >= _amountIn) {
            revert Fiat24CryptoDeposit__FeeAmountExceedsOutput(_feeAmountViaUsdc, _amountIn);
        }

        if (_feeAmountViaUsdc > 0) {
            TransferHelper.safeTransfer(usdc, feeReceiver, _feeAmountViaUsdc);
        }

        // Perform the swap from remaining USDC to output token
        uint256 outputAmount = _swapExactInputSingle(usdc, _tokenOut, _amountIn - _feeAmountViaUsdc, _amountOutMinimum, _userAddress, false);
        emit SwapExecuted(_userAddress, usdc, _tokenOut, _amountIn, outputAmount);

        return outputAmount;
    }

    // Internal method to execute Agni swap
    function _swapExactInputSingle(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMinimum,
        address _recipient,
        bool _isMNT
    ) internal returns (uint256 amountOut) {
        uint24 poolFee = getPoolFeeOfMostLiquidPool(_tokenIn, _tokenOut);
        if (poolFee == 0) revert Fiat24CryptoDeposit__NoPoolAvailable(_tokenIn, _tokenOut);

        if (!_isMNT) {
            TransferHelper.safeApprove(_tokenIn, UNISWAP_ROUTER, _amountIn);
        }

        // Setup swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: poolFee,
            recipient: _recipient,
            deadline: block.timestamp + 15,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        // Execute swap
        if (_isMNT) {
            amountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle{value: _amountIn}(params);
        } else {
            amountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params);
        }

        return amountOut;
    }

    function _processDeposit(
        address user,
        address _inputToken,
        address _outputToken,
        uint256 _inputAmount,
        uint256 _factAmount,
        uint256 tokenId
    ) internal returns (uint256 outputAmount) {
        if (_factAmount == 0) revert Fiat24CryptoDeposit__SwapOutputAmountZero();
        if (_factAmount > maxUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountHigherMaxDepositAmount(_factAmount, maxUsdcDepositAmount);
        if (_factAmount < minUsdcDepositAmount) revert Fiat24CryptoDeposit__UsdcAmountLowerMinDepositAmount(_factAmount, minUsdcDepositAmount);

        uint256 walletId = IFiat24Account(fiat24account).walletProvider(tokenId);
        bool walletIdExists = IFiat24Account(fiat24account).exists(walletId);
        uint256 feeInUSDC = IFiat24CryptoRelay(fiat24CryptoRelayAddress).getFee(tokenId, _factAmount);
        
        if (walletId == 0 || !walletIdExists) {
            TransferHelper.safeTransfer(usdc, usdcDepositAddress, _factAmount);
            TransferHelper.safeTransferFrom(
                usd24, 
                IFiat24Account(fiat24account).ownerOf(CRYPTO_DESK), 
                IFiat24Account(fiat24account).ownerOf(FEE_DESK), 
                feeInUSDC / USDC_DIVISOR
            );
        } else {
            TransferHelper.safeTransfer(usdc, usdcDepositAddress, _factAmount - feeInUSDC);
            TransferHelper.safeTransfer(usdc, IFiat24Account(fiat24account).ownerOf(walletId), feeInUSDC);
        }

        outputAmount = (_factAmount - feeInUSDC) / USDC_DIVISOR * exchangeRates[usdc][usd24] / XXX24_DIVISOR;

        outputAmount = outputAmount * IFiat24CryptoRelay(fiat24CryptoRelayAddress).getExchangeRate(usd24, _outputToken) /
                    XXX24_DIVISOR * IFiat24CryptoRelay(fiat24CryptoRelayAddress).getSpread(usd24, _outputToken, false) / XXX24_DIVISOR;

        TransferHelper.safeTransferFrom(_outputToken, IFiat24Account(fiat24account).ownerOf(CRYPTO_DESK), user, outputAmount);
        emit DepositedFiat24Token(user, _inputToken, _inputAmount, _outputToken, outputAmount);
    }

    // Internal function to validate common parameters for deposit to account
    function _validateDepositToAccountParams(address _targetAccount, address _outputToken) internal view returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (_targetAccount == address(0)) revert Fiat24CryptoDeposit__ValueZero();
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);

        uint256 targetTokenId = IFiat24Account(fiat24account).historicOwnership(_targetAccount);
        if (targetTokenId == 0) revert Fiat24CryptoDeposit__AddressHasNoToken(_targetAccount);
        
        return targetTokenId;
    }

    /// @notice Internal function to swap tokens via aggregator
    /// @param _inputToken The input token address (address(0) or 0xEeee...eEeE for MNT)
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
            // For MNT, call aggregator with value
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
        // Cap fee at maximum and validate it doesn't exceed amount
        if (_feeAmountViaUsdc >= MAX_FEE_AMOUNT_USDC) {
            _feeAmountViaUsdc = MAX_FEE_AMOUNT_USDC;
        }

        if (_feeAmountViaUsdc >= _usdcAmount) {
            revert Fiat24CryptoDeposit__FeeAmountExceedsOutput(_feeAmountViaUsdc, _usdcAmount);
        }

        usdcFactAmount = _usdcAmount - _feeAmountViaUsdc;
        
        // Transfer fee to feeReceiver if > 0
        if (_feeAmountViaUsdc > 0) {
            TransferHelper.safeTransfer(usdc, feeReceiver, _feeAmountViaUsdc);
        }
        
        return usdcFactAmount;
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

    function pause() external {
        if (!(hasRole(PAUSE_ROLE, _msgSender()))) revert Fiat24CryptoDeposit__NotPauser(_msgSender());
        _pause();
    }

    function unpause() external {
        if (!(hasRole(UNPAUSE_ROLE, _msgSender()))) revert Fiat24CryptoDeposit__NotUnpauser(_msgSender());
        _unpause();
    }


    receive() external payable {}
}
