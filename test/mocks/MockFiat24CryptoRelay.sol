// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IFiat24CryptoRelay.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

contract MockFiat24CryptoRelay is IFiat24CryptoRelay {
    // Mock exchange rates: 1 USDC = 1 USD24 (10000 basis points)
    uint256 public constant DEFAULT_USDC_USD24_RATE = 10000;
    
    // Mock exchange rates for other tokens (1:1 for simplicity)
    mapping(address => mapping(address => uint256)) public override exchangeRates;
    
    // Mock spread: 10000 = 100% (no spread for simplicity)
    uint256 public constant DEFAULT_SPREAD = 10000;
    
    // Mock USDC token
    address public usdc;
    
    // Mock addresses for treasury and crypto desk (for token transfers)
    address public treasuryDesk = address(0x9100);
    address public cryptoDesk = address(0x9105);
    
    constructor(address _usdc) {
        usdc = _usdc;
        // Set default rates
        exchangeRates[usdc][address(0)] = DEFAULT_USDC_USD24_RATE; // Placeholder, will be set properly
    }
    
    function setExchangeRate(address tokenA, address tokenB, uint256 rate) external {
        exchangeRates[tokenA][tokenB] = rate;
    }
    
    function setTreasuryDesk(address _treasuryDesk) external {
        treasuryDesk = _treasuryDesk;
    }
    
    function setCryptoDesk(address _cryptoDesk) external {
        cryptoDesk = _cryptoDesk;
    }
    
    function depositTokenViaUsdc(address, address, uint256) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }
    
    function moneyExchangeExactIn(
        address _inputToken,
        address _outputToken,
        uint256 _inputAmount,
        uint256 _amountOutMinimum
    ) external override returns (uint256) {
        // Get exchange rate
        uint256 rate = exchangeRates[_inputToken][_outputToken];
        if (rate == 0) rate = DEFAULT_USDC_USD24_RATE;
        
        // Calculate output amount
        uint256 output = (_inputAmount * rate) / 10000;
        require(output >= _amountOutMinimum, "Slippage");
        
        // Transfer input token from caller to treasury desk
        IERC20Upgradeable(_inputToken).transferFrom(msg.sender, treasuryDesk, _inputAmount);
        
        // Transfer output token from crypto desk to caller
        // Note: In tests, crypto desk needs to have the output token and approve this contract
        IERC20Upgradeable(_outputToken).transferFrom(cryptoDesk, msg.sender, output);
        
        return output;
    }
    
    function permitAndMoneyExchangeExactIn(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }
    
    function updateExchangeRates(uint256, uint256, uint256, uint256, bool) external pure override {
        revert("Not implemented in mock");
    }
    
    function updateUsdcUsd24ExchangeRate(uint256 _rate) external override {
        // This would be set properly in tests
    }
    
    function getExchangeRate(address _inputToken, address _outputToken) external view override returns (uint256) {
        uint256 rate = exchangeRates[_inputToken][_outputToken];
        return rate == 0 ? DEFAULT_USDC_USD24_RATE : rate;
    }
    
    function getSpread(address, address, bool) external pure override returns (uint256) {
        return DEFAULT_SPREAD;
    }
    
    function getFee(uint256, uint256) external pure override returns (uint256) {
        return 0; // No fee for simplicity
    }
    
    function changeStandardFee(uint256) external pure override {
        revert("Not implemented in mock");
    }
    
    function changeMarketClosedSpread(uint256) external pure override {
        revert("Not implemented in mock");
    }
    
    function changeExchangeSpread(uint256) external pure override {
        revert("Not implemented in mock");
    }
    
    function changeMinUsdExchangeAmount(uint256) external pure override {
        revert("Not implemented in mock");
    }
    
    function setRelayGasLimit(uint128) external pure override {
        revert("Not implemented in mock");
    }
    
    function setFixedNativeFee(uint256) external pure override {
        revert("Not implemented in mock");
    }
    
    function withdrawMNT(address payable, uint256) external pure override {
        revert("Not implemented in mock");
    }
    
    function pause() external pure override {
        revert("Not implemented in mock");
    }
    
    function unpause() external pure override {
        revert("Not implemented in mock");
    }
}

