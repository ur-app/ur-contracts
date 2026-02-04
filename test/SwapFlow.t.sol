// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {WithStateTest} from "./WithState.t.sol";

contract SwapFlowTest is WithStateTest {
    function test_swapAlternative_USDC_to_USD24_success() public {
        // Arrange: set alternative input tokens for USD24
        vm.prank(admin);
        marqeta.setAlternativeInputTokens(address(usd), _oneAddrArray(address(usdc)));

        // Treasury and desks
        address desk = account.ownerOf(9105);

        // Desk approves USD24 for Marqeta to transfer to users
        vm.prank(desk);
        usd.approve(address(marqeta), type(uint256).max);

        // User has little USD24 but enough USDC
        // Reset user USD24 to 50.00 (2 decimals)
        vm.startPrank(user);
        // grant large allowance on USD24 and USDC to Marqeta
        usd.approve(address(marqeta), type(uint256).max);
        usdc.approve(address(marqeta), type(uint256).max);
        vm.stopPrank();

        // Mint balances as needed
        vm.prank(admin);
        usd.mint(5_000);      // 50.00 (additional)
        vm.prank(account.ownerOf(9101));
        usd.transfer(user, 5_000);
        usdc.mint(user, 1_000_000_000); // 1,000 USDC

        // Act: call authorize with txnCurrency = EUR (user has 0 EUR24), cardCurrency = USD24
        // Treasury address is already set in WithStateTest.setUp(), no need to set it again

        // EUR token is already added from initialization, so skip addFiatToken

        // USD and EUR tokens are already valid from initialization, so skip setValidXXX24Token

        // Execute authorize; numbers chosen to force shortfall and trigger alternative swap
        vm.prank(admin);
        marqeta.authorize(
            "AUTH1",
            "CARD1",
            1001,
            address(usd),
            "EUR",
            address(eur),
            10_000, // 100.00 EUR24 worth
            0
        );
    }

    function _oneAddrArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}


