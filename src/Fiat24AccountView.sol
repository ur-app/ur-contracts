// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Fiat24Account.sol";
import "./Fiat24CardAuthorizationMarqeta.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract Fiat24AccountView is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    struct TokenSnapshot {
        address token;
        uint256 balance;
        uint256 allowance;
    }
    
    event Usd24AlternativeTokensUpdated(address[] tokens);
    event FiatTokensUpdated(address[] tokens);

    Fiat24Account public immutable fiat24Account;
    Fiat24CardAuthorizationMarqeta public immutable fiat24CardAuthorizationMarqeta;
    address public immutable usd24Address;
    address public immutable eur24Address;
    address[] public fiatTokens;
    address[] public usd24AlternativeTokens; // Alternative tokens for USD24 (like USDE)

    constructor(address fiat24AccountAddress, address fiat24CardAuthorizationMarqetaAddress, address admin) {
        require(fiat24AccountAddress != address(0), "Fiat24AccountView: zero account address");
        require(fiat24CardAuthorizationMarqetaAddress != address(0), "Fiat24AccountView: zero card authorization marqeta address");
        require(admin != address(0), "Fiat24AccountView: zero admin address");
        
        fiat24Account = Fiat24Account(fiat24AccountAddress);
        fiat24CardAuthorizationMarqeta = Fiat24CardAuthorizationMarqeta(fiat24CardAuthorizationMarqetaAddress);

        usd24Address = fiat24CardAuthorizationMarqeta.usd24Address();
        eur24Address = fiat24CardAuthorizationMarqeta.eur24Address();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        
        // support currency: EUR, USD, CHF, CNH, SGD, JPY, HKD
        fiatTokens = [
            fiat24CardAuthorizationMarqeta.XXX24Tokens("EUR"),
            fiat24CardAuthorizationMarqeta.XXX24Tokens("USD"),
            fiat24CardAuthorizationMarqeta.XXX24Tokens("CHF"),
            fiat24CardAuthorizationMarqeta.XXX24Tokens("CNH"),
            fiat24CardAuthorizationMarqeta.XXX24Tokens("SGD"),
            fiat24CardAuthorizationMarqeta.XXX24Tokens("JPY"),
            fiat24CardAuthorizationMarqeta.XXX24Tokens("HKD")
        ];
    }

    function setUsd24AlternativeTokens(address[] calldata tokens) external onlyRole(OPERATOR_ROLE) {
        // Validate all tokens are non-zero addresses
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Fiat24AccountView: zero token address");
        }
        usd24AlternativeTokens = tokens;
        emit Usd24AlternativeTokensUpdated(tokens);
    }

    function setFiatTokens(address[] calldata tokens) external onlyRole(OPERATOR_ROLE) {
        require(tokens.length > 0, "Fiat24AccountView: empty tokens array");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(
                fiat24CardAuthorizationMarqeta.validXXX24Tokens(tokens[i]),
                "Fiat24AccountView: invalid XXX24 token"
            );
        }
        fiatTokens = tokens;
        emit FiatTokensUpdated(tokens);
    }

    /// @notice Get the list of all fiat tokens
    /// @return Array of fiat token addresses
    function getFiatTokens() external view returns (address[] memory) {
        return fiatTokens;
    }

    /// @notice Get the list of USD24 alternative tokens
    /// @return Array of alternative token addresses (e.g., USDE)
    function getUsd24AlternativeTokens() external view returns (address[] memory) {
        return usd24AlternativeTokens;
    }

    function accountOwner(uint256 accountId) external view returns (address) {
        return _resolveOwner(accountId);
    }

    function accountBalance(uint256 accountId, address token) external view returns (uint256) {
        return IERC20Upgradeable(token).balanceOf(_resolveOwner(accountId));
    }

    function accountAllowance(uint256 accountId, address token, address spender) external view returns (uint256) {
        return IERC20Upgradeable(token).allowance(_resolveOwner(accountId), spender);
    }

    function accountSnapshot(uint256 accountId, address[] calldata tokenAddresses, address spender)
        external
        view
        returns (address owner, TokenSnapshot[] memory snapshots)
    {
        owner = _resolveOwner(accountId);
        snapshots = new TokenSnapshot[](tokenAddresses.length);
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address token = tokenAddresses[i];
            IERC20Upgradeable erc20 = IERC20Upgradeable(token);
            snapshots[i] = TokenSnapshot({token: token, balance: erc20.balanceOf(owner), allowance: erc20.allowance(owner, spender)});
        }
    }


    function accountCheck(
        uint256 accountId, 
        address cardCurrency_,
        string memory transactionCurrency_, 
        address settlementCurrency_, 
        uint256 transactionAmount_, 
        uint256 settlementAmount_
    ) external view returns (address) {
        address owner = _resolveOwner(accountId);
        address txnToken = fiat24CardAuthorizationMarqeta.XXX24Tokens(transactionCurrency_);
        
        if (fiat24CardAuthorizationMarqeta.validXXX24Tokens(txnToken)) {
            return _checkValidToken(owner, txnToken, transactionAmount_);
        } else {
            return _checkInvalidToken(owner, settlementCurrency_, settlementAmount_);
        }
    }

    /// @notice Check if user has sufficient balance for valid transaction token
    function _checkValidToken(
        address owner,
        address txnToken,
        uint256 transactionAmount
    ) internal view returns (address) {
        // Check if user has sufficient balance in the transaction token
        if (_hasSufficientBalance(owner, txnToken, transactionAmount)) {
            return txnToken;
        }
        
        // Find the token with maximum balance, prioritizing USD24 if it meets requirements
        address bestToken = _findTokenWithMaxBalance(owner, txnToken, transactionAmount, address(0), 0);
        return bestToken != address(0) ? bestToken : usd24Address;
    }

    /// @notice Check balance for invalid transaction token (fallback to EUR)
    function _checkInvalidToken(
        address owner,
        address settlementCurrency,
        uint256 settlementAmount
    ) internal view returns (address) {
        // Validate settlement currency
        if (settlementCurrency != eur24Address) {
            return usd24Address;
        }
        
        // Calculate required EUR amount
        uint256 requiredEurAmount = _calculateRequiredEurAmount(settlementAmount, settlementCurrency, eur24Address);
        
        // Check if user has sufficient EUR balance
        if (_hasSufficientBalance(owner, eur24Address, requiredEurAmount)) {
            return eur24Address;
        }
        
        // Find the token with maximum balance (EUR fallback scenario)
        address bestToken = _findTokenWithMaxBalance(owner, address(0), 0, eur24Address, settlementAmount);
        return bestToken != address(0) ? bestToken : usd24Address;
    }

    /// @notice Find the fiat token with maximum available balance, prioritizing USD24
    /// @param owner The account owner address
    /// @param txnToken Transaction token address (or address(0) for EUR fallback)
    /// @param transactionAmount Transaction amount (or 0 for EUR fallback)
    /// @param settlementToken Settlement token address (EUR24 for fallback, or address(0) for valid token)
    /// @param settlementAmount Settlement amount (or 0 for valid token)
    function _findTokenWithMaxBalance(
        address owner,
        address txnToken,
        uint256 transactionAmount,
        address settlementToken,
        uint256 settlementAmount
    ) internal view returns (address) {
        // Check USD24 + alternative tokens first (only if allowance > 0)
        {
            uint256 usd24Allowance = IERC20Upgradeable(usd24Address).allowance(owner, address(fiat24CardAuthorizationMarqeta));
            if (usd24Allowance != 0) {
                // Calculate required USD24 amount
                uint256 requiredUsd24Amount;
                if (txnToken != address(0) && transactionAmount > 0) {
                    requiredUsd24Amount = _calculateRequiredTokenAmount(txnToken, transactionAmount, usd24Address);
                } else if (settlementToken != address(0) && settlementAmount > 0) {
                    // EUR fallback: use _calculateRequiredEurAmount to include interchange
                    requiredUsd24Amount = _calculateRequiredEurAmount(settlementAmount, usd24Address, settlementToken);
                } else {
                    requiredUsd24Amount = 0;
                }

                uint256 usd24Available = _getAvailableBalance(owner, usd24Address);

                if (usd24Available >= requiredUsd24Amount) {
                    return usd24Address;
                }

                // Check if alternative tokens can cover the shortfall
                if (usd24AlternativeTokens.length > 0 && requiredUsd24Amount > usd24Available) {
                    if (_canAlternativeTokensCoverAmount(owner, usd24Address, requiredUsd24Amount - usd24Available)) {
                        return usd24Address;
                    }
                }
            }
        }
        
        // Find token with maximum USD value that can cover the required amount
        address bestToken = address(0);
        uint256 maxUsdValue = 0;
        
        for (uint256 i = 0; i < fiatTokens.length; i++) {
            address fiatToken = fiatTokens[i];
            if (fiatToken == address(0) || fiatToken == usd24Address) continue;
            
            uint256 availableAmount = _getAvailableBalance(owner, fiatToken);
            if (availableAmount == 0) continue; // Skip tokens with no balance
            
            // Check if this token can cover the required amount
            if (!_canTokenCoverAmount(fiatToken, txnToken, transactionAmount, settlementToken, settlementAmount, availableAmount)) {
                continue;
            }
            
            // Convert to USD value for comparison
            uint256 usdValue = _calculateRequiredTokenAmount(fiatToken, availableAmount, usd24Address);
            
            if (usdValue > maxUsdValue) {
                maxUsdValue = usdValue;
                bestToken = fiatToken;
            }
        }
        
        return bestToken;
    }

    /// @notice Check if a token can cover the required amount
    function _canTokenCoverAmount(
        address fiatToken,
        address txnToken,
        uint256 transactionAmount,
        address settlementToken,
        uint256 settlementAmount,
        uint256 availableAmount
    ) internal view returns (bool) {
        if (!fiat24CardAuthorizationMarqeta.validXXX24Tokens(fiatToken)) {
            return false;
        }

        // Valid token scenario
        if (txnToken != address(0) && transactionAmount > 0) {
            uint256 requiredAmount = _calculateRequiredTokenAmount(txnToken, transactionAmount, fiatToken);
            return availableAmount >= requiredAmount;
        }
        
        // EUR fallback scenario - use Marqeta's formula with interchange
        if (settlementToken != address(0) && settlementAmount > 0) {
            // Formula: settlementAmount * (100 + interchange) * getRate(settlementToken, fiatToken) * getSpread / 10000000000
            uint256 requiredAmount = _calculateRequiredEurAmount(settlementAmount, fiatToken, settlementToken);
            return availableAmount >= requiredAmount;
        }

        return false;
    }

    /// @notice Calculate required amount in target token for a given source amount
    /// @param sourceToken The source token address
    /// @param sourceAmount The amount in source token
    /// @param targetToken The target token address
    /// @return The required amount in target token
    function _calculateRequiredTokenAmount(
        address sourceToken,
        uint256 sourceAmount,
        address targetToken
    ) internal view returns (uint256) {
        // If same token, return as is
        if (sourceToken == targetToken) {
            return sourceAmount;
        }
        
        // Calculate target token equivalent using exchange rate and spread
        uint256 rate = fiat24CardAuthorizationMarqeta.getRate(sourceToken, targetToken);
        uint256 spread = fiat24CardAuthorizationMarqeta.getSpread(sourceToken, targetToken, false);
        
        return sourceAmount * rate * spread / 100000000;
    }

    /// @notice Get available balance for a token
    /// @dev Does NOT include alternative tokens to match Marqeta logic (no accumulation)
    function _getAvailableBalance(
        address owner,
        address token
    ) internal view returns (uint256) {
        uint256 balance = IERC20Upgradeable(token).balanceOf(owner);
        uint256 allowance = IERC20Upgradeable(token).allowance(owner, address(fiat24CardAuthorizationMarqeta));
        return balance < allowance ? balance : allowance;
    }

    /// @notice Check if any single alternative token can cover a required amount
    /// @dev Matches Marqeta contract logic: tries each token individually, no accumulation
    /// @param owner The account owner address
    /// @param outputToken The output token address (e.g., USD24)
    /// @param requiredAmount The required amount in output token
    /// @return True if any alternative token can cover the amount
    function _canAlternativeTokensCoverAmount(
        address owner,
        address outputToken,
        uint256 requiredAmount
    ) internal view returns (bool) {
        for (uint256 j = 0; j < usd24AlternativeTokens.length; j++) {
            address altToken = usd24AlternativeTokens[j];
            if (altToken == address(0)) continue;
            
            // Check if the token pair is active in Marqeta contract
            (, bool isActive) = fiat24CardAuthorizationMarqeta.tokenPairConfigs(altToken, outputToken);
            if (!isActive) continue;
            
            uint256 altBalance = IERC20Upgradeable(altToken).balanceOf(owner);
            uint256 altAllowance = IERC20Upgradeable(altToken).allowance(owner, address(fiat24CardAuthorizationMarqeta));
            uint256 altAvailable = altBalance < altAllowance ? altBalance : altAllowance;
            
            if (altAvailable == 0) continue;
            
            // Get how much altToken is needed for the required output amount
            uint256 requiredInput = fiat24CardAuthorizationMarqeta.getQuoteForTokenPair(altToken, outputToken, requiredAmount);
            
            // If this alternative token can cover the required amount (matches Marqeta logic)
            if (requiredInput > 0 && altAvailable >= requiredInput) {
                return true;
            }
        }
        
        return false;
    }

    /// @notice Check if user has sufficient balance and allowance for a token
    function _hasSufficientBalance(
        address owner,
        address token,
        uint256 requiredAmount
    ) internal view returns (bool) {
        return IERC20Upgradeable(token).balanceOf(owner) >= requiredAmount
            && IERC20Upgradeable(token).allowance(owner, address(fiat24CardAuthorizationMarqeta)) >= requiredAmount;
    }

    /// @notice Calculate required fiat token amount including interchange fee
    /// @dev This matches Marqeta's paidAmount calculation: settlementAmount * (100 + interchange) * getRate * getSpread / 10000000000
    /// @param settlementAmount Original settlement amount (e.g., 100 EUR)
    /// @param targetToken Target fiat token to pay with (e.g., CHF24, EUR24)
    /// @param settlementCurrency Settlement currency (e.g., EUR24)
    /// @return Required amount in target token including interchange and conversion
    function _calculateRequiredEurAmount(
        uint256 settlementAmount,
        address targetToken,
        address settlementCurrency
    ) internal view returns (uint256) {
        uint256 interchange = fiat24CardAuthorizationMarqeta.interchange();
        return settlementAmount * (100 + interchange) * 
            fiat24CardAuthorizationMarqeta.getRate(settlementCurrency, targetToken) * 
            fiat24CardAuthorizationMarqeta.getSpread(settlementCurrency, targetToken, false) / 10000000000;
    }

    function _resolveOwner(uint256 accountId) private view returns (address) {
        require(fiat24Account.exists(accountId), "Fiat24AccountView: unknown accountId");
        return fiat24Account.ownerOf(accountId);
    }
}

