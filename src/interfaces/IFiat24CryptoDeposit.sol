// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFiat24CryptoDeposit {
    error Fiat24CryptoDeposit__NotOperator(address sender);
    error Fiat24CryptoDeposit__NotOperatorAdmin(address sender);
    error Fiat24CryptoDeposit__NotDefaultAdmin(address sender);
    error Fiat24CryptoDeposit__NotRateUpdater(address sender);
    error Fiat24CryptoDeposit__Paused();
    error Fiat24CryptoDeposit__NotValidOutputToken(address token);
    error Fiat24CryptoDeposit__AmountLessThanMinimum(uint256 outputAmount);
    error Fiat24CryptoDeposit__AmountGreaterThanMaximum(uint256 inputAmount);
    error Fiat24CryptoDeposit__NotValidInputToken(address token);
    error Fiat24CryptoDeposit__InputTokenOutputTokenSame(address inputToken, address outputToken);
    error Fiat24CryptoDeposit__AddressHasNoToken(address sender);
    error Fiat24CryptoDeposit__ValueZero();
    error Fiat24CryptoDeposit__EthRefundFailed();
    error Fiat24CryptoDeposit__MNTRefundFailed();
    error Fiat24CryptoDeposit__SwapOutputAmountZero();
    error Fiat24CryptoDeposit__UsdcAmountHigherMaxDepositAmount(uint256 usdcAmount, uint256 maxAmount);
    error Fiat24CryptoDeposit__UsdcAmountLowerMinDepositAmount(uint256 usdcAmount, uint256 minAmount);
    error Fiat24CryptoDeposit__NoPoolAvailable(address tokenA, address tokenB);
    error Fiat24CryptoDeposit__ExchangeRateNotAvailable(address inputToken, address outputToken);
    error Fiat24CryptoDeposit__NotTokensWalletProvider(address sender, uint256 tokenId);
    error Fiat24CryptoDeposit__NotPauser(address sender);
    error Fiat24CryptoDeposit__NotUnpauser(address sender);
    error Fiat24CryptoExchange__UsdAmountLowerMinAmount(uint256 usdAmount);
    error Fiat24Token__NotCashOperator(address caller);
    error Fiat24CryptoDeposit__FeeAmountExceedsOutput(uint256 _feeAmountViaUsdc, uint256 usdcAmount);
    error Fiat24CryptoDeposit__NotWhitelistedAggregator(address aggregator);
    error Fiat24CryptoDeposit__AggregatorSwapFailed();
    error Fiat24CryptoDeposit__SlippageExceeded(uint256 actualAmount, uint256 minAcceptableAmount);
    error Fiat24CryptoDeposit__InvalidCalldata();
    error Fiat24CryptoDeposit__FunctionNotWhitelisted(bytes4 selector);

    event ExchangeRatesUpdatedByOperator(address indexed sender, uint256 usdeur, uint256 usdchf, uint256 usdgbp, uint256 usdcnh, bool marketClosed);
    event ExchangeRatesUpdatedByRobot(address indexed sender, uint256 usdeur, uint256 usdchf, uint256 usdgbp, uint256 usdcnh, bool marketClosed);


    event SentDepositedEth(address indexed sender, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount);
    event DepositedFiat24Token(address indexed sender, address inputToken, uint256 inputAmount, address outputToken, uint256 outputAmount);
    event DepositToAccount(address indexed sender, address indexed targetAddress, address inputToken, uint256 inputAmount);
    event MessageProcessed(uint32 indexed srcEid, bytes32 indexed messageId);
    event FailedMessageProcessed(bytes32 indexed messageId);

    event SentDepositedTokenViaUsd(address indexed sender, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount);
    event DepositedTokenViaUsd(address indexed sender, address inputToken, address outputToken, uint256 inputAmount, uint256 factAmount, uint256 outputAmount);
    event SentDepositedTokenViaEth(address indexed sender, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount);
    event DepositedByWallet(
        uint256 indexed tokenId, address indexed clientAddress, uint256 indexed walletId, address walletAddress, address outputToken, uint256 usdcAmount
    );
    event MoneyExchangedExactIn(address indexed sender, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount);
    event MoneyExchangedExactOut(address indexed sender, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount);

    event UsdcDepositAddressChanged(address oldAddress, address newAddress);

    event FixedNativeFeeUpdated(uint256 oldFee, uint256 newFee);
    event RefundSent(uint32 indexed srcEid, bytes32 indexed srcOApp, string reason);
    event RefundRetried(bytes32 indexed messageId);
    event RefundProcessed(address indexed user, uint256 indexed usdcAmount);
    event RefundProcessFailed(bytes32 indexed messageId, address user, uint256 usdcAmount);
    event PermitFailed(address indexed owner, address indexed spender, uint256 value);
    event ExchangeRateUpdatedByOperator(address indexed fiatToken, uint256 oldRate, uint256 newRate, bool _isMarketClosed);
    event ExchangeRateUpdatedByRobot(address indexed fiatToken, uint256 oldRate, uint256 newRate, bool _isMarketClosed);
    event FiatTokenAndRateAdded(address indexed fiatToken, uint256 indexed rateUsdcToFiat);
    event FiatTokenAdded(address indexed fiatToken);
    event MessageFailed(bytes32 indexed messageId, string reason);
    event MessageRetried(bytes32 indexed messageId, bool success, string reason);
    event CrossChainMessage(address user, address inputToken, uint256 inputAmount, uint256 usdcAmount, address outputToken);
    event SwapExecuted(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    struct FailedRefund {
        address user;
        uint256 usdcAmount;
        address outputToken;
        uint256 retryCount;
    }
}
