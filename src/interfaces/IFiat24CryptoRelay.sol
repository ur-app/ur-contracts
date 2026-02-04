// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

/**
 * @title IFiat24CryptoRelay
 * @dev Interface for the Fiat24CryptoRelay contract that handles cross-chain token deposits and exchanges
 */
interface IFiat24CryptoRelay {
    // Core functions
    function depositTokenViaUsdc(address _inputToken, address _outputToken, uint256 _amount) external returns (uint256);
    function moneyExchangeExactIn(address _inputToken, address _outputToken, uint256 _inputAmount, uint256 _amountOutMinimum) external returns (uint256);
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
    ) external returns (uint256);

    // Rate management functions
    function updateExchangeRates(uint256 _usd_eur, uint256 _usd_chf, uint256 _usd_gbp, uint256 _usd_cnh, bool _isMarketClosed) external;
    function updateUsdcUsd24ExchangeRate(uint256 _usdc_usd24) external;
    function exchangeRates(address tokenA, address tokenB) external view returns (uint256);
    function getExchangeRate(address _inputToken, address _outputToken) external view returns (uint256);
    function getSpread(address _inputToken, address _outputToken, bool exactOut) external view returns (uint256);
    function getFee(uint256 _tokenId, uint256 _usdcAmount) external view returns (uint256);

    // Configuration functions
    function changeStandardFee(uint256 _standardFee) external;
    function changeMarketClosedSpread(uint256 _marketClosedSpread) external;
    function changeExchangeSpread(uint256 _exchangeSpread) external;
    function changeMinUsdExchangeAmount(uint256 _minUsdExchangeAmount) external;
    function setRelayGasLimit(uint128 _newLimit) external;
    function setFixedNativeFee(uint256 _fixedNativeFee) external;

    // Admin functions
    function withdrawMNT(address payable to, uint256 amount) external;
    function pause() external;
    function unpause() external;
} 