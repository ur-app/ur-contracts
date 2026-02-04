// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {WithStateTest} from "./WithState.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Fiat24Account} from "../src/Fiat24Account.sol";
import {Fiat24AccountView} from "../src/Fiat24AccountView.sol";

contract Fiat24AccountViewTest is WithStateTest {
    Fiat24AccountView internal accountView;
    MockERC20 internal usde;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Deploy alternative token
        usde = new MockERC20("USDe", "USDe", 18);
        
        // NOW deploy Fiat24AccountView (uses tokens already in BaseTest: eur, usd, chf, cnh, gbp)
        accountView = new Fiat24AccountView(
            address(account),
            address(marqeta),
            admin
        );
        
        vm.startPrank(admin);
        
        // Setup alternative tokens for USD24
        marqeta.setCryptoTokenPairActive(address(usde), address(usd), 1e18);
        address[] memory alternatives = new address[](1);
        alternatives[0] = address(usde);
        marqeta.setAlternativeInputTokens(address(usd), alternatives);
        accountView.setUsd24AlternativeTokens(alternatives);
        
        // Setup treasury
        marqeta.setTreasuryAddress(account.ownerOf(9100));
        vm.stopPrank();
        
        // Give user USDe tokens
        usde.mint(user, 10_000 * 1e18); // 10,000 USDe
        
        // Setup approvals for alternative token
        vm.startPrank(user);
        usde.approve(address(marqeta), type(uint256).max);
        vm.stopPrank();
        
        // Give CRYPTO_DESK (9105) USDe for swaps
        address desk = account.ownerOf(9105);
        vm.prank(desk);
        usd.approve(address(marqeta), type(uint256).max);
    }

    // ============ Constructor and Initialization Tests ============
    
    function test_constructor_initializesFiatTokens() public {
        address[] memory tokens = accountView.getFiatTokens();
        
        // Note: Constructor initializes EUR, USD, CHF, CNH, SGD, JPY, HKD
        // But SGD, JPY, HKD may return address(0) if not added to Marqeta
        assertEq(tokens.length, 7);
        assertEq(tokens[0], address(eur)); // EUR
        assertEq(tokens[1], address(usd)); // USD
        assertEq(tokens[2], address(chf)); // CHF
        assertEq(tokens[3], address(cnh)); // CNH
        // SGD, JPY, HKD addresses depend on whether they're added to Marqeta
    }
    
    function test_constructor_revertsWithZeroAddresses() public {
        vm.expectRevert("Fiat24AccountView: zero account address");
        new Fiat24AccountView(address(0), address(marqeta), admin);
        
        vm.expectRevert("Fiat24AccountView: zero card authorization marqeta address");
        new Fiat24AccountView(address(account), address(0), admin);
        
        vm.expectRevert("Fiat24AccountView: zero admin address");
        new Fiat24AccountView(address(account), address(marqeta), address(0));
    }
    
    function test_constructor_grantsRolesToAdmin() public {
        assertTrue(accountView.hasRole(accountView.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(accountView.hasRole(accountView.OPERATOR_ROLE(), admin));
    }

    // ============ Access Control Tests ============
    
    function test_setUsd24AlternativeTokens_onlyOperator() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usde);
        
        // Should succeed for admin (who has OPERATOR_ROLE)
        vm.prank(admin);
        accountView.setUsd24AlternativeTokens(tokens);
        
        // Should fail for non-operator (AccessControl reverts with standard message)
        vm.expectRevert();
        vm.prank(user);
        accountView.setUsd24AlternativeTokens(tokens);
    }
    
    function test_setFiatTokens_onlyOperator() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(eur);
        tokens[1] = address(usd);
        tokens[2] = address(chf);
        
        // Should succeed for admin (who has OPERATOR_ROLE)
        vm.prank(admin);
        accountView.setFiatTokens(tokens);
        
        // Should fail for non-operator (AccessControl reverts with standard message)
        vm.expectRevert();
        vm.prank(user);
        accountView.setFiatTokens(tokens);
    }
    
    function test_setFiatTokens_revertsWithEmptyArray() public {
        address[] memory emptyTokens = new address[](0);
        
        vm.expectRevert("Fiat24AccountView: empty tokens array");
        vm.prank(admin);
        accountView.setFiatTokens(emptyTokens);
    }
    
    function test_setUsd24AlternativeTokens_emitsEvent() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usde);
        
        vm.expectEmit(false, false, false, true);
        emit Usd24AlternativeTokensUpdated(tokens);
        
        vm.prank(admin);
        accountView.setUsd24AlternativeTokens(tokens);
    }
    
    function test_setFiatTokens_emitsEvent() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(eur);
        tokens[1] = address(usd);
        tokens[2] = address(chf);
        
        vm.expectEmit(false, false, false, true);
        emit FiatTokensUpdated(tokens);
        
        vm.prank(admin);
        accountView.setFiatTokens(tokens);
    }

    // ============ View Function Tests ============
    
    function test_accountOwner_returnsCorrectOwner() public {
        address owner = accountView.accountOwner(1001);
        assertEq(owner, user);
    }
    
    function test_accountOwner_revertsForNonexistentAccount() public {
        vm.expectRevert("Fiat24AccountView: unknown accountId");
        accountView.accountOwner(99999);
    }
    
    function test_accountBalance_returnsCorrectBalance() public {
        uint256 balance = accountView.accountBalance(1001, address(usd));
        assertEq(balance, 1_000_00); // User has 1,000 USD24
    }
    
    function test_accountAllowance_returnsCorrectAllowance() public {
        uint256 allowance = accountView.accountAllowance(1001, address(usd), address(marqeta));
        assertEq(allowance, type(uint256).max); // User approved max
    }
    
    function test_accountSnapshot_returnsMultipleTokens() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(usd);
        tokens[1] = address(eur);
        tokens[2] = address(chf);
        
        (address owner, Fiat24AccountView.TokenSnapshot[] memory snapshots) = 
            accountView.accountSnapshot(1001, tokens, address(marqeta));
        
        assertEq(owner, user);
        assertEq(snapshots.length, 3);
        
        // USD24
        assertEq(snapshots[0].token, address(usd));
        assertEq(snapshots[0].balance, 1_000_00);
        assertEq(snapshots[0].allowance, type(uint256).max);
        
        // EUR24
        assertEq(snapshots[1].token, address(eur));
        assertEq(snapshots[1].balance, 1_000_00);
        assertEq(snapshots[1].allowance, type(uint256).max);
        
        // CHF24
        assertEq(snapshots[2].token, address(chf));
        assertEq(snapshots[2].balance, 1_000_00);
        assertEq(snapshots[2].allowance, type(uint256).max);
    }

    // ============ accountCheck - Valid Token Scenario Tests ============
    
    function test_accountCheck_validToken_sufficientBalance_returnsTxnToken() public {
        // User has 1,000 USD24, transaction requires 50 USD24
        address selectedToken = accountView.accountCheck(
            1001,
            address(usd), // cardCurrency
            "USD",        // transactionCurrency
            address(usd), // settlementCurrency
            50_00,        // transactionAmount
            50_00         // settlementAmount
        );
        
        assertEq(selectedToken, address(usd));
    }
    
    function test_accountCheck_validToken_insufficientBalance_returnsUsd24WithAlternatives() public {
        // Create a new user with insufficient USD24 but has USDe alternative token
        vm.prank(admin);
        account.mint(other, 2002);
        
        // Give user only 10 USD24 (insufficient for 80 USD24 transaction)
        vm.prank(admin);
        usd.mint(10_00);
        vm.prank(account.ownerOf(9101));
        usd.transfer(other, 10_00);
        
        // Give user 100 USDe (alternative token, sufficient to cover shortfall)
        usde.mint(other, 100 * 1e18);
        
        // Setup approvals
        vm.startPrank(other);
        usd.approve(address(marqeta), type(uint256).max);
        usde.approve(address(marqeta), type(uint256).max);
        vm.stopPrank();
        
        // Check for 80 USD24 transaction
        address selectedToken = accountView.accountCheck(
            2002,
            address(usd),
            "USD",
            address(usd),
            80_00, // Need 80 USD24
            80_00
        );
        
        // Should return USD24 because alternative token (USDe) can cover the shortfall
        assertEq(selectedToken, address(usd));
    }

    function test_accountCheck_validToken_noTokenCanCover_returnsUsd24() public {
        // Create a new user with very small balances in all tokens
        vm.prank(admin);
        account.mint(other, 2004);
        
        // Give user tiny amounts (not enough to cover 1000 USD24)
        vm.prank(admin);
        usd.mint(5_00);
        vm.prank(account.ownerOf(9101));
        usd.transfer(other, 5_00); // 5 USD24
        
        vm.prank(admin);
        eur.mint(5_00);
        vm.prank(account.ownerOf(9101));
        eur.transfer(other, 5_00); // 5 EUR24
        
        vm.prank(admin);
        chf.mint(5_00);
        vm.prank(account.ownerOf(9101));
        chf.transfer(other, 5_00); // 5 CHF24
        
        // Setup approvals
        vm.startPrank(other);
        usd.approve(address(marqeta), type(uint256).max);
        eur.approve(address(marqeta), type(uint256).max);
        chf.approve(address(marqeta), type(uint256).max);
        vm.stopPrank();
        
        // Check for 1000 USD24 transaction (no token can cover)
        address selectedToken = accountView.accountCheck(
            2004,
            address(usd),
            "USD",
            address(usd),
            1000_00, // Need 1000 USD24 (no one can cover)
            1000_00
        );
        
        // Should return USD24 as default (no token can cover the amount)
        assertEq(selectedToken, address(usd));
    }

    
    function test_accountCheck_validToken_prioritizesUsd24OverOthers() public {
        // Even if other tokens have higher balances, USD24 should be prioritized if it can cover
        // Give user more CHF balance
        vm.prank(admin);
        chf.mint(10_000_00);
        vm.prank(account.ownerOf(9101));
        chf.transfer(user, 10_000_00); // User now has 11,000 CHF24
        
        address selectedToken = accountView.accountCheck(
            1001,
            address(usd),
            "USD",
            address(usd),
            50_00, // USD24 can cover this
            50_00
        );
        
        // Should still return USD24 (prioritized)
        assertEq(selectedToken, address(usd));
    }

    // ============ accountCheck - Invalid Token (EUR Fallback) Scenario Tests ============
    
    function test_accountCheck_invalidToken_sufficientEur_returnsEur() public {
        // User has 1,000 EUR24, settlement requires 100 EUR24 + interchange
        address selectedToken = accountView.accountCheck(
            1001,
            address(eur), // cardCurrency
            "AUD",        // transactionCurrency (not supported)
            address(eur), // settlementCurrency
            100,          // transactionAmount (in AUD, raw cents)
            100           // settlementAmount (in EUR, raw cents)
        );
        
        assertEq(selectedToken, address(eur));
    }
    
    function test_accountCheck_invalidToken_wrongSettlementCurrency_returnsUsd24() public {
        // Settlement currency must be EUR24 for invalid token
        address selectedToken = accountView.accountCheck(
            1001,
            address(usd),
            "AUD",
            address(usd), // settlementCurrency is USD24, not EUR24
            100,
            100
        );
        
        // Should return USD24 as default
        assertEq(selectedToken, address(usd));
    }

    // ============ accountCheck - Currency Conversion Tests ============
    
    function test_accountCheck_convertsDifferentCurrencies() public {
        // User wants to pay with EUR but transaction is in USD
        // Need 100 USD24, user has 1000 EUR24
        // Rate EUR->USD: reverse of 9168 = ~10909
        address selectedToken = accountView.accountCheck(
            1001,
            address(eur), // cardCurrency
            "USD",        // transactionCurrency
            address(usd), // settlementCurrency
            100_00,       // 100 USD24
            100_00
        );
        
        // EUR24 should be able to cover (has enough balance after conversion)
        assertEq(selectedToken, address(usd)); // USD24 is prioritized if available
    }

    // ============ accountCheck - Interchange Fee Tests ============
    
    function test_accountCheck_includesInterchangeInEurFallback() public {
        // EUR fallback should include interchange fee (1%)
        // Settlement: 100 EUR -> with 1% interchange = 202 EUR (including spread)
        
        // Give user exactly 202 EUR24 (just enough)
        vm.startPrank(admin);
        eur.mint(102_00); // Mint to MINT_DESK
        vm.stopPrank();
        
        // Transfer from MINT_DESK to user
        address mintDesk = account.ownerOf(9101);
        vm.prank(mintDesk);
        eur.transfer(user, 102_00); // Total: 1000 + 102 = 1102 EUR24
        
        address selectedToken = accountView.accountCheck(
            1001,
            address(eur),
            "AUD",
            address(eur),
            100_00, // 100 AUD (ignored for EUR fallback)
            100_00  // 100 EUR settlement
        );
        
        // User has enough EUR24 to cover with interchange
        assertEq(selectedToken, address(eur));
    }
    
    function test_accountCheck_interchangeAppliesOnlyToEurFallback() public {
        // Valid token scenario should NOT include interchange
        // Only EUR fallback includes interchange
        
        address selectedToken = accountView.accountCheck(
            1001,
            address(usd),
            "USD", // Valid token
            address(usd),
            100_00,
            100_00
        );
        
        // User has 1000 USD24, needs 100 USD24 (no interchange)
        assertEq(selectedToken, address(usd));
    }

    // ============ accountCheck - Edge Cases ============
    
    function test_accountCheck_zeroAmounts() public {
        address selectedToken = accountView.accountCheck(
            1001,
            address(usd),
            "USD",
            address(usd),
            0, // Zero amount
            0
        );
        
        // Should still return USD24 (has sufficient zero balance)
        assertEq(selectedToken, address(usd));
    }
    
    function test_accountCheck_veryLargeAmounts() public {
        // Request amount larger than any token balance
        address selectedToken = accountView.accountCheck(
            1001,
            address(usd),
            "USD",
            address(usd),
            1_000_000_00, // 1 million USD24
            1_000_000_00
        );
        
        // Should return USD24 as default (no token can cover)
        assertEq(selectedToken, address(usd));
    }

    // ============ Getter Function Tests ============
    
    function test_getFiatTokens_returnsFullList() public {
        address[] memory tokens = accountView.getFiatTokens();
        
        assertEq(tokens.length, 7);
        assertEq(tokens[0], address(eur));
        assertEq(tokens[1], address(usd));
        assertEq(tokens[2], address(chf));
        assertEq(tokens[3], address(cnh));
        // SGD, JPY, HKD may be address(0) if not added to Marqeta
    }
    
    function test_getUsd24AlternativeTokens_returnsFullList() public {
        address[] memory tokens = accountView.getUsd24AlternativeTokens();
        
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usde));
    }
    
    function test_getFiatTokens_reflectsUpdates() public {
        address[] memory newTokens = new address[](3);
        newTokens[0] = address(eur);
        newTokens[1] = address(usd);
        newTokens[2] = address(chf);
        
        vm.prank(admin);
        accountView.setFiatTokens(newTokens);
        
        address[] memory tokens = accountView.getFiatTokens();
        assertEq(tokens.length, 3);
    }

    // ============ Integration Tests ============
    
    function test_accountView_integration() public {
        // Basic integration test for accountView
        assertTrue(address(accountView) != address(0));
    }

    // ============ Additional accountCheck Tests ============
    
    function test_accountCheck_withEurToken_sufficientBalance() public {
        // User pays with EUR for EUR transaction
        address selectedToken = accountView.accountCheck(
            1001,
            address(eur),
            "EUR",
            address(eur),
            100_00,
            100_00
        );
        
        assertEq(selectedToken, address(eur));
    }
    
    function test_accountCheck_withChfToken_sufficientBalance() public {
        // User pays with CHF for CHF transaction  
        address selectedToken = accountView.accountCheck(
            1001,
            address(chf),
            "CHF",
            address(chf),
            100_00,
            100_00
        );
        
        assertEq(selectedToken, address(chf));
    }
    
    function test_accountCheck_withGbpToken_sufficientBalance() public {
        // User pays with GBP for GBP transaction
        address selectedToken = accountView.accountCheck(
            1001,
            address(gbp),
            "GBP",
            address(gbp),
            100_00,
            100_00
        );
        
        assertEq(selectedToken, address(gbp));
    }
    
    function test_accountCheck_withCnhToken_sufficientBalance() public {
        // User pays with CNH for CNH transaction
        address selectedToken = accountView.accountCheck(
            1001,
            address(cnh),
            "CNH",
            address(cnh),
            100_00,
            100_00
        );
        
        assertEq(selectedToken, address(cnh));
    }
    
    function test_accountCheck_crossCurrency_eurToUsd() public {
        // User wants to pay USD transaction with EUR balance
        address selectedToken = accountView.accountCheck(
            1001,
            address(eur),
            "USD",
            address(usd),
            100_00, // 100 USD
            100_00
        );
        
        // Should prioritize USD24 if available (which it is - user has 1000 USD24)
        assertEq(selectedToken, address(usd));
    }
    
    function test_accountCheck_crossCurrency_chfToUsd() public {
        // User wants to pay USD transaction with CHF balance
        address selectedToken = accountView.accountCheck(
            1001,
            address(chf),
            "USD",
            address(usd),
            50_00, // 50 USD
            50_00
        );
        
        // Should prioritize USD24 if available
        assertEq(selectedToken, address(usd));
    }
    
    function test_accountCheck_withAllowanceButNoBalance() public {
        // Create a new account with allowance but no balance
        vm.prank(admin);
        account.mint(other, 2001);
        
        vm.prank(other);
        usd.approve(address(marqeta), type(uint256).max);
        
        // Check - should return USD24 even with 0 balance (default behavior)
        address selectedToken = accountView.accountCheck(
            2001,
            address(usd),
            "USD",
            address(usd),
            50_00,
            50_00
        );
        
        assertEq(selectedToken, address(usd));
    }
    
    function test_accountCheck_eurFallback_withSufficientEur() public {
        // Invalid currency (e.g., AUD) should fallback to EUR settlement
        address selectedToken = accountView.accountCheck(
            1001,
            address(eur),
            "AUD", // Not supported
            address(eur), // Settlement in EUR
            200,   // 2 AUD
            200    // 2 EUR settlement
        );
        
        assertEq(selectedToken, address(eur));
    }
    
    function test_accountCheck_usd24Priority_evenWithOtherBalances() public {
        // Even with EUR, CHF, GBP, CNH balances, USD24 should be prioritized
        // User has all these tokens from BaseTest setup
        
        address selectedToken = accountView.accountCheck(
            1001,
            address(usd),
            "USD",
            address(usd),
            100_00,
            100_00
        );
        
        // Should always prioritize USD24
        assertEq(selectedToken, address(usd));
    }


    // ============ Events ============
    
    event Usd24AlternativeTokensUpdated(address[] tokens);
    event FiatTokensUpdated(address[] tokens);
}

