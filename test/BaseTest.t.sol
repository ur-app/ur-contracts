// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PreDeployHelper} from "./utils/PreDeployHelper.sol";
import {Fiat24CryptoDeposit} from "../src/Fiat24CryptoDeposit.sol";
import {Fiat24CardAuthorizationMarqeta} from "../src/Fiat24CardAuthorizationMarqeta.sol";
import {Fiat24Account} from "../src/Fiat24Account.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BaseTest is Test, PreDeployHelper {
    address internal admin = address(0xA11CE);
    address internal user = address(0xBEEF);
    address internal other = address(0xCAFE);

    Fiat24CryptoDeposit internal deposit;
    Fiat24CardAuthorizationMarqeta internal marqeta;
    MockERC20 internal usdc;

    function setUp() public virtual {
        vm.startPrank(admin);
        
        // Deploy all Fiat24 tokens using PreDeployHelper
        deployPreDeployContracts(admin);
        
        // Deploy USDC mock
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy CryptoDeposit with proxy (dummy uniswap params - not used in most tests)
        address depositImpl = address(new Fiat24CryptoDeposit(address(1), address(1), address(1), address(1), address(1)));
        deposit = Fiat24CryptoDeposit(payable(address(new TransparentUpgradeableProxy(
            depositImpl,
            address(timelock),
            abi.encodeWithSelector(
                Fiat24CryptoDeposit.initialize.selector,
                admin,
                address(account),
                address(usd),
                address(eur),
                address(chf),
                address(gbp),
                address(cnh),
                address(usdc),
                address(this), // usdcDepositAddress
                admin,         // feeReceiver
                address(this)  // fiat24CryptoRelayAddress
            )
        ))));

        // Deploy CardAuthorizationMarqeta with proxy
        address marqetaImpl = address(new Fiat24CardAuthorizationMarqeta());
        marqeta = Fiat24CardAuthorizationMarqeta(address(new TransparentUpgradeableProxy(
            marqetaImpl,
            address(timelock),
            abi.encodeWithSelector(
                Fiat24CardAuthorizationMarqeta.initialize.selector,
                admin,
                address(account),
                address(eur),
                address(usd),
                address(chf),
                address(gbp),
                address(cnh)
            )
        )));
        vm.stopPrank();

        // Mint system accounts to different addresses and user account
        vm.startPrank(admin);
        account.mint(address(0x9101), 9101);  // MINT_DESK
        account.mint(address(0x9100), 9100);  // TREASURY_DESK  
        account.mint(address(0x9110), 9110);  // CARD_BOOKED
        account.mint(address(0x9106), 9106);  // SPECIAL_ACCOUNT
        account.mint(address(0x9105), 9105);  // CRYPTO_DESK
        account.mint(address(0x9104), 9104);  // BURN_DESK
        account.mint(address(0x9103), 9103);  // SUNDRY
        account.mint(address(0x9102), 9102);  // PAYOUT_DESK
        account.mint(address(0x9203), 9203);  // FEE_DESK
        account.mint(user, 1001);             // User account

        // Change all system accounts to Live status (5)
        account.changeClientStatus(9101, Fiat24Account.Status.Live);
        account.changeClientStatus(9100, Fiat24Account.Status.Live);
        account.changeClientStatus(9110, Fiat24Account.Status.Live);
        account.changeClientStatus(9106, Fiat24Account.Status.Live);
        account.changeClientStatus(9105, Fiat24Account.Status.Live);
        account.changeClientStatus(9104, Fiat24Account.Status.Live);
        account.changeClientStatus(9103, Fiat24Account.Status.Live);
        account.changeClientStatus(9102, Fiat24Account.Status.Live);
        account.changeClientStatus(9203, Fiat24Account.Status.Live);
        account.changeClientStatus(1001, Fiat24Account.Status.Live); // User account too

        // Setup roles for Marqeta contract (using admin who has DEFAULT_ADMIN_ROLE)
        vm.startPrank(admin);
        marqeta.grantRole(marqeta.AUTHORIZER_ROLE(), admin);
        marqeta.grantRole(marqeta.AUTHORIZER_ROLE(), address(0x9110)); // CARD_BOOKED can authorize
        marqeta.grantRole(marqeta.CRYPTO_CONFIG_UPDATER_ROLE(), address(0x9105)); // CRYPTO_DESK can update configs
        marqeta.grantRole(marqeta.RATES_UPDATER_OPERATOR_ROLE(), admin);
        marqeta.grantRole(marqeta.RATES_UPDATER_ROBOT_ROLE(), address(0x9100)); // TREASURY can update rates
        marqeta.grantRole(marqeta.PAUSE_ROLE(), admin);
        marqeta.grantRole(marqeta.UNPAUSE_ROLE(), admin);
        vm.stopPrank();

        // Setup roles for CryptoDeposit contract (using admin who has DEFAULT_ADMIN_ROLE)
        vm.startPrank(admin);
        deposit.grantRole(deposit.CASH_OPERATOR_ROLE(), admin);
        deposit.grantRole(deposit.CASH_OPERATOR_ROLE(), address(0x9105)); // CRYPTO_DESK can operate
        deposit.grantRole(deposit.RATES_UPDATER_OPERATOR_ROLE(), admin);
        deposit.grantRole(deposit.PAUSE_ROLE(), admin);
        deposit.grantRole(deposit.UNPAUSE_ROLE(), admin);
        vm.stopPrank();

        // Setup roles for Fiat24Token contracts (using admin who has DEFAULT_ADMIN_ROLE)
        vm.startPrank(admin);
        usd.grantRole(usd.CASH_OPERATOR_ROLE(), admin);
        usd.grantRole(usd.CASH_OPERATOR_ROLE(), address(0x9105)); // CRYPTO_DESK can operate
        usd.grantRole(usd.OPERATOR_ROLE(), address(marqeta)); // Marqeta can operate USD24
        usd.grantRole(usd.RATES_UPDATER_OPERATOR_ROLE(), admin);
        usd.grantRole(usd.PAUSE_ROLE(), admin);
        usd.grantRole(usd.UNPAUSE_ROLE(), admin);
        vm.stopPrank();
        
        vm.startPrank(admin);
        eur.grantRole(eur.CASH_OPERATOR_ROLE(), admin);
        eur.grantRole(eur.CASH_OPERATOR_ROLE(), address(0x9105));
        eur.grantRole(eur.OPERATOR_ROLE(), address(marqeta)); // Marqeta can operate EUR24
        eur.grantRole(eur.RATES_UPDATER_OPERATOR_ROLE(), admin);
        eur.grantRole(eur.PAUSE_ROLE(), admin);
        eur.grantRole(eur.UNPAUSE_ROLE(), admin);
        vm.stopPrank();
        
        vm.startPrank(admin);
        chf.grantRole(chf.CASH_OPERATOR_ROLE(), admin);
        chf.grantRole(chf.CASH_OPERATOR_ROLE(), address(0x9105));
        chf.grantRole(chf.OPERATOR_ROLE(), address(marqeta)); // Marqeta can operate CHF24
        chf.grantRole(chf.RATES_UPDATER_OPERATOR_ROLE(), admin);
        chf.grantRole(chf.PAUSE_ROLE(), admin);
        chf.grantRole(chf.UNPAUSE_ROLE(), admin);
        vm.stopPrank();
        
        vm.startPrank(admin);
        gbp.grantRole(gbp.CASH_OPERATOR_ROLE(), admin);
        gbp.grantRole(gbp.CASH_OPERATOR_ROLE(), address(0x9105));
        gbp.grantRole(gbp.OPERATOR_ROLE(), address(marqeta)); // Marqeta can operate GBP24
        gbp.grantRole(gbp.RATES_UPDATER_OPERATOR_ROLE(), admin);
        gbp.grantRole(gbp.PAUSE_ROLE(), admin);
        gbp.grantRole(gbp.UNPAUSE_ROLE(), admin);
        vm.stopPrank();
        
        vm.startPrank(admin);
        cnh.grantRole(cnh.CASH_OPERATOR_ROLE(), admin);
        cnh.grantRole(cnh.CASH_OPERATOR_ROLE(), address(0x9105));
        cnh.grantRole(cnh.OPERATOR_ROLE(), address(marqeta)); // Marqeta can operate CNH24
        cnh.grantRole(cnh.RATES_UPDATER_OPERATOR_ROLE(), admin);
        cnh.grantRole(cnh.PAUSE_ROLE(), admin);
        cnh.grantRole(cnh.UNPAUSE_ROLE(), admin);
        vm.stopPrank();

        // Setup Account contract roles (using admin who has DEFAULT_ADMIN_ROLE)
        vm.startPrank(admin);
        account.grantRole(account.LIMITUPDATER_ROLE(), address(usd));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(eur));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(chf));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(gbp));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(cnh));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(marqeta));
        account.grantRole(account.CLIENTSTATUSCHANGE_ROLE(), admin);
        account.grantRole(account.MINTER_ROLE(), admin);
        account.grantRole(account.PAUSE_ROLE(), admin);
        account.grantRole(account.UNPAUSE_ROLE(), admin);
        
        // Set up Marqeta contract additional configuration
        // marqeta.setFiat24CryptoRelayAddress(address(this)); // Method removed from Marqeta contract
        marqeta.setTreasuryAddress(account.ownerOf(9100)); // TREASURY_DESK
        vm.stopPrank();

        // Mint tokens to system accounts according to Fiat24Token logic
        vm.startPrank(admin);
        // Mint to 9101 (MINT_DESK) - this is where new tokens are minted
        usd.mint(10_000_000_00); // 10M USD24
        eur.mint(10_000_000_00); // 10M EUR24
        chf.mint(10_000_000_00); // 10M CHF24
        gbp.mint(10_000_000_00); // 10M GBP24
        cnh.mint(10_000_000_00); // 10M CNH24
        vm.stopPrank();

        // Setup approvals from MINT_DESK (9101) to admin for token transfers
        vm.startPrank(account.ownerOf(9101));
        usd.approve(admin, type(uint256).max);
        eur.approve(admin, type(uint256).max);
        chf.approve(admin, type(uint256).max);
        gbp.approve(admin, type(uint256).max);
        cnh.approve(admin, type(uint256).max);
        vm.stopPrank();

        // Transfer tokens to CRYPTO_DESK (9105) for swap payouts
        vm.startPrank(admin);
        usd.transferFrom(account.ownerOf(9101), account.ownerOf(9105), 1_000_000_00); // 1M USD24
        eur.transferFrom(account.ownerOf(9101), account.ownerOf(9105), 1_000_000_00); // 1M EUR24
        chf.transferFrom(account.ownerOf(9101), account.ownerOf(9105), 1_000_000_00); // 1M CHF24
        gbp.transferFrom(account.ownerOf(9101), account.ownerOf(9105), 1_000_000_00); // 1M GBP24
        cnh.transferFrom(account.ownerOf(9101), account.ownerOf(9105), 1_000_000_00); // 1M CNH24

        // Give user initial balances
        usd.transferFrom(account.ownerOf(9101), user, 1_000_00); // 1,000.00 USD24
        eur.transferFrom(account.ownerOf(9101), user, 1_000_00); // 1,000.00 EUR24
        chf.transferFrom(account.ownerOf(9101), user, 1_000_00); // 1,000.00 CHF24
        gbp.transferFrom(account.ownerOf(9101), user, 1_000_00); // 1,000.00 GBP24
        cnh.transferFrom(account.ownerOf(9101), user, 1_000_00); // 1,000.00 CNH24
        vm.stopPrank();

        // Setup system account approvals for Marqeta contract
        vm.startPrank(account.ownerOf(9105)); // CRYPTO_DESK
        usd.approve(address(marqeta), type(uint256).max);
        eur.approve(address(marqeta), type(uint256).max);
        chf.approve(address(marqeta), type(uint256).max);
        gbp.approve(address(marqeta), type(uint256).max);
        cnh.approve(address(marqeta), type(uint256).max);
        vm.stopPrank();

        // Setup system account approvals for CryptoDeposit contract
        vm.startPrank(account.ownerOf(9105)); // CRYPTO_DESK
        usd.approve(address(deposit), type(uint256).max);
        eur.approve(address(deposit), type(uint256).max);
        chf.approve(address(deposit), type(uint256).max);
        gbp.approve(address(deposit), type(uint256).max);
        cnh.approve(address(deposit), type(uint256).max);
        vm.stopPrank();
        
        usdc.mint(user, 10_000_000); // 10 USDC
        
        // Setup approvals
        vm.startPrank(user);
        usd.approve(address(marqeta), type(uint256).max);
        eur.approve(address(marqeta), type(uint256).max);
        chf.approve(address(marqeta), type(uint256).max);
        gbp.approve(address(marqeta), type(uint256).max);
        cnh.approve(address(marqeta), type(uint256).max);
        usdc.approve(address(deposit), type(uint256).max);
        usdc.approve(address(marqeta), type(uint256).max);
        vm.stopPrank();
    }

    // Mock implementation of Fiat24CryptoRelay.getFee
    function getFee(uint256 tokenId, uint256 amount) external pure returns (uint256) {
        // Simple mock: 1% fee
        return amount / 100;
    }
}


