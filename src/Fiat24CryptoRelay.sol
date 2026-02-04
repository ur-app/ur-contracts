// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "./interfaces/IFiat24CryptoDeposit.sol";
import "./interfaces/IFiat24Account.sol";
import "./libraries/DigitsOfUint.sol";
import "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OAppOptionsType3Upgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/libs/OAppOptionsType3Upgradeable.sol";

contract Fiat24CryptoRelay is OAppUpgradeable,OAppOptionsType3Upgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, IFiat24CryptoDeposit  {

    using SafeMath for uint256;
    using DigitsOfUint for uint256;
    using OptionsBuilder for bytes;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant CASH_OPERATOR_ROLE = keccak256("CASH_OPERATOR_ROLE");
    bytes32 public constant AUTHORIZED_SENDER_ROLE = keccak256("AUTHORIZED_SENDER_ROLE");
    bytes32 public constant RATES_UPDATER_OPERATOR_ROLE = keccak256("RATES_UPDATER_OPERATOR_ROLE");
    bytes32 public constant RATES_UPDATER_ROBOT_ROLE = keccak256("RATES_UPDATER_ROBOT_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    uint256 public constant USDC_DIVISOR = 10000;
    uint256 public constant XXX24_DIVISOR = 10000;

    uint256 public constant CRYPTO_DESK = 9105; // topup subsidiary account
    uint256 public constant TREASURY_DESK = 9100;
    uint256 public constant FEE_DESK = 9203;

    mapping(address => bool) public validXXX24Tokens;
    mapping(address => mapping(address => uint256)) public exchangeRates;
    mapping(uint256 => uint256) public fees;

    uint256 public constant MAX_DIGITS = 5;

    uint256 public fixedNativeFee;

    bool public marketClosed;
    uint256 public exchangeSpread;
    uint256 public marketClosedSpread;

    uint128 public RELAY_GAS_LIMIT;
    uint256 public standardFee;

    address public fiat24account;
    address public usd24;
    address public eur24;
    address public chf24;
    address public gbp24;
    address public usdc;
    address public cnh24;

    uint256 public minUsdExchangeAmount;
    mapping(bytes32 => bytes) private _failedPayloads;
    bytes32[] public failedKeys;
    address[] public fiatTokens;

    // The mapping value should be written as idx+1
    mapping(bytes32 => uint256) private _failedKeyIndex;

    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(
        address admin,
        address _delegate,
        address _fiat24account,
        address _usd24,
        address _eur24,
        address _chf24,
        address _gbp24,
        address _cnh24,
        address _usdc
    ) public initializer {

        require(admin != address(0), "admin is zero");
        require(_delegate != address(0), "delegate is zero");
        require(_fiat24account != address(0), "fiat24account is zero");
        require(_usd24 != address(0), "usd24 is zero");
        require(_eur24 != address(0), "eur24 is zero");
        require(_chf24 != address(0), "chf24 is zero");
        require(_gbp24 != address(0), "gbp24 is zero");
        require(_cnh24 != address(0), "cnh24 is zero");
        require(_usdc != address(0), "usdc is zero");

        __AccessControl_init_unchained();
        __ReentrancyGuard_init();
        __Pausable_init_unchained();
        __OApp_init(_delegate);
        __Ownable_init();
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ROLE, admin);
        _transferOwnership(admin);
        fiat24account = _fiat24account;
        usd24 = _usd24;
        eur24 = _eur24;
        chf24 = _chf24;
        gbp24 = _gbp24;
        cnh24 = _cnh24;
        usdc = _usdc;
        standardFee = 50;

        validXXX24Tokens[_usd24] = true;
        validXXX24Tokens[_eur24] = true;
        validXXX24Tokens[_chf24] = true;
        validXXX24Tokens[_gbp24] = true;
        validXXX24Tokens[_cnh24] = true;

        exchangeRates[usdc][usd24] = 10000;
        exchangeRates[usd24][usd24] = 10000;
        exchangeRates[usd24][eur24] = 8800;
        exchangeRates[usd24][chf24] = 8300;
        exchangeRates[usd24][gbp24] = 7500;
        exchangeRates[usd24][_cnh24] = 72420;

        marketClosed = false;
        exchangeSpread = 9900;
        marketClosedSpread = 9995;
        fixedNativeFee = 1 ether;
        minUsdExchangeAmount = 5000000;
        RELAY_GAS_LIMIT = 500000;

    }

     // @dev Internal function override to handle incoming messages from another chain.
     // @param payload The encoded message payload being received.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata payload,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) internal override {

        try this.processMessage(payload) {

            emit MessageProcessed(_origin.srcEid, _guid);
        } catch Error(string memory reason) {
            _storeFailedMessage(_guid, payload, reason);
        } catch {
            _storeFailedMessage(_guid, payload, "Unknown failure");
        }
    }

    function processMessage(bytes calldata payload) nonReentrant external {

        if (paused()) revert Fiat24CryptoDeposit__Paused();

        require(msg.sender == address(this), "Only internal calls");

        (address user, address inputToken, uint256 inputAmount, uint256 usdcAmount, address outputToken) =
                            abi.decode(payload, (address, address, uint256, uint256, address));

        require(user != address(0), "Invalid user");
        require(usdcAmount > 0, "Invalid amount");
        require(validXXX24Tokens[outputToken], "Invalid token");

        uint256 tokenId = IFiat24Account(fiat24account).historicOwnership(user);
        if (tokenId == 0) revert Fiat24CryptoDeposit__AddressHasNoToken(user);

        uint256 walletId = IFiat24Account(fiat24account).walletProvider(tokenId);
        bool walletIdExists = IFiat24Account(fiat24account).exists(walletId);
        uint256 feeInUSDC = getFee(tokenId, usdcAmount);

        if (walletId == 0 || !walletIdExists) {
            TransferHelper.safeTransferFrom(
                usd24,
                IFiat24Account(fiat24account).ownerOf(CRYPTO_DESK),
                IFiat24Account(fiat24account).ownerOf(FEE_DESK),
                feeInUSDC / USDC_DIVISOR
            );
        } else {
            TransferHelper.safeTransferFrom(
                usd24,
                IFiat24Account(fiat24account).ownerOf(CRYPTO_DESK),
                IFiat24Account(fiat24account).ownerOf(walletId),
                feeInUSDC / USDC_DIVISOR
            );
        }

        uint256 outputAmount = (usdcAmount - feeInUSDC)
            .div(USDC_DIVISOR)
            .mul(exchangeRates[usdc][usd24])
            .div(XXX24_DIVISOR);
        outputAmount = outputAmount
            .mul(getExchangeRate(usd24, outputToken))
            .div(XXX24_DIVISOR)
            .mul(getSpread(usd24, outputToken, false))
            .div(XXX24_DIVISOR);

        TransferHelper.safeTransferFrom(
            outputToken,
            IFiat24Account(fiat24account).ownerOf(CRYPTO_DESK),
            user,
            outputAmount
        );

        emit CrossChainMessage(user, inputToken, inputAmount, usdcAmount, outputToken);
        emit DepositedFiat24Token(user, inputToken, inputAmount, outputToken, outputAmount);
    }

    function _storeFailedMessage(bytes32 messageId, bytes calldata payload, string memory reason) internal {

        if (_failedPayloads[messageId].length == 0) {

            if (payload.length == 0) {
                emit MessageFailed(messageId, "payload length == 0");
            } else {
                _failedPayloads[messageId] = payload;
                failedKeys.push(messageId);
                _failedKeyIndex[messageId] = failedKeys.length;
                emit MessageFailed(messageId, reason);
            }

        } else {
            emit MessageFailed(messageId, "Repeated insertion of data");
        }
    }

    /// @notice Retry a previously failed cross-chain message
    /// @param messageId The unique identifier 'guid' of the failed message to retry
    function retryFailedMessage(bytes32 messageId) external {
        if (!hasRole(OPERATOR_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperator(_msgSender());
        bytes memory payload = _failedPayloads[messageId];
        require(payload.length > 0, "No failed message to retry");
        delete _failedPayloads[messageId];

        this.processMessage(payload);
        _removeFailedKey(messageId);
        emit MessageRetried(messageId, true, "");
    }

    /// @notice Returns a list of messageIds for all failed messages
    function getFailedKeys() external view returns (bytes32[] memory) {
        return failedKeys;
    }

    /// @notice Manually clear a failed message without retrying its processing
    /// @param messageId The unique identifier 'guid' of the failed message to retry
    function adminProcessFailedMessage(bytes32 messageId) external {
        if (!hasRole(OPERATOR_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperator(_msgSender());
        bytes memory payload = _failedPayloads[messageId];
        require(payload.length > 0, "No failed message to retry");
        delete _failedPayloads[messageId];
        _removeFailedKey(messageId);
        emit FailedMessageProcessed(messageId);
    }

    function moneyExchangeExactIn(address _inputToken, address _outputToken, uint256 _inputAmount, uint256 _amountOutMinimum) nonReentrant external returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        if (!validXXX24Tokens[_inputToken]) revert Fiat24CryptoDeposit__NotValidInputToken(_inputToken);
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);
        if (_inputToken == _outputToken) revert Fiat24CryptoDeposit__InputTokenOutputTokenSame(_inputToken, _outputToken);
        uint256 usdAmount = _inputAmount * getExchangeRate(_inputToken, usd24) / XXX24_DIVISOR;
        if (usdAmount < minUsdExchangeAmount) revert Fiat24CryptoExchange__UsdAmountLowerMinAmount(usdAmount);

        TransferHelper.safeTransferFrom(_inputToken, _msgSender(), IFiat24Account(fiat24account).ownerOf(TREASURY_DESK), _inputAmount);
        uint256 outputAmount =
            _inputAmount * getExchangeRate(_inputToken, _outputToken) / XXX24_DIVISOR * getSpread(_inputToken, _outputToken, false) / XXX24_DIVISOR;

        if(outputAmount < _amountOutMinimum) revert Fiat24CryptoDeposit__AmountLessThanMinimum(outputAmount);
        TransferHelper.safeTransferFrom(_outputToken, IFiat24Account(fiat24account).ownerOf(CRYPTO_DESK), _msgSender(), outputAmount);

        emit MoneyExchangedExactIn(_msgSender(), _inputToken, _outputToken, _inputAmount, outputAmount);
        return outputAmount;
    }

    function permitAndMoneyExchangeExactIn(
        address userAddress,
        address _inputToken,
        address _outputToken,
        uint256 _inputAmount,
        uint256 _amountOutMinimum,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external returns (uint256) {
        if (paused()) revert Fiat24CryptoDeposit__Paused();
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Fiat24Token: Not a Cash Operator");
        if (!validXXX24Tokens[_inputToken]) revert Fiat24CryptoDeposit__NotValidInputToken(_inputToken);
        if (!validXXX24Tokens[_outputToken]) revert Fiat24CryptoDeposit__NotValidOutputToken(_outputToken);
        if (_inputToken == _outputToken) revert Fiat24CryptoDeposit__InputTokenOutputTokenSame(_inputToken, _outputToken);

        uint256 usdAmount = _inputAmount * getExchangeRate(_inputToken, usd24) / XXX24_DIVISOR;
        if (usdAmount < minUsdExchangeAmount) revert Fiat24CryptoExchange__UsdAmountLowerMinAmount(usdAmount);

        // 1) Permit
        try IERC20Permit(_inputToken).permit(
            userAddress,
            address(this),
            _inputAmount,
            _deadline,
            _v, _r, _s
        ) {} catch {
            emit PermitFailed(userAddress, address(this), _inputAmount);
        }

        TransferHelper.safeTransferFrom(_inputToken, userAddress, IFiat24Account(fiat24account).ownerOf(TREASURY_DESK), _inputAmount);
        uint256 outputAmount = _inputAmount * getExchangeRate(_inputToken, _outputToken) / XXX24_DIVISOR * getSpread(_inputToken, _outputToken, false) / XXX24_DIVISOR;
        if(outputAmount < _amountOutMinimum) revert Fiat24CryptoDeposit__AmountLessThanMinimum(outputAmount);
        TransferHelper.safeTransferFrom(_outputToken, IFiat24Account(fiat24account).ownerOf(CRYPTO_DESK), userAddress, outputAmount);
        emit MoneyExchangedExactIn(userAddress, _inputToken, _outputToken, _inputAmount, outputAmount);
        return outputAmount;
    }

    function updateExchangeRates(uint256 _usd_eur, uint256 _usd_chf, uint256 _usd_gbp, uint256 _usd_cnh, bool _isMarketClosed) external {
        if (hasRole(RATES_UPDATER_OPERATOR_ROLE, _msgSender())) {
            exchangeRates[usd24][eur24] = _usd_eur;
            exchangeRates[usd24][chf24] = _usd_chf;
            exchangeRates[usd24][gbp24] = _usd_gbp;
            exchangeRates[usd24][cnh24] = _usd_cnh;
            marketClosed = _isMarketClosed;
            emit ExchangeRatesUpdatedByOperator(
                _msgSender(), exchangeRates[usd24][eur24], exchangeRates[usd24][chf24], exchangeRates[usd24][gbp24], exchangeRates[usd24][cnh24], marketClosed
            );
        } else if ((hasRole(RATES_UPDATER_ROBOT_ROLE, _msgSender()))) {
            uint256 rateDiff_usd_eur =
                (exchangeRates[usd24][eur24] > _usd_eur) ? (exchangeRates[usd24][eur24] - _usd_eur) : (_usd_eur - exchangeRates[usd24][eur24]);
            rateDiff_usd_eur = (rateDiff_usd_eur * XXX24_DIVISOR) / exchangeRates[usd24][eur24];
            uint256 rateDiff_usd_chf =
                (exchangeRates[usd24][chf24] > _usd_chf) ? (exchangeRates[usd24][chf24] - _usd_chf) : (_usd_chf - exchangeRates[usd24][chf24]);
            rateDiff_usd_chf = (rateDiff_usd_chf * XXX24_DIVISOR) / exchangeRates[usd24][chf24];
            uint256 rateDiff_usd_gbp =
                (exchangeRates[usd24][gbp24] > _usd_gbp) ? (exchangeRates[usd24][gbp24] - _usd_gbp) : (_usd_gbp - exchangeRates[usd24][gbp24]);
            rateDiff_usd_gbp = (rateDiff_usd_gbp * XXX24_DIVISOR) / exchangeRates[usd24][gbp24];
            uint256 rateDiff_usd_cnh =
                (exchangeRates[usd24][cnh24] > _usd_cnh) ? (exchangeRates[usd24][cnh24] - _usd_cnh) : (_usd_cnh - exchangeRates[usd24][cnh24]);
            rateDiff_usd_cnh = (rateDiff_usd_cnh * XXX24_DIVISOR) / exchangeRates[usd24][cnh24];
            if (rateDiff_usd_eur < 300) exchangeRates[usd24][eur24] = _usd_eur;
            if (rateDiff_usd_chf < 300) exchangeRates[usd24][chf24] = _usd_chf;
            if (rateDiff_usd_gbp < 300) exchangeRates[usd24][gbp24] = _usd_gbp;
            if (rateDiff_usd_cnh < 300) exchangeRates[usd24][cnh24] = _usd_cnh;
            marketClosed = _isMarketClosed;
            emit ExchangeRatesUpdatedByRobot(
                _msgSender(), exchangeRates[usd24][eur24], exchangeRates[usd24][chf24], exchangeRates[usd24][gbp24], exchangeRates[usd24][cnh24], marketClosed
            );
        } else {
            revert Fiat24CryptoDeposit__NotRateUpdater((_msgSender()));
        }
    }

    function updateExchangeRates(
        address[] calldata fiatTokenAddresses,
        uint256[] calldata rates,
        bool isMarketClosed
    ) external {

        require(
            hasRole(RATES_UPDATER_OPERATOR_ROLE, _msgSender()) ||
            hasRole(RATES_UPDATER_ROBOT_ROLE,    _msgSender()),
            "Not authorized to update rates"
        );

        require(fiatTokenAddresses.length == rates.length, "Arrays length mismatch");
        marketClosed = isMarketClosed;
        for (uint256 i = 0; i < fiatTokenAddresses.length; i++) {
            address token = fiatTokenAddresses[i];
            uint256 rate  = rates[i];
            require(validXXX24Tokens[token], "Invalid token");
            require(rate > 0, "Rate must be >0");
            _updateExchangeRate(token, rate, isMarketClosed);
        }
    }

    /// @notice Updating the exchange rate between USD and individual fiat currencies
    function _updateExchangeRate(address _fiatToken, uint256 _rateUsdcToFiat, bool _isMarketClosed) internal {

        uint256 oldRate = exchangeRates[usd24][_fiatToken];

        if (hasRole(RATES_UPDATER_OPERATOR_ROLE, _msgSender())) {
            exchangeRates[usd24][_fiatToken] = _rateUsdcToFiat;
            emit ExchangeRateUpdatedByOperator(_fiatToken, oldRate, _rateUsdcToFiat, _isMarketClosed);
        } else if (hasRole(RATES_UPDATER_ROBOT_ROLE, _msgSender())) {

            uint256 delta = oldRate > _rateUsdcToFiat ? (oldRate - _rateUsdcToFiat) : (_rateUsdcToFiat - oldRate);
            uint256 rateDiff = delta * XXX24_DIVISOR / oldRate;
            require(rateDiff < 300, "Rate Update Robot: change too large");
            exchangeRates[usd24][_fiatToken] = _rateUsdcToFiat;
            emit ExchangeRateUpdatedByRobot(_fiatToken, oldRate, _rateUsdcToFiat, _isMarketClosed);
        } else {
            revert Fiat24CryptoDeposit__NotRateUpdater((_msgSender()));
        }
    }

    function getExchangeRate(address _inputToken, address _outputToken) public view returns (uint256) {
        uint256 exchangeRate;
        if (_inputToken == usd24 || _outputToken == usd24) {
            exchangeRate =
                exchangeRates[_inputToken][_outputToken] == 0 ? 10000 ** 2 / exchangeRates[_outputToken][_inputToken] : exchangeRates[_inputToken][_outputToken];
        } else {
            exchangeRate = (10000 ** 2 / exchangeRates[usd24][_inputToken]) * exchangeRates[usd24][_outputToken] / XXX24_DIVISOR;
        }
        return exchangeRate;
    }

    function getSpread(address _inputToken, address _outputToken, bool exactOut) public view returns (uint256) {
        uint256 totalSpread = 10000;
        if (!(_inputToken == usd24 && _outputToken == usd24)) {
            totalSpread = marketClosed ? exchangeSpread * marketClosedSpread / 10000 : exchangeSpread;
            if (exactOut) {
                totalSpread = 10000 * XXX24_DIVISOR / totalSpread;
            }
        }
        return totalSpread;
    }

    function getFee(uint256 _tokenId, uint256 _usdcAmount) public view returns (uint256 feeInUSDC) {

        // updating
        uint256 _fee = standardFee;
        feeInUSDC = _usdcAmount * _fee / 10000;
    }

    function updateUsdcUsd24ExchangeRate(uint256 _usdc_usd24) external {
        if (!hasRole(RATES_UPDATER_OPERATOR_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotRateUpdater((_msgSender()));
        exchangeRates[usdc][usd24] = _usdc_usd24;
    }


    function changeStandardFee(uint256 _standardFee) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_standardFee >= 0 && _standardFee <= 1000, "Fee must be between 0 and 1000");
        standardFee = _standardFee;
    }

    function changeMarketClosedSpread(uint256 _marketClosedSpread) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_marketClosedSpread >= 9000 && _marketClosedSpread <= 11000, "Spread must be between 9000 and 11000");
        marketClosedSpread = _marketClosedSpread;
    }

    function changeExchangeSpread(uint256 _exchangeSpread) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_exchangeSpread >= 9000 && _exchangeSpread <= 11000, "Spread must be between 9000 and 11000");
        exchangeSpread = _exchangeSpread;
    }

    function changeMinUsdExchangeAmount(uint256 _minUsdExchangeAmount) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperatorAdmin(_msgSender());
        require(_minUsdExchangeAmount > 0, "Min USD exchange amount must be greater than 0");
        minUsdExchangeAmount = _minUsdExchangeAmount;
    }

    function withdrawMNT(address payable to, uint256 amount) external {
        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperator(_msgSender());
        require(to != address(0), "Invalid recipient");
        require(address(this).balance >= amount, "Insufficient MNT balance");

        (bool success, ) = to.call{value: amount}("");
        require(success, "MNT withdrawal failed");
    }

    /// @notice Add a token and set the USD→fiat exchange rate.
    /// @param _fiatToken The address of the Token to be added.
    /// @param _rateUsdToFiat Initial exchange rate
    function addFiatToken(address _fiatToken, uint256 _rateUsdToFiat) external {

        if (!hasRole(OPERATOR_ADMIN_ROLE, _msgSender())) revert Fiat24CryptoDeposit__NotOperator(_msgSender());

        require(_fiatToken != address(0), "Zero address");
        require(!validXXX24Tokens[_fiatToken], "Already exists token");
        require(_rateUsdToFiat > 0, "Rate must be >0");

        validXXX24Tokens[_fiatToken] = true;
        fiatTokens.push(_fiatToken);
        exchangeRates[usd24][_fiatToken] = _rateUsdToFiat;

        emit FiatTokenAndRateAdded(_fiatToken, _rateUsdToFiat);
    }

    function getFiatTokens() external view returns (address[] memory) {
        return fiatTokens;
    }

    function _removeFailedKey(bytes32 messageId) internal {
        uint256 idxPlusOne = _failedKeyIndex[messageId];
        require(idxPlusOne != 0, "Error message");

        // If the element to be deleted is not the last element
        if (idxPlusOne!= failedKeys.length) {
            bytes32 lastId = failedKeys[failedKeys.length - 1];
            failedKeys[idxPlusOne - 1] = lastId;
            _failedKeyIndex[lastId] = idxPlusOne;
        }

        failedKeys.pop();
        delete _failedKeyIndex[messageId];
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