// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockControllerHelper} from "./TimelockControllerHelper.sol";
import {Fiat24Account} from "../../src/Fiat24Account.sol";
import {Fiat24USD} from "../../src/Fiat24USD.sol";
import {Fiat24EUR} from "../../src/Fiat24EUR.sol";
import {Fiat24CHF} from "../../src/Fiat24CHF.sol";
import {Fiat24GBP} from "../../src/Fiat24GBP.sol";
import {Fiat24CNH} from "../../src/Fiat24CNH.sol";

abstract contract PreDeployHelper is TimelockControllerHelper {
    Fiat24Account public account;

    Fiat24USD public usd;
    Fiat24EUR public eur;
    Fiat24CHF public chf;
    Fiat24GBP public gbp;
    Fiat24CNH public cnh;

    function deployPreDeployContracts(address operator) public {
        deployTimelock(operator);

        // Deploy Fiat24Account
        address accountImpl = address(new Fiat24Account());
        account =
            Fiat24Account(address(new TransparentUpgradeableProxy(accountImpl, address(timelock), abi.encodeWithSelector(Fiat24Account.initialize.selector, operator))));
        account.grantRole(account.OPERATOR_ROLE(), operator);

        // Deploy Token contracts
        address usdImpl = address(new Fiat24USD());
        address eurImpl = address(new Fiat24EUR());
        address chfImpl = address(new Fiat24CHF());
        address gbpImpl = address(new Fiat24GBP());
        address cnhImpl = address(new Fiat24CNH());
        usd = Fiat24USD(
            address(
                new TransparentUpgradeableProxy(usdImpl, address(timelock), abi.encodeWithSelector(Fiat24USD.initialize.selector, operator, address(account), 1000, 1, 1))
            )
        );
        eur = Fiat24EUR(
            address(
                new TransparentUpgradeableProxy(eurImpl, address(timelock), abi.encodeWithSelector(Fiat24EUR.initialize.selector, operator, address(account), 1000, 1, 1))
            )
        );
        chf = Fiat24CHF(
            address(
                new TransparentUpgradeableProxy(chfImpl, address(timelock), abi.encodeWithSelector(Fiat24CHF.initialize.selector, operator, address(account), 1000, 1, 1))
            )
        );
        gbp = Fiat24GBP(
            address(
                new TransparentUpgradeableProxy(gbpImpl, address(timelock), abi.encodeWithSelector(Fiat24GBP.initialize.selector, operator, address(account), 1000, 1, 1))
            )
        );
        cnh = Fiat24CNH(
            address(
                new TransparentUpgradeableProxy(cnhImpl, address(timelock), abi.encodeWithSelector(Fiat24CNH.initialize.selector, operator, address(account), 1000, 1, 1))
            )
        );

        // operator role
        usd.grantRole(usd.OPERATOR_ROLE(), operator);
        eur.grantRole(eur.OPERATOR_ROLE(), operator);
        chf.grantRole(chf.OPERATOR_ROLE(), operator);
        gbp.grantRole(gbp.OPERATOR_ROLE(), operator);
        cnh.grantRole(cnh.OPERATOR_ROLE(), operator);

        // limit updater role
        account.grantRole(account.LIMITUPDATER_ROLE(), address(usd));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(eur));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(chf));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(gbp));
        account.grantRole(account.LIMITUPDATER_ROLE(), address(cnh));
    }
}
