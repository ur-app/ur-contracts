// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {BaseTest} from "./BaseTest.t.sol";
import {Fiat24Account} from "../src/Fiat24Account.sol";

contract Fiat24AccountTest is BaseTest {
    address internal operator = address(0xDEAD);
    address internal minter = address(0xFEED);
    address internal walletProvider = address(0xABCD);
    address internal cashOperator = address(0xCA5E);

    function setUp() public virtual override {
        super.setUp();
        
        vm.startPrank(admin);
        account.grantRole(account.OPERATOR_ROLE(), operator);
        account.grantRole(account.MINTER_ROLE(), minter);
        account.grantRole(account.OPERATOR_MINT_ROLE(), cashOperator);
        
        // Setup wallet provider
        account.mint(walletProvider, 8001);
        account.addWalletProvider(8001, "TestWallet");
        vm.stopPrank();
    }

    function test_mint_success() public {
        vm.prank(operator);
        account.mint(other, 1002);
        
        assertEq(account.ownerOf(1002), other);
        assertEq(uint256(account.status(1002)), uint256(Fiat24Account.Status.Tourist));
        assertEq(account.nickNames(1002), "Account 1002");
    }

    function test_mint_revertsIfNotOperator() public {
        vm.expectRevert("Not an operator/minter");
        vm.prank(user);
        account.mint(other, 1003);
    }

    function test_changeClientStatus_touristToLive() public {
        vm.prank(operator);
        account.mint(other, 1004);
        
        // Change from Tourist to Live
        vm.prank(operator);
        account.changeClientStatus(1004, Fiat24Account.Status.Live);
        
        assertEq(uint256(account.status(1004)), uint256(Fiat24Account.Status.Live));
        assertEq(account.historicOwnership(other), 1004);
    }

    function test_changeClientStatus_revertsIfNotAuthorized() public {
        vm.expectRevert("Not an operator/clientstatuschange");
        vm.prank(user);
        account.changeClientStatus(1001, Fiat24Account.Status.Live);
    }

    function test_close_success() public {
        // First make account Live
        vm.prank(operator);
        account.changeClientStatus(1001, Fiat24Account.Status.Live);
        
        // User can close their own account
        vm.prank(user);
        account.close(1001);
        
        assertEq(uint256(account.status(1001)), uint256(Fiat24Account.Status.Closed));
    }

    function test_close_revertsIfNotOwner() public {
        vm.prank(operator);
        account.changeClientStatus(1001, Fiat24Account.Status.Live);
        
        vm.expectRevert("Not account owner");
        vm.prank(other);
        account.close(1001);
    }

    function test_close_revertsIfNotLive() public {
        // Create a new Tourist account for this test
        vm.prank(operator);
        account.mint(other, 2001);
        
        // Account 2001 is Tourist by default
        vm.expectRevert("Not live client");
        vm.prank(other);
        account.close(2001);
    }

    function test_mintByWallet_success() public {
        vm.deal(other, 1 ether);
        vm.deal(walletProvider, 1 ether);  // Give walletProvider ETH for the fee
        
        vm.prank(admin);
        account.setMintFee(0.1 ether);
        vm.prank(admin);
        account.setFeeReceiver(admin);
        
        // mintByWallet function is disabled
        vm.expectRevert("This function is disabled");
        vm.prank(walletProvider);
        account.mintByWallet{value: 0.1 ether}(other, 12345);
    }

    function test_mintByWallet_revertsInsufficientFee() public {
        vm.deal(other, 1 ether);
        vm.deal(walletProvider, 1 ether);  // Give walletProvider ETH for the fee
        
        vm.prank(admin);
        account.setMintFee(0.1 ether);
        
        // mintByWallet function is disabled, so it reverts with that message first
        vm.expectRevert("This function is disabled");
        vm.prank(walletProvider);
        account.mintByWallet{value: 0.05 ether}(other, 12346);
    }

    function test_checkLimit_tourist() public {
        // Tourist has default limit
        bool canSpend = account.checkLimit(1001, 50000); // 500.00 (assuming 2 decimals)
        assertTrue(canSpend);
        
        bool cannotSpend = account.checkLimit(1001, 200000); // 2000.00 > tourist limit
        assertFalse(cannotSpend);
    }

    function test_updateLimit_success() public {
        // Get current usedLimit before update
        (uint256 currentUsedLimit,,) = account.limit(1001);
        
        // USD token already has LIMITUPDATER_ROLE from BaseTest setup
        vm.prank(address(usd));
        account.updateLimit(1001, 10000); // Add 100.00
        
        (uint256 newUsedLimit,,) = account.limit(1001);
        assertEq(newUsedLimit, currentUsedLimit + 10000);
    }

    function test_updateLimit_revertsIfNotAuthorized() public {
        vm.expectRevert("Not a limit-updater");
        vm.prank(user);
        account.updateLimit(1001, 10000);
    }

    function test_setNickname_success() public {
        vm.prank(user);
        account.setNickname(1001, "MyAccount");
        
        assertEq(account.nickNames(1001), "MyAccount");
    }

    function test_setNickname_revertsIfNotOwner() public {
        vm.expectRevert("Not account owner");
        vm.prank(other);
        account.setNickname(1001, "NotMyAccount");
    }

    function test_transferFrom_updatesHistoricOwnership() public {
        // Change to Live first
        vm.prank(operator);
        account.changeClientStatus(1001, Fiat24Account.Status.Live);
        
        vm.prank(user);
        account.transferFrom(user, other, 1001);
        
        assertEq(account.ownerOf(1001), other);
        assertEq(account.historicOwnership(other), 1001);
    }

    function test_transferFrom_touristDoesNotUpdateHistoric() public {
        // Create a new Tourist account for this test using a fresh address
        address freshUser = address(0x1234);
        vm.prank(operator);
        account.mint(freshUser, 3001);
        
        // Account 3001 is Tourist by default, transfer it
        vm.prank(freshUser);
        account.transferFrom(freshUser, other, 3001);
        
        assertEq(account.ownerOf(3001), other);
        assertEq(account.historicOwnership(other), 0); // Not updated for Tourist
    }

    function test_burn_success() public {
        vm.prank(operator);
        account.burn(1001);
        
        vm.expectRevert("ERC721: owner query for nonexistent token");
        account.ownerOf(1001);
    }

    function test_burn_revertsIfNotOperator() public {
        vm.expectRevert("Not an operator");
        vm.prank(user);
        account.burn(1001);
    }

    function test_exists_returnsCorrectly() public {
        assertTrue(account.exists(1001));
        assertFalse(account.exists(9999));
    }

    function test_removeHistoricOwnership_success() public {
        // First set historic ownership
        vm.prank(operator);
        account.changeClientStatus(1001, Fiat24Account.Status.Live);
        
        vm.prank(operator);
        account.removeHistoricOwnership(user);
        
        assertEq(account.historicOwnership(user), 0);
    }

    function test_addWalletProvider_success() public {
        vm.prank(admin);
        account.addWalletProvider(8002, "NewWallet");
        
        (string memory name, bool isAvailable) = account.walletProviderMap(8002);
        assertEq(name, "NewWallet");
        assertTrue(isAvailable);
    }

    function test_removeWalletProvider_success() public {
        vm.prank(admin);
        account.addWalletProvider(8003, "TempWallet");
        
        vm.prank(admin);
        account.removeWalletProvider(8003);
        
        (string memory name, bool isAvailable) = account.walletProviderMap(8003);
        assertEq(name, "");
        assertFalse(isAvailable);
    }

    function test_setNftAvatar_success() public {
        vm.prank(user);
        account.setNftAvatar("https://example.com/avatar.png");
        
        assertEq(account.nftAvatar(1001), "https://example.com/avatar.png");
    }

    function test_setNftAvatar_revertsIfNoAccount() public {
        vm.expectRevert("Address has no account");
        vm.prank(other);
        account.setNftAvatar("https://example.com/avatar.png");
    }

    function test_pause_unpause() public {
        // admin already has pause/unpause roles from BaseTest setup
        vm.prank(admin);
        account.pause();
        assertTrue(account.paused());
        
        vm.prank(admin);
        account.unpause();
        assertFalse(account.paused());
    }

    // ============ mintByOperator Tests ============

    function test_mintByOperator_success() public {
        // tokenId must be 10-11 digits (minDigitForSale=10, maxDigitForSale=11)
        uint256 tokenId = 1234567890; // 10 digits
        
        vm.prank(cashOperator);
        account.mintByOperator(other, tokenId, 8001);
        
        assertEq(account.ownerOf(tokenId), other);
        assertEq(uint256(account.status(tokenId)), uint256(Fiat24Account.Status.Tourist));
        assertEq(account.walletProvider(tokenId), 8001);
    }

    function test_mintByOperator_revertsIfNotOperatorMintRole() public {
        uint256 tokenId = 1234567891;
        
        vm.expectRevert("Not an operator/operator mint role");
        vm.prank(user);
        account.mintByOperator(other, tokenId, 8001);
    }

    function test_mintByOperator_revertsOnInvalidWalletProviderId() public {
        uint256 tokenId = 1234567892;
        
        // walletProviderTokenId must be 8xxx (8-8999)
        vm.expectRevert("Incorrect wallet provider id");
        vm.prank(cashOperator);
        account.mintByOperator(other, tokenId, 1001);
    }

    function test_mintByOperator_revertsOnUnavailableWalletProvider() public {
        uint256 tokenId = 1234567893;
        
        // 8002 is not registered as wallet provider
        vm.expectRevert("Not a valid wallet provider");
        vm.prank(cashOperator);
        account.mintByOperator(other, tokenId, 8002);
    }

    function test_mintByOperator_revertsOn9xxTokenId() public {
        // 9xx tokenIds are reserved for internal accounts (use 10 digit 9xxxxxxxxx)
        uint256 tokenId = 9123456789;
        
        vm.expectRevert("9xx cannot be minted");
        vm.prank(cashOperator);
        account.mintByOperator(other, tokenId, 8001);
    }

    function test_mintByOperator_revertsOn8xxTokenId() public {
        // 8xx tokenIds are reserved for merchant accounts (use 10 digit 8xxxxxxxxx)
        uint256 tokenId = 8123456789;
        
        vm.expectRevert("Merchant account cannot be minted");
        vm.prank(cashOperator);
        account.mintByOperator(other, tokenId, 8001);
    }

    function test_mintByOperator_revertsIfTargetAlreadyHasAccount() public {
        uint256 tokenId = 1234567894;
        
        // user already has account 1001 from BaseTest setup
        vm.expectRevert("Target address not allowed to mint");
        vm.prank(cashOperator);
        account.mintByOperator(user, tokenId, 8001);
    }

    function test_mintByOperator_revertsOnTooFewDigits() public {
        // tokenId with less than 10 digits should fail
        vm.expectRevert("Token digits < min digits for sale");
        vm.prank(cashOperator);
        account.mintByOperator(other, 12345, 8001);
    }

    function test_mintByOperator_revertsOnTooManyDigits() public {
        // tokenId with more than 11 digits should fail
        uint256 tokenId = 123456789012; // 12 digits
        
        vm.expectRevert("Token digits > max digits for sale");
        vm.prank(cashOperator);
        account.mintByOperator(other, tokenId, 8001);
    }
}
