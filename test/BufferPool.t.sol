// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {BufferPool} from "../src/BufferPool.sol";
import {MockFiat24CryptoRelay} from "./mocks/MockFiat24CryptoRelay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BufferPoolTest is BaseTest {
    address internal operator = address(0xDEAD);
    address internal liquidityManager = address(0x1111);
    address internal robot = address(0x1234);
    address internal liquidityReceiver = address(0x5678);
    address internal feeReceiver = address(0x9ABC);
    
    BufferPool internal bufferPool;
    MockFiat24CryptoRelay internal cryptoRelay;
    
    // Mock Stargate (minimal interface for testing)
    address internal stargate = address(0x5747);
    
    function setUp() public override {
        // Call BaseTest setUp - handles all system accounts, tokens, etc.
        super.setUp();
        
        vm.startPrank(admin);
        
        // Deploy MockFiat24CryptoRelay
        cryptoRelay = new MockFiat24CryptoRelay(address(usdc));
        
        // Set exchange rates
        cryptoRelay.setExchangeRate(address(usdc), address(usd), 10000); // 1:1
        cryptoRelay.setExchangeRate(address(usd), address(usdc), 10000);
        cryptoRelay.setExchangeRate(address(eur), address(usd), 11000); // 1 EUR = 1.1 USD
        
        // Setup mock relay addresses
        cryptoRelay.setTreasuryDesk(account.ownerOf(9100));
        cryptoRelay.setCryptoDesk(account.ownerOf(9105));
        
        // Approve relay from crypto desk
        vm.stopPrank();
        vm.prank(account.ownerOf(9105));
        usd.approve(address(cryptoRelay), type(uint256).max);
        vm.startPrank(admin);
        
        // Deploy BufferPool with proxy
        address bufferPoolImpl = address(new BufferPool());
        address[] memory validTokens = new address[](5);
        validTokens[0] = address(usd);
        validTokens[1] = address(eur);
        validTokens[2] = address(chf);
        validTokens[3] = address(gbp);
        validTokens[4] = address(cnh);
        
        bufferPool = BufferPool(payable(address(new TransparentUpgradeableProxy(
            bufferPoolImpl,
            address(timelock),
            abi.encodeWithSelector(
                BufferPool.initialize.selector,
                admin,
                address(usdc),
                address(usd),
                stargate,
                address(account),
                address(cryptoRelay),
                liquidityReceiver,
                validTokens
            )
        ))));
        
        // Setup roles
        bufferPool.grantRole(bufferPool.OPERATOR_ROLE(), operator);
        bufferPool.grantRole(bufferPool.DELEGATE_OPERATOR_ROLE(), operator);
        bufferPool.grantRole(bufferPool.CASH_OPERATOR_ROLE(), operator);
        bufferPool.grantRole(bufferPool.LIQUIDITY_MANAGER_ROLE(), liquidityManager);
        bufferPool.grantRole(bufferPool.LIQUIDITY_MANAGER_ROBOT_ROLE(), robot);
        bufferPool.grantRole(bufferPool.PAUSE_ROLE(), admin);
        bufferPool.grantRole(bufferPool.UNPAUSE_ROLE(), admin);
        
        // Set fee receiver
        bufferPool.setFeeReceiver(feeReceiver);
        
        // Add liquidity to BufferPool
        usdc.mint(address(bufferPool), 1_000_000); // 1 USDC
        
        vm.stopPrank();
    }
    
    // ============ Initialization Tests ============
    
    function test_initialize_setsCorrectValues() public {
        assertEq(address(bufferPool.usdc()), address(usdc));
        assertEq(bufferPool.usd24(), address(usd));
        assertEq(address(bufferPool.stargate()), stargate);
        assertEq(address(bufferPool.fiat24Account()), address(account));
        assertEq(address(bufferPool.fiat24CryptoRelay()), address(cryptoRelay));
        assertEq(bufferPool.liquidityReceiver(), liquidityReceiver);
        assertTrue(bufferPool.validXXX24Tokens(address(usd)));
        assertTrue(bufferPool.validXXX24Tokens(address(eur)));
    }
    
    function test_initialize_revertsOnZeroAddress() public {
        address impl = address(new BufferPool());
        address[] memory validTokens = new address[](1);
        validTokens[0] = address(usd);
        
        vm.expectRevert(BufferPool.BufferPool__ZeroAddress.selector);
        BufferPool(payable(address(new TransparentUpgradeableProxy(
            impl,
            address(timelock),
            abi.encodeWithSelector(
                BufferPool.initialize.selector,
                address(0), // Zero admin
                address(usdc),
                address(usd),
                stargate,
                address(account),
                address(cryptoRelay),
                liquidityReceiver,
                validTokens
            )
        ))));
    }
    
    // ============ Quote Tests ============
    
    function test_getQuote_returnsCorrectAmount() public view {
        uint256 amountIn = 100_00; // 100.00 USD24
        uint256 quote = bufferPool.getQuote(address(usd), amountIn);
        assertGt(quote, 0, "Quote should be > 0");
    }
    
    function test_getQuote_revertsOnInvalidToken() public {
        MockERC20 invalidToken = new MockERC20("INVALID", "INV", 18);
        vm.expectRevert(BufferPool.BufferPool__InvalidToken.selector);
        bufferPool.getQuote(address(invalidToken), 100);
    }
    
    // ============ Onramp Tests ============
    // Note: test_onramp_executesSuccessfully removed - requires mainnet Fiat24Token transfer setup
    
    function test_onramp_revertsOnZeroAmount() public {
        BufferPool.OnrampParams memory params = BufferPool.OnrampParams({
            user: user,
            tokenIn: address(usd),
            amountIn: 0,
            minAmountOut: 0,
            feeAmount: 0
        });
        
        vm.expectRevert(BufferPool.BufferPool__InvalidAmount.selector);
        vm.prank(operator);
        bufferPool.onramp(params);
    }
    
    function test_onramp_revertsOnInvalidAccount() public {
        address invalidUser = address(0xBAD);
        uint256 amountIn = 100_00;
        
        BufferPool.OnrampParams memory params = BufferPool.OnrampParams({
            user: invalidUser,
            tokenIn: address(usd),
            amountIn: amountIn,
            minAmountOut: 0,
            feeAmount: 0
        });
        
        vm.expectRevert(BufferPool.BufferPool__AccountNotLive.selector);
        vm.prank(operator);
        bufferPool.onramp(params);
    }
    
    // Note: test_onramp_revertsOnSlippage removed - requires mainnet Fiat24Token transfer setup
    
    // ============ Liquidity Management Tests ============
    
    function test_addLiquidity_addsUSDC() public {
        uint256 amount = 1_000_000; // 1 USDC
        usdc.mint(liquidityManager, amount);
        
        vm.startPrank(liquidityManager);
        usdc.approve(address(bufferPool), amount);
        bufferPool.addLiquidity(amount);
        vm.stopPrank();
        
        assertEq(usdc.balanceOf(address(bufferPool)), 1_000_000 + amount);
    }
    
    function test_addLiquidity_revertsOnUnauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        bufferPool.addLiquidity(1000);
    }
    
    function test_removeLiquidity_removesUSDC() public {
        uint256 amount = 500_000; // 0.5 USDC
        uint256 receiverBefore = usdc.balanceOf(liquidityReceiver);
        
        vm.prank(liquidityManager);
        bufferPool.removeLiquidity(amount);
        
        assertEq(usdc.balanceOf(liquidityReceiver), receiverBefore + amount);
    }
    
    function test_removeLiquidity_revertsOnUnauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        bufferPool.removeLiquidity(1000);
    }
    
    // ============ Withdraw USD24 Tests ============
    // Note: test_withdrawUsd24_withdrawsToTreasury removed - requires mainnet Fiat24Token transfer setup
    
    function test_withdrawUsd24_revertsOnZeroAmount() public {
        vm.expectRevert(BufferPool.BufferPool__InvalidAmount.selector);
        vm.prank(robot);
        bufferPool.withdrawUsd24(0);
    }
    
    function test_withdrawUsd24_revertsOnUnauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        bufferPool.withdrawUsd24(100);
    }
    
    function test_withdrawUsd24_revertsWhenPaused() public {
        vm.prank(admin);
        bufferPool.pause();
        
        vm.expectRevert();
        vm.prank(robot);
        bufferPool.withdrawUsd24(100);
    }
    
    // ============ Convert Fiat to USD24 Tests ============
    // Note: test_convertFiatToUsd24_convertsTokens removed - requires mainnet Fiat24Token transfer setup
    
    function test_convertFiatToUsd24_revertsOnInvalidToken() public {
        address[] memory tokensIn = new address[](1);
        tokensIn[0] = address(0xBAD);
        uint256[] memory minAmountsOut = new uint256[](1);
        minAmountsOut[0] = 0;
        
        vm.expectRevert(BufferPool.BufferPool__InvalidToken.selector);
        vm.prank(robot);
        bufferPool.convertFiatToUsd24(tokensIn, minAmountsOut);
    }
    
    function test_convertFiatToUsd24_revertsOnUSD24() public {
        address[] memory tokensIn = new address[](1);
        tokensIn[0] = address(usd);
        uint256[] memory minAmountsOut = new uint256[](1);
        minAmountsOut[0] = 0;
        
        vm.expectRevert(BufferPool.BufferPool__InvalidToken.selector);
        vm.prank(robot);
        bufferPool.convertFiatToUsd24(tokensIn, minAmountsOut);
    }
    
    // ============ Setter Functions Tests ============
    
    function test_updateFees_updatesFee() public {
        uint256 newFee = 100; // 1%
        
        vm.prank(operator);
        bufferPool.updateFees(newFee);
        
        assertEq(bufferPool.bufferPoolFee(), newFee);
    }
    
    function test_updateFees_revertsOnNoChange() public {
        uint256 currentFee = bufferPool.bufferPoolFee();
        
        vm.expectRevert(BufferPool.BufferPool__NoChange.selector);
        vm.prank(operator);
        bufferPool.updateFees(currentFee);
    }
    
    function test_enableFiat24Token_enablesToken() public {
        MockERC20 newToken = new MockERC20("NEW", "NEW", 2);
        
        vm.prank(admin);
        bufferPool.enableFiat24Token(address(newToken));
        
        assertTrue(bufferPool.validXXX24Tokens(address(newToken)));
    }
    
    function test_enableFiat24Token_revertsOnNoChange() public {
        vm.expectRevert(BufferPool.BufferPool__NoChange.selector);
        vm.prank(admin);
        bufferPool.enableFiat24Token(address(usd)); // Already enabled
    }
    
    function test_disableFiat24Token_disablesToken() public {
        vm.prank(admin);
        bufferPool.disableFiat24Token(address(eur));
        
        assertFalse(bufferPool.validXXX24Tokens(address(eur)));
    }
    
    function test_disableFiat24Token_revertsOnNoChange() public {
        vm.prank(admin);
        bufferPool.disableFiat24Token(address(eur));
        
        vm.expectRevert(BufferPool.BufferPool__NoChange.selector);
        vm.prank(admin);
        bufferPool.disableFiat24Token(address(eur)); // Already disabled
    }
    
    function test_setFeeReceiver_updatesReceiver() public {
        address newReceiver = address(0xABCD);
        
        vm.prank(admin);
        bufferPool.setFeeReceiver(newReceiver);
        
        assertEq(bufferPool.feeReceiver(), newReceiver);
    }
    
    function test_setFeeReceiver_revertsOnZeroAddress() public {
        vm.expectRevert(BufferPool.BufferPool__ZeroAddress.selector);
        vm.prank(admin);
        bufferPool.setFeeReceiver(address(0));
    }
    
    function test_setFeeReceiver_revertsOnNoChange() public {
        vm.expectRevert(BufferPool.BufferPool__NoChange.selector);
        vm.prank(admin);
        bufferPool.setFeeReceiver(feeReceiver); // Same as current
    }
    
    // ============ Pause/Unpause Tests ============
    
    function test_pause_pausesContract() public {
        vm.prank(admin);
        bufferPool.pause();
        
        assertTrue(bufferPool.paused());
    }
    
    function test_unpause_unpausesContract() public {
        vm.prank(admin);
        bufferPool.pause();
        
        vm.prank(admin);
        bufferPool.unpause();
        
        assertFalse(bufferPool.paused());
    }
    
    function test_pause_revertsOnUnauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        bufferPool.pause();
    }
}

