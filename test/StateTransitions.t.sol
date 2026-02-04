// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {WithStateTest} from "./WithState.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StateTransitionsTest is WithStateTest {
    MockERC20 internal usde;

    function setUp() public virtual override {
        super.setUp();

        usde = new MockERC20("USDe", "USDe", 18);
        usde.mint(user, 1000 * 1e18);

        vm.prank(user);
        usde.approve(address(marqeta), type(uint256).max);
    }

    // ============ Token Pair State Transitions ============

    function test_stateTransition_tokenPairActivation() public {
        // Initially inactive (pair not configured yet)
        uint256 quote1 = marqeta.getQuoteForTokenPair(address(usde), address(usd), 100);
        assertEq(quote1, 0, "Inactive pair should return 0");

        // Activate the token pair (exchange rate must be between 0.95e18 and 1.05e18)
        vm.prank(admin);
        marqeta.setCryptoTokenPairActive(address(usde), address(usd), 1.0e18);

        uint256 quote2 = marqeta.getQuoteForTokenPair(address(usde), address(usd), 100);
        assertGt(quote2, 0, "Active pair should return > 0");
    }

    function test_stateTransition_tokenValidityToggle() public {
        // Make USDe valid
        vm.prank(admin);
        marqeta.setValidXXX24Token(address(usde), true);
        assertTrue(marqeta.validXXX24Tokens(address(usde)));

        // Make it invalid
        vm.prank(admin);
        marqeta.setValidXXX24Token(address(usde), false);
        assertFalse(marqeta.validXXX24Tokens(address(usde)));

        // Make it valid again
        vm.prank(admin);
        marqeta.setValidXXX24Token(address(usde), true);
        assertTrue(marqeta.validXXX24Tokens(address(usde)));
    }

    // ============ Market State Transitions ============

    function test_stateTransition_marketClosedSpreadChanges() public {
        uint256 openSpread = marqeta.getSpread(address(usd), address(eur), false);

        // Close market
        vm.prank(admin);
        marqeta.setMarketClosed(true);

        uint256 closedSpread = marqeta.getSpread(address(usd), address(eur), false);

        // Closed market should have different (typically worse) spread
        assertNotEq(openSpread, closedSpread);

        // Reopen market
        vm.prank(admin);
        marqeta.setMarketClosed(false);

        uint256 reopenSpread = marqeta.getSpread(address(usd), address(eur), false);
        assertEq(openSpread, reopenSpread, "Reopened market should match original spread");
    }

    // ============ Treasury State Transitions ============

    function test_stateTransition_treasuryAddressChange() public {
        address oldTreasury = marqeta.treasuryAddress();
        address newTreasury = address(0x1234);

        vm.prank(admin);
        marqeta.setTreasuryAddress(newTreasury);

        assertEq(marqeta.treasuryAddress(), newTreasury);
        assertNotEq(marqeta.treasuryAddress(), oldTreasury);
    }

    // ============ Alternative Token List State Changes ============

    function test_stateTransition_alternativeTokensUpdate() public {
        // Set initial alternatives
        address[] memory initial = new address[](1);
        initial[0] = address(usde);

        vm.prank(admin);
        marqeta.setAlternativeInputTokens(address(usd), initial);

        assertEq(marqeta.alternativeInputTokens(address(usd), 0), address(usde));

        // Update to different set
        address[] memory updated = new address[](2);
        updated[0] = address(usdc);
        updated[1] = address(usde);

        vm.prank(admin);
        marqeta.setAlternativeInputTokens(address(usd), updated);

        assertEq(marqeta.alternativeInputTokens(address(usd), 0), address(usdc));
        assertEq(marqeta.alternativeInputTokens(address(usd), 1), address(usde));
    }

    // ============ Pause State Transitions ============

    function test_stateTransition_pauseUnpauseFlow() public {
        vm.startPrank(admin);
        marqeta.grantRole(marqeta.PAUSE_ROLE(), admin);
        marqeta.grantRole(marqeta.UNPAUSE_ROLE(), admin);

        assertFalse(marqeta.paused());

        marqeta.pause();
        assertTrue(marqeta.paused());

        marqeta.unpause();
        assertFalse(marqeta.paused());
        vm.stopPrank();
    }

    function test_stateTransition_pausedBlocksAuthorize() public {
        vm.startPrank(admin);
        marqeta.grantRole(marqeta.PAUSE_ROLE(), admin);
        marqeta.pause();

        vm.expectRevert();
        marqeta.authorize("AUTH001", "CARD001", 1001, address(usd), "USD", address(usd), 50_00, 50_00);
        vm.stopPrank();
    }

    // ============ Exchange Rate State Transitions ============

    function test_stateTransition_exchangeRateUpdates() public {
        uint256 oldRate = marqeta.exchangeRates(address(usd), address(eur));
        uint256 newRate = 9500;

        // RATES_UPDATER_OPERATOR_ROLE is already granted to admin in BaseTest

        address[] memory tokens = new address[](1);
        tokens[0] = address(eur);
        uint256[] memory rates = new uint256[](1);
        rates[0] = newRate;

        vm.prank(admin);
        marqeta.updateExchangeRates(tokens, rates, false);

        assertEq(marqeta.exchangeRates(address(usd), address(eur)), newRate);
        assertNotEq(marqeta.exchangeRates(address(usd), address(eur)), oldRate);
    }

    // ============ Multiple State Changes in Sequence ============

    function test_stateTransition_multipleConfigChanges() public {
        vm.startPrank(admin);

        // Configure token pair (activate) - exchange rate must be between 0.95e18 and 1.05e18
        marqeta.setCryptoTokenPairActive(address(usde), address(usd), 1.0e18);

        // Change rate (requires pair to be active) - must be between 0.95e18 and 1.05e18
        marqeta.setTokenPairExchangeRate(address(usde), address(usd), 1.05e18);

        // Deactivate
        marqeta.grantRole(marqeta.CLOSE_CRYPTO_TOKEN_PAIR_ROLE(), admin);
        marqeta.closeCryptoTokenPair(address(usde), address(usd));

        // Reactivate with new rate - must be between 0.95e18 and 1.05e18
        marqeta.setCryptoTokenPairActive(address(usde), address(usd), 0.98e18);

        vm.stopPrank();

        (uint256 finalRate, bool finalActive) = marqeta.tokenPairConfigs(address(usde), address(usd));
        assertEq(finalRate, 0.98e18);
        assertTrue(finalActive);
    }
}
