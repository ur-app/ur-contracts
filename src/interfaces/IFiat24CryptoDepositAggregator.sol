// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFiat24CryptoDepositAggregator
 * @notice Interface for aggregator-based deposit functions
 */
interface IFiat24CryptoDepositAggregator {
    /**
     * @notice Deposit token via aggregator swap to Fiat24 token
     * @param _inputToken Input token address
     * @param _outputToken Output Fiat24 token address
     * @param _amount Amount of input token
     * @param _aggregator Aggregator contract address
     * @param _swapCalldata Calldata for aggregator swap
     * @param _minUsdcAmount Minimum USDC amount after swap (slippage protection)
     * @param _feeAmountViaUsdc Fee amount in USDC
     * @return Output amount of Fiat24 token
     */
    function depositTokenViaAggregator(
        address _inputToken,
        address _outputToken,
        uint256 _amount,
        address _aggregator,
        bytes calldata _swapCalldata,
        uint256 _minUsdcAmount,
        uint256 _feeAmountViaUsdc
    ) external payable returns (uint256);

    /**
     * @notice Deposit token via aggregator swap to a specific Fiat24 account
     * @param _targetAccount Target account address to receive Fiat24 tokens
     * @param _inputToken Input token address
     * @param _outputToken Output Fiat24 token address
     * @param _amount Amount of input token
     * @param _aggregator Aggregator contract address
     * @param _swapCalldata Calldata for aggregator swap
     * @param _minUsdcAmount Minimum USDC amount after swap (slippage protection)
     * @return Output amount of Fiat24 token
     */
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

