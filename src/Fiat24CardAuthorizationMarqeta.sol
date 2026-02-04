// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./interfaces/IFiat24Account.sol";
import "./interfaces/IFiat24CryptoRelay.sol";
import "./libraries/DigitsOfUint.sol";

error Fiat24CardAuthorizationMarqeta__NotOperator(address sender);
error Fiat24CardAuthorizationMarqeta__NotAuthorizer(address sender);
error Fiat24CardAuthorizationMarqeta__NotPauser(address sender);
error Fiat24CardAuthorizationMarqeta__NotUnpauser(address sender);
error Fiat24CardAuthorizationMarqeta__NotCloseCryptoTokenPairRole(address sender);
error Fiat24CardAuthorizationMarqeta__Suspended();
error Fiat24CardAuthorizationMarqeta__NotValidSettlementCurrency(address settlementCurrency);
error Fiat24CardAuthorizationMarqeta__DefaultSettlementCurrencyIsNotEUR(address settlementCurrency);
error Fiat24CardAuthorizationMarqeta__NotRateUpdater(address sender);
error Fiat24CardAuthorizationMarqeta__InterchangeOutOfRange(uint256 value);
error Fiat24CardAuthorizationMarqeta__InsufficientAllowance(address token, uint256 required, uint256 allowance);

contract Fiat24CardAuthorizationMarqeta is Initializable, AccessControlUpgradeable, PausableUpgradeable {
    using DigitsOfUint for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant AUTHORIZER_ROLE = keccak256("AUTHORIZER_ROLE");
    bytes32 public constant CRYPTO_CONFIG_UPDATER_ROLE = keccak256("CRYPTO_CONFIG_UPDATER_ROLE");
    bytes32 public constant CLOSE_CRYPTO_TOKEN_PAIR_ROLE = keccak256("CLOSE_CRYPTO_TOKEN_PAIR_ROLE");
    bytes32 public constant RATES_UPDATER_OPERATOR_ROLE = keccak256("RATES_UPDATER_OPERATOR_ROLE");
    bytes32 public constant RATES_UPDATER_ROBOT_ROLE = keccak256("RATES_UPDATER_ROBOT_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    uint256 public constant CARD_BOOKED = 9110;
    uint256 public constant SUNDRY = 9103;
    uint256 public constant TREASURY = 9100;
    uint256 public constant CRYPTO_DESK = 9105;

    address public fiat24AccountAddress;
    address public eur24Address;
    address public usd24Address;
    address public chf24Address;
    address public cnh24Address;
    address public gbp24Address;

    mapping(address => bool) public validXXX24Tokens;
    mapping(string => address) public XXX24Tokens;
    mapping(address => mapping(address => uint256)) public exchangeRates;

    uint256 public interchange;
    bool public marketClosed;
    uint256 public exchangeSpread;
    uint256 public marketClosedSpread;

    // unified treasury account for all token swaps
    address public treasuryAddress;
    

    // tokenIn => tokenOut => config
    mapping(address => mapping(address => TokenPairConfig)) public tokenPairConfigs;

    // Configurable alternative tokens that can be swapped for USD24 (or any output token)
    mapping(address => address[]) public alternativeInputTokens;

    uint256 public cryptoSpread;

    struct TokenPairConfig {
        uint256 exchangeRate;
        bool isActive;
    }

    event Authorized(string authorizationToken, uint256 indexed tokenId, address indexed sender, string cardId, address cardCurrency, uint256 paidAmount);
    event Incremented(string authorizationToken, uint256 indexed tokenId, address indexed sender, string cardId, address cardCurrency, uint256 paidAmount);
    event Adviced(
        string adviceToken,
        string originalAuthorizationToken,
        uint256 indexed tokenId,
        address indexed sender,
        string cardId,
        address cardCurrency,
        uint256 paidAmount
    );
    event Reversed(
        string adviceToken,
        string originalAuthorizationToken,
        uint256 indexed tokenId,
        address indexed sender,
        string cardId,
        address cardCurrency,
        uint256 paidAmount
    );
    event ExchangeRatesUpdatedByOperator(address indexed sender, uint256 usd_eur, uint256 usd_chf, uint256 usd_gbp, uint256 usd_cnh, bool marketClosed);
    event ExchangeRatesUpdatedByRobot(address indexed sender, uint256 usd_eur, uint256 usd_chf, uint256 usd_gbp, uint256 usd_cnh, bool marketClosed);
    event FiatTokenAndRateAddedInMarqeta(address indexed fiatToken, uint256 indexed rateUsdcToFiat, string fiatName);
    event ExchangeRateUpdatedByOperator(address indexed fiatToken, uint256 oldRate, uint256 newRate, bool _isMarketClosed);
    event ExchangeRateUpdatedByRobot(address indexed fiatToken, uint256 oldRate, uint256 newRate, bool _isMarketClosed);
    event TokenPairConfigured(address indexed tokenIn, address indexed tokenOut, uint256 exchangeRate, bool isActive);
    event TokenPairExchangeRateUpdated(address indexed tokenIn, address indexed tokenOut, uint256 exchangeRate);
    event TokenPairActiveStatusUpdated(address indexed tokenIn, address indexed tokenOut, bool isActive, uint256 exchangeRate);
    event TreasuryAddressUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DirectSwapExecuted(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event ValidXXX24TokenUpdated(address indexed token, bool oldStatus, bool isValid);
    event SwapFeeCollected(address indexed user, address indexed token, uint256 feeAmount, uint256 tokenId);
    event AlternativeInputTokensUpdated(address indexed outputToken, address[] inputTokens);
    event MarketClosedUpdated(bool oldValue, bool newValue);
    event ExchangeSpreadUpdated(uint256 oldValue, uint256 newValue);
    event CryptoSpreadUpdated(uint256 oldValue, uint256 newValue);
    event InterchangeUpdated(uint256 oldValue, uint256 newValue);

    function initialize(
        address admin,
        address fiat24AccountAddress_,
        address eur24Address_,
        address usd24Address_,
        address chf24Address_,
        address gbp24Address_,
        address cnh24Address_
    ) public initializer {
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ADMIN_ROLE, admin);
        fiat24AccountAddress = fiat24AccountAddress_;
        eur24Address = eur24Address_;
        usd24Address = usd24Address_;
        chf24Address = chf24Address_;
        gbp24Address = gbp24Address_;
        cnh24Address = cnh24Address_;
        validXXX24Tokens[eur24Address_] = true;
        validXXX24Tokens[usd24Address_] = true;
        validXXX24Tokens[chf24Address_] = true;
        validXXX24Tokens[gbp24Address_] = true;
        validXXX24Tokens[cnh24Address_] = true;
        XXX24Tokens["EUR"] = eur24Address_;
        XXX24Tokens["USD"] = usd24Address_;
        XXX24Tokens["CHF"] = chf24Address_;
        XXX24Tokens["GBP"] = gbp24Address_;
        XXX24Tokens["CNH"] = cnh24Address_; //CNH and CNY
        XXX24Tokens["CNY"] = cnh24Address_; //CNH and CNY
        exchangeRates[usd24Address][usd24Address] = 10000;
        exchangeRates[usd24Address][eur24Address] = 9168;
        exchangeRates[usd24Address][chf24Address] = 8632;
        exchangeRates[usd24Address][gbp24Address] = 7674;
        exchangeRates[usd24Address][cnh24Address] = 70885;
        marketClosed = false;
        exchangeSpread = 10150;
        marketClosedSpread = 10005;
        interchange = 1;
    }

    function authorize(
        string memory authorizationToken_,
        string memory cardId_,
        uint256 tokenId_,
        address cardCurrency_,
        string memory transactionCurrency_,
        address settlementCurrency_,
        uint256 transactionAmount_,
        uint256 settlementAmount_
    ) public {
        if (!(hasRole(AUTHORIZER_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotAuthorizer(_msgSender());
        if (paused()) revert Fiat24CardAuthorizationMarqeta__Suspended();
        if (!validXXX24Tokens[settlementCurrency_]) revert Fiat24CardAuthorizationMarqeta__NotValidSettlementCurrency(settlementCurrency_);
        address sender = IFiat24Account(fiat24AccountAddress).ownerOf(tokenId_);
        address booked = IFiat24Account(fiat24AccountAddress).ownerOf(CARD_BOOKED);
        address paidCurrency = cardCurrency_;
        uint256 paidAmount;

        address txnToken = XXX24Tokens[transactionCurrency_];

        if (validXXX24Tokens[txnToken]) {

            if (
                IERC20Upgradeable(txnToken).balanceOf(sender) >= transactionAmount_
                && IERC20Upgradeable(txnToken).allowance(sender, address(this)) >= transactionAmount_
            ) {

                paidCurrency = txnToken;
                paidAmount = transactionAmount_;
            } else {

                paidAmount = transactionAmount_ * getRate(txnToken, cardCurrency_)
                    * getSpread(txnToken, cardCurrency_, false) / 100000000;
                    
                if (cardCurrency_ == usd24Address) {
                    uint256 userUsd24Balance = IERC20Upgradeable(usd24Address).balanceOf(sender);
                    uint256 userUsd24Allowance = IERC20Upgradeable(usd24Address).allowance(sender, address(this));
                    uint256 availableUsd24 = userUsd24Balance < userUsd24Allowance ? userUsd24Balance : userUsd24Allowance;
                    require(userUsd24Allowance >= paidAmount, "Insufficient USD24 allowance");
                    if (availableUsd24 < paidAmount) {

                        require(_trySwapAlternativeTokens(usd24Address, sender, paidAmount - availableUsd24),
                            "Failed to swap alternative tokens for USD24");
                    }
                }
            }
        } else {
            if (settlementCurrency_ != eur24Address) revert Fiat24CardAuthorizationMarqeta__DefaultSettlementCurrencyIsNotEUR(settlementCurrency_);
            paidAmount = settlementAmount_ * (100 + interchange) * getRate(eur24Address, cardCurrency_) * getSpread(eur24Address, cardCurrency_, false) / 10000000000;
            
            if (cardCurrency_ == usd24Address) {
                uint256 userUsd24Balance = IERC20Upgradeable(usd24Address).balanceOf(sender);
                uint256 userUsd24Allowance = IERC20Upgradeable(usd24Address).allowance(sender, address(this));
                uint256 availableUsd24 = userUsd24Balance < userUsd24Allowance ? userUsd24Balance : userUsd24Allowance;
                require(userUsd24Allowance >= paidAmount, "Insufficient USD24 allowance");
                if (availableUsd24 < paidAmount) {

                    require(_trySwapAlternativeTokens(usd24Address, sender, paidAmount - availableUsd24),
                        "Failed to swap alternative tokens for USD24");
                }
            }
        }

        IERC20Upgradeable(paidCurrency).safeTransferFrom(sender, booked, paidAmount == 0 ? 1 : paidAmount);
        emit Authorized(authorizationToken_, tokenId_, sender, cardId_, paidCurrency, paidAmount);
    }

    function increment(
        string memory authorizationToken_,
        string memory cardId_,
        uint256 tokenId_,
        address cardCurrency_,
        string memory transactionCurrency_,
        address settlementCurrency_,
        uint256 transactionAmount_,
        uint256 settlementAmount_
    ) public {
        if (!(hasRole(AUTHORIZER_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotAuthorizer(_msgSender());
        if (paused()) revert Fiat24CardAuthorizationMarqeta__Suspended();
        if (!validXXX24Tokens[settlementCurrency_]) revert Fiat24CardAuthorizationMarqeta__NotValidSettlementCurrency(settlementCurrency_);
        address sender = IFiat24Account(fiat24AccountAddress).ownerOf(tokenId_);
        address booked = IFiat24Account(fiat24AccountAddress).ownerOf(CARD_BOOKED);
        address paidCurrency = cardCurrency_;
        uint256 paidAmount;

        address txnToken = XXX24Tokens[transactionCurrency_];

        if (validXXX24Tokens[txnToken]) {
            if (
                IERC20Upgradeable(txnToken).balanceOf(sender) >= transactionAmount_
                && IERC20Upgradeable(txnToken).allowance(sender, address(this)) >= transactionAmount_
            ) {

                paidCurrency = txnToken;
                paidAmount = transactionAmount_;
            } else {

                paidAmount = transactionAmount_ * getRate(txnToken, cardCurrency_)
                    * getSpread(txnToken, cardCurrency_, false) / 100000000;

                if (cardCurrency_ == usd24Address) {
                    uint256 userUsd24Balance = IERC20Upgradeable(usd24Address).balanceOf(sender);
                    uint256 userUsd24Allowance = IERC20Upgradeable(usd24Address).allowance(sender, address(this));
                    uint256 availableUsd24 = userUsd24Balance < userUsd24Allowance ? userUsd24Balance : userUsd24Allowance;
                    require(userUsd24Allowance >= paidAmount, "Insufficient USD24 allowance");
                    if (availableUsd24 < paidAmount) {
                        require(_trySwapAlternativeTokens(usd24Address, sender, paidAmount - availableUsd24),
                            "Failed to swap alternative tokens for USD24");
                    }
                }
            }
        } else {
            if (settlementCurrency_ != eur24Address) revert Fiat24CardAuthorizationMarqeta__DefaultSettlementCurrencyIsNotEUR(settlementCurrency_);
            paidAmount = settlementAmount_ * (100 + interchange) * getRate(eur24Address, cardCurrency_) * getSpread(eur24Address, cardCurrency_, false) / 10000000000;

            if (cardCurrency_ == usd24Address) {
                uint256 userUsd24Balance = IERC20Upgradeable(usd24Address).balanceOf(sender);
                uint256 userUsd24Allowance = IERC20Upgradeable(usd24Address).allowance(sender, address(this));
                uint256 availableUsd24 = userUsd24Balance < userUsd24Allowance ? userUsd24Balance : userUsd24Allowance;
                require(userUsd24Allowance >= paidAmount, "Insufficient USD24 allowance");
                if (availableUsd24 < paidAmount) {
                    require(_trySwapAlternativeTokens(usd24Address, sender, paidAmount - availableUsd24),
                        "Failed to swap alternative tokens for USD24");
                }
            }
        }

        IERC20Upgradeable(paidCurrency).safeTransferFrom(sender, booked, paidAmount == 0 ? 1 : paidAmount);

        emit Incremented(authorizationToken_, tokenId_, sender, cardId_, paidCurrency, paidAmount);
    }

    function advice(
        string memory authorizationToken_,
        string memory originalAuthorizationToken_,
        string memory cardId_,
        uint256 tokenId_,
        string memory transactionCurrency_,
        address settlementCurrency_,
        uint256 transactionAmount_,
        uint256 settlementAmount_,
        address originalPaidCurrency_
    ) public {
        if (!(hasRole(AUTHORIZER_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotAuthorizer(_msgSender());
        if (paused()) revert Fiat24CardAuthorizationMarqeta__Suspended();
        if (!validXXX24Tokens[settlementCurrency_]) revert Fiat24CardAuthorizationMarqeta__NotValidSettlementCurrency(settlementCurrency_);
        address sender = IFiat24Account(fiat24AccountAddress).ownerOf(tokenId_);
        address booked = IFiat24Account(fiat24AccountAddress).ownerOf(CARD_BOOKED);
        address paidCurrency = originalPaidCurrency_; // Always pay back to the same currency
        uint256 paidAmount;

        if (validXXX24Tokens[XXX24Tokens[transactionCurrency_]]) {
            paidAmount = transactionAmount_ * getRate(XXX24Tokens[transactionCurrency_], originalPaidCurrency_)
                * getSpread(XXX24Tokens[transactionCurrency_], originalPaidCurrency_, false) / 100000000;
        } else {
            if (settlementCurrency_ != eur24Address) revert Fiat24CardAuthorizationMarqeta__DefaultSettlementCurrencyIsNotEUR(settlementCurrency_);
            paidAmount = settlementAmount_ * getRate(eur24Address, originalPaidCurrency_) * getSpread(eur24Address, originalPaidCurrency_, false) / 100000000;
        }

        // Booking from #9110 to Client
        IERC20Upgradeable(paidCurrency).safeTransferFrom(booked, sender, paidAmount);

        emit Adviced(authorizationToken_, originalAuthorizationToken_, tokenId_, sender, cardId_, paidCurrency, paidAmount);
    }

    function reverse(
        string memory authorizationToken_,
        string memory originalAuthorizationToken_,
        string memory cardId_,
        uint256 tokenId_,
        string memory transactionCurrency_,
        address settlementCurrency_,
        uint256 transactionAmount_,
        uint256 settlementAmount_,
        address originalPaidCurrency_
    ) public {
        if (!(hasRole(AUTHORIZER_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotAuthorizer(_msgSender());
        if (paused()) revert Fiat24CardAuthorizationMarqeta__Suspended();
        if (!validXXX24Tokens[settlementCurrency_]) revert Fiat24CardAuthorizationMarqeta__NotValidSettlementCurrency(settlementCurrency_);
        address sender = IFiat24Account(fiat24AccountAddress).ownerOf(tokenId_);
        address booked = IFiat24Account(fiat24AccountAddress).ownerOf(CARD_BOOKED);
        address paidCurrency = originalPaidCurrency_; // Always pay back to the same currency
        uint256 paidAmount;

        if (validXXX24Tokens[XXX24Tokens[transactionCurrency_]]) {
            paidAmount = transactionAmount_ * getRate(XXX24Tokens[transactionCurrency_], originalPaidCurrency_)
                * getSpread(XXX24Tokens[transactionCurrency_], originalPaidCurrency_, false) / 100000000;
        } else {
            if (settlementCurrency_ != eur24Address) revert Fiat24CardAuthorizationMarqeta__DefaultSettlementCurrencyIsNotEUR(settlementCurrency_);
            paidAmount = settlementAmount_ * (100 + interchange) * getRate(eur24Address, originalPaidCurrency_)
                * getSpread(eur24Address, originalPaidCurrency_, false) / 10000000000;
        }

        // Booking from #9110 to Client
        IERC20Upgradeable(paidCurrency).safeTransferFrom(booked, sender, paidAmount);

        emit Reversed(authorizationToken_, originalAuthorizationToken_, tokenId_, sender, cardId_, paidCurrency, paidAmount);
    }


    function setTreasuryAddress(address treasury_) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());
        require(treasury_ != address(0), "Invalid treasury address");
        require(treasury_ != treasuryAddress, "Duplicate treasury address");
        
        address oldTreasury = treasuryAddress;
        treasuryAddress = treasury_;
        
        emit TreasuryAddressUpdated(oldTreasury, treasury_);
    }

    function setTokenPairExchangeRate(
        address tokenIn_,
        address tokenOut_,
        uint256 exchangeRate_
    ) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()) || hasRole(CRYPTO_CONFIG_UPDATER_ROLE, _msgSender()))) {
            revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());
        }
        require(tokenIn_ != address(0), "Invalid input token address");
        require(tokenOut_ != address(0), "Invalid output token address");
        require(tokenIn_ != tokenOut_, "Input and output tokens cannot be the same");
        require(exchangeRate_ >= 0.95e18 && exchangeRate_ <= 1.05e18, "Exchange rate must be between 0.95 and 1.05");
        
        TokenPairConfig storage cfg = tokenPairConfigs[tokenIn_][tokenOut_];
        require(cfg.isActive, "Token pair is not active");
        cfg.exchangeRate = exchangeRate_;
        
        emit TokenPairExchangeRateUpdated(tokenIn_, tokenOut_, exchangeRate_);
    }

    function setCryptoTokenPairActive(
        address tokenIn_,
        address tokenOut_,
        uint256 exchangeRate_
    ) external {
        
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) {
            revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());
        }
        require(tokenIn_ != address(0), "Invalid input token address");
        require(tokenOut_ != address(0), "Invalid output token address");
        require(tokenIn_ != tokenOut_, "Input and output tokens cannot be the same");
        
        uint8 tokenInDecimals = ERC20Upgradeable(tokenIn_).decimals();
        uint8 tokenOutDecimals = ERC20Upgradeable(tokenOut_).decimals();
        require(tokenInDecimals > tokenOutDecimals, "Input token decimals must be > output token decimals");
        require(exchangeRate_ >= 0.95e18 && exchangeRate_ <= 1.05e18, "Exchange rate must be between 0.95 and 1.05");


        TokenPairConfig storage cfg = tokenPairConfigs[tokenIn_][tokenOut_];
        bool oldActive = cfg.isActive;

        require(oldActive == false, "Active status must be false");

        cfg.isActive = true;
        cfg.exchangeRate = exchangeRate_;
        
        emit TokenPairActiveStatusUpdated(tokenIn_, tokenOut_, true, exchangeRate_);
    }

    function closeCryptoTokenPair(
        address tokenIn_,
        address tokenOut_
    ) external {
        if (!hasRole(CLOSE_CRYPTO_TOKEN_PAIR_ROLE, _msgSender())) {
            revert Fiat24CardAuthorizationMarqeta__NotCloseCryptoTokenPairRole(_msgSender());
        }
        
        TokenPairConfig storage cfg = tokenPairConfigs[tokenIn_][tokenOut_];
        require(cfg.isActive == true, "Active status must be true");
        cfg.isActive = false;
        
        emit TokenPairActiveStatusUpdated(tokenIn_, tokenOut_, false, cfg.exchangeRate);
    }

    // Internal function to calculate required input amount with precision handling
    function _calculateRequiredInput(
        address tokenIn,
        address tokenOut,
        uint256 outputAmount,
        uint256 exchangeRate
    ) internal view returns (uint256 baseRequiredAmountIn) {
        uint8 tokenInDecimals = ERC20Upgradeable(tokenIn).decimals();
        uint8 tokenOutDecimals = ERC20Upgradeable(tokenOut).decimals();

        require(tokenInDecimals > tokenOutDecimals, "Input token decimals must be > output token decimals");
        
        // Calculate required input using standard division
        baseRequiredAmountIn = (outputAmount * 10 ** (tokenInDecimals - tokenOutDecimals) * 1e18) / exchangeRate;
        
        if (cryptoSpread > 0 && cryptoSpread != 10000) {
            baseRequiredAmountIn = baseRequiredAmountIn * cryptoSpread / 10000;
        }
    }

    function getQuoteForTokenPair(
        address tokenIn,
        address tokenOut,
        uint256 outputAmount
    ) external view returns (uint256 baseRequiredInput) {
        TokenPairConfig memory config = tokenPairConfigs[tokenIn][tokenOut];
        if (!config.isActive || config.exchangeRate == 0) return 0;
        baseRequiredInput = _calculateRequiredInput(tokenIn, tokenOut, outputAmount, config.exchangeRate);
    }

    function _tryDirectTokenSwap(
        address tokenIn,
        address tokenOut,
        address sender,
        uint256 targetAmountOut
    ) internal returns (bool success) {
        TokenPairConfig memory config = tokenPairConfigs[tokenIn][tokenOut];

        if (!config.isActive || config.exchangeRate == 0) {
            return false;
        }

        uint256 totalRequiredAmountIn = _calculateRequiredInput(
            tokenIn,
            tokenOut,
            targetAmountOut,
            config.exchangeRate
        );

        if (
            IERC20Upgradeable(tokenIn).balanceOf(sender) < (totalRequiredAmountIn) ||
            IERC20Upgradeable(tokenIn).allowance(sender, address(this)) < (totalRequiredAmountIn)
        ) {
            return false;
        }

        // Transfer input tokens to treasury (includes spread)
        IERC20Upgradeable(tokenIn).safeTransferFrom(sender, treasuryAddress, totalRequiredAmountIn);
        
        // Transfer full output amount to user
        IERC20Upgradeable(tokenOut).safeTransferFrom(IFiat24Account(fiat24AccountAddress).ownerOf(CRYPTO_DESK), sender, targetAmountOut);

        emit DirectSwapExecuted(sender, tokenIn, tokenOut, totalRequiredAmountIn, targetAmountOut);
        return true;
    }

    function setAlternativeInputTokens(address outputToken, address[] calldata inputTokens) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());
        require(outputToken != address(0), "Zero outputToken");
        
        uint8 outputTokenDecimals = ERC20Upgradeable(outputToken).decimals();
        
        for (uint256 i = 0; i < inputTokens.length; i++) {
            require(inputTokens[i] != address(0), "Zero input token");
            uint8 inputTokenDecimals = ERC20Upgradeable(inputTokens[i]).decimals();
            require(inputTokenDecimals > outputTokenDecimals, "Input token decimals must be >= output token decimals");
        }
        alternativeInputTokens[outputToken] = inputTokens;
        emit AlternativeInputTokensUpdated(outputToken, inputTokens);
    }
    
    // Generic function to try swapping alternative tokens for a target output
    function _trySwapAlternativeTokens(
        address targetOutputToken,
        address sender,
        uint256 targetAmountOut
    ) internal returns (bool success) {
        address[] memory alternatives = alternativeInputTokens[targetOutputToken];

        if (treasuryAddress == address(0)){
            return false;
        }
        for (uint256 i = 0; i < alternatives.length; i++) {
            if (_tryDirectTokenSwap(alternatives[i], targetOutputToken, sender, targetAmountOut)) {
                return true;
            }

        }
        
        return false;
    }


    function getRate(address _inputToken, address _outputToken) public view returns (uint256) {
        if (_inputToken == _outputToken) {
            return 10000;
        }
        if (_inputToken == usd24Address || _outputToken == usd24Address) {
            return
                exchangeRates[_inputToken][_outputToken] == 0 ? 10000 ** 2 / exchangeRates[_outputToken][_inputToken] : exchangeRates[_inputToken][_outputToken];
        } else {
            return (10000 ** 2 / exchangeRates[usd24Address][_inputToken]) * exchangeRates[usd24Address][_outputToken] / 10000;
        }
    }

    function getSpread(address _inputToken, address _outputToken, bool exactOut) public view returns (uint256) {
        uint256 totalSpread = 10000;

        if (_inputToken == _outputToken) {
            return totalSpread;
        }
        if (!(_inputToken == usd24Address && _outputToken == usd24Address)) {
            totalSpread = marketClosed ? exchangeSpread * marketClosedSpread / 10000 : exchangeSpread;
            if (exactOut) {
                totalSpread = 10000 * 10000 / totalSpread;
            }
        }
        return totalSpread;
    }

    function setMarketClosed(bool newMarketClosed) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());
        bool old = marketClosed;
        marketClosed = newMarketClosed;
        emit MarketClosedUpdated(old, newMarketClosed);
    }

    function setExchangeSpread(uint256 newExchangeSpread) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());

        require(newExchangeSpread > 9000 && newExchangeSpread <= 11000, "Spread must be between 9000 and 11000");
        uint256 old = exchangeSpread;
        exchangeSpread = newExchangeSpread;
        emit ExchangeSpreadUpdated(old, newExchangeSpread);
    }

    function setCryptoSpread(uint256 newCryptoSpread) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());

        require(newCryptoSpread >= 9000 && newCryptoSpread <= 12000, "Crypto spread must be between 9000 and 12000");
        uint256 old = cryptoSpread;
        cryptoSpread = newCryptoSpread;
        emit CryptoSpreadUpdated(old, newCryptoSpread);
    }

    function setInterchange(uint256 interchange_) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());
        if (interchange_ > 100) revert Fiat24CardAuthorizationMarqeta__InterchangeOutOfRange(interchange_);
        uint256 old = interchange;
        interchange = interchange_;
        emit InterchangeUpdated(old, interchange_);
    }

    /// @notice Add a token and set the USD→fiat exchange rate.
    /// @param _fiatToken The address of the Token to be added.
    /// @param _rateUsdToFiat Initial exchange rate
    /// @param _fiatName fiat token name
    function addFiatToken(address _fiatToken, uint256 _rateUsdToFiat, string calldata _fiatName) external {

        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());

        require(_fiatToken != address(0), "Zero address");
        require(!validXXX24Tokens[_fiatToken], "Already exists token");
        require(_rateUsdToFiat > 0, "Rate must be > 0");
        require(XXX24Tokens[_fiatName] == address(0), "Fiat name already used");

        validXXX24Tokens[_fiatToken] = true;
        XXX24Tokens[_fiatName] = _fiatToken;
        exchangeRates[usd24Address][_fiatToken] = _rateUsdToFiat;

        emit FiatTokenAndRateAddedInMarqeta(_fiatToken, _rateUsdToFiat, _fiatName);
    }

    function setValidXXX24Token(address token, bool isValid) external {
        if (!(hasRole(OPERATOR_ADMIN_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotOperator(_msgSender());
        require(token != address(0), "Zero address");
        bool old = validXXX24Tokens[token];
        require(old != isValid, "No state change");
        validXXX24Tokens[token] = isValid;
        emit ValidXXX24TokenUpdated(token, old, isValid);
    }

    function updateExchangeRates(
        address[] calldata fiatTokens,
        uint256[] calldata rates,
        bool isMarketClosed
    ) external {

        require(
            hasRole(RATES_UPDATER_OPERATOR_ROLE, _msgSender()) ||
            hasRole(RATES_UPDATER_ROBOT_ROLE,    _msgSender()),
            "Not authorized to update rates"
        );

        require(fiatTokens.length == rates.length, "Arrays length mismatch");
        marketClosed = isMarketClosed;
        for (uint256 i = 0; i < fiatTokens.length; i++) {
            address token = fiatTokens[i];
            uint256 rate  = rates[i];
            require(validXXX24Tokens[token], "Invalid token");
            require(rate > 0, "Rate must be >0");
            _updateExchangeRate(token, rate, isMarketClosed);
        }
    }

    /// @notice Updating the exchange rate between USD and individual fiat currencies
    function _updateExchangeRate(address _fiatToken, uint256 _rateUsdcToFiat, bool _isMarketClosed) internal {

        uint256 oldRate = exchangeRates[usd24Address][_fiatToken];

        if (hasRole(RATES_UPDATER_OPERATOR_ROLE, _msgSender())) {
            exchangeRates[usd24Address][_fiatToken] = _rateUsdcToFiat;
            emit ExchangeRateUpdatedByOperator(_fiatToken, oldRate, _rateUsdcToFiat, _isMarketClosed);
        } else if (hasRole(RATES_UPDATER_ROBOT_ROLE, _msgSender())) {

            uint256 rateDiff = oldRate > _rateUsdcToFiat ? (oldRate - _rateUsdcToFiat) : (_rateUsdcToFiat - oldRate);
            rateDiff = rateDiff * 10000 / oldRate;
            require(rateDiff < 300, "Rate Update Robot: change too large");
            exchangeRates[usd24Address][_fiatToken] = _rateUsdcToFiat;
            emit ExchangeRateUpdatedByRobot(_fiatToken, oldRate, _rateUsdcToFiat, _isMarketClosed);
        } else {
            revert Fiat24CardAuthorizationMarqeta__NotRateUpdater((_msgSender()));
        }
    }

    function pause() external {
        if (!(hasRole(PAUSE_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotPauser(_msgSender());
        _pause();
    }

    function unpause() external {
        if (!(hasRole(UNPAUSE_ROLE, _msgSender()))) revert Fiat24CardAuthorizationMarqeta__NotUnpauser(_msgSender());
        _unpause();
    }


}