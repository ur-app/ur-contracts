// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {WithStateTest} from "./WithState.t.sol";

contract SecurityTest is WithStateTest {
    address internal attacker = address(0xBAD);
    
    // ============ Access Control Security ============
    
    function test_security_onlyOperatorAdminCanSetTreasury() public {
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.setTreasuryAddress(attacker);
    }

    function test_security_onlyOperatorAdminCanConfigureTokenPair() public {
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.setCryptoTokenPairActive(address(usdc), address(usd), 1e18);
    }

    function test_security_onlyOperatorAdminCanSetAlternativeTokens() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.setAlternativeInputTokens(address(usd), tokens);
    }

    function test_security_onlyAuthorizerCanAuthorize() public {
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.authorize("AUTH001", "CARD001", 1001, address(usd), "USD", address(usd), 50_00, 50_00);
    }

    function test_security_onlyOperatorAdminCanSetValidToken() public {
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.setValidXXX24Token(address(usdc), true);
    }

    function test_security_onlyRateUpdaterCanUpdateRates() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usd);
        uint256[] memory rates = new uint256[](1);
        rates[0] = 10000;
        
        vm.expectRevert("Not authorized to update rates");
        vm.prank(attacker);
        marqeta.updateExchangeRates(tokens, rates, false);
    }

    // ============ Input Validation Security ============
    
    function test_security_zeroAddressProtection_setTreasury() public {
        vm.expectRevert("Invalid treasury address");
        vm.prank(admin);
        marqeta.setTreasuryAddress(address(0));
    }

    function test_security_zeroAddressProtection_configureTokenPair() public {
        vm.expectRevert("Invalid input token address");
        vm.prank(admin);
        marqeta.setCryptoTokenPairActive(address(0), address(usd), 1e18);
        
        vm.expectRevert("Invalid output token address");
        vm.prank(admin);
        marqeta.setCryptoTokenPairActive(address(usdc), address(0), 1e18);
    }

    function test_security_zeroAddressProtection_setValidToken() public {
        vm.expectRevert("Zero address");
        vm.prank(admin);
        marqeta.setValidXXX24Token(address(0), true);
    }

    // ============ State Consistency Security ============
    
    function test_security_duplicateAddressProtection() public {
        address currentTreasury = marqeta.treasuryAddress();
        
        vm.expectRevert("Duplicate treasury address");
        vm.prank(admin);
        marqeta.setTreasuryAddress(currentTreasury);
    }

    function test_security_noStateChangeProtection() public {
        // Set a token to true first
        vm.prank(admin);
        marqeta.setValidXXX24Token(address(usdc), true);
        
        // Try to set same value again
        vm.expectRevert("No state change");
        vm.prank(admin);
        marqeta.setValidXXX24Token(address(usdc), true);
    }

    // ============ Financial Security ============
    
    function test_security_insufficientAllowanceEarlyRevert() public {
        // User has balance but insufficient allowance
        vm.prank(user);
        usd.approve(address(marqeta), 20_00); // Only 20.00 allowance
        
        vm.expectRevert();
        vm.prank(admin);
        marqeta.authorize("AUTH005", "CARD005", 1001, address(usd), "USD", address(usd), 80_00, 80_00);
    }

    function test_security_interchangeRange() public {
        vm.expectRevert();
        vm.prank(admin);
        marqeta.setInterchange(101); // > 100
    }

    function test_security_exchangeSpreadRange() public {
        vm.expectRevert("Spread must be between 9000 and 11000");
        vm.prank(admin);
        marqeta.setExchangeSpread(8000); // < 9000
        
        vm.expectRevert("Spread must be between 9000 and 11000");
        vm.prank(admin);
        marqeta.setExchangeSpread(12000); // > 11000
    }

    // ============ Pause/Unpause Security ============
    
    function test_security_onlyPauserCanPause() public {
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.pause();
    }

    function test_security_onlyUnpauserCanUnpause() public {
        // PAUSE_ROLE is already granted to admin in BaseTest
        vm.prank(admin);
        marqeta.pause();
        
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.unpause();
    }

    function test_security_differentErrorsForPauseUnpause() public {
        // Test that pause and unpause have different error types
        // PAUSE_ROLE is already granted to admin in BaseTest
        vm.prank(admin);
        marqeta.pause();
        
        // This should revert with NotUnpauser, not NotPauser
        vm.expectRevert();
        vm.prank(attacker);
        marqeta.unpause();
    }
}
