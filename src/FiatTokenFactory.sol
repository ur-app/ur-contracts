// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./FiatToken.sol";

/// @dev Factory for deploying Fiat24 token proxies via a shared beacon.
contract Fiat24TokenFactory is AccessControl {

    /// @notice Role for creating new tokens
    bytes32 public constant CREATE_ROLE = keccak256("CREATE_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");

    /// @notice Beacon holding the implementation address for all tokens.
    address public immutable beaconAddress;

    address public accountProxyAddress;

    address public fiatTokenAdminAddress;

    address public fiatTokenOperatorAdminRole;

    address[] public fiatTokenOperatorRoles;

    address[] public cashOperatorRoles;

    address[] public fiatTokenPausers;

    address public fiatTokenUnpauser;

    /// @notice List of all deployed proxy addresses.
    address[] public allTokens;

    event FiatTokenCreated(address indexed proxy, address indexed admin);
    event ConfigUpdated(string indexed functionSignature, bytes oldValue, bytes newValue);

    constructor(
        address _factoryAdmin,
        address _factoryOperator,
        address _beaconAddress,
        address _accountProxyAddress,
        address _fiatTokenAdminAddress,
        address _fiatTokenOperatorAdminRole,
        address[] memory _fiatTokenOperatorRoles,
        address[] memory _cashOperatorRoles,
        address[] memory _fiatTokenPausers,
        address _fiatTokenUnpauser
    ) {
        require(_factoryAdmin != address(0), "FactoryAdmin cannot be zero address");
        require(_beaconAddress != address(0), "Beacon cannot be zero address");
        require(_fiatTokenAdminAddress != address(0), "Admin cannot be zero address");
        require(_factoryOperator != address(0),"Factory Operator cannot be zero address");
        require(_fiatTokenOperatorRoles.length != 0,"Fiat token operators cannot be zero");
        require(_fiatTokenOperatorAdminRole != address(0),"Fiat token admin operators cannot be zero address");
        require(_cashOperatorRoles.length != 0,"Cash operator roles cannot be zero");
        require(_fiatTokenUnpauser != address(0),"Unpauser cannot be zero address");
        require(_fiatTokenPausers.length != 0,"Pausers length cannot be zero");

        beaconAddress = _beaconAddress;
        accountProxyAddress = _accountProxyAddress;
        fiatTokenAdminAddress = _fiatTokenAdminAddress;
        fiatTokenOperatorRoles = _fiatTokenOperatorRoles;
        fiatTokenOperatorAdminRole = _fiatTokenOperatorAdminRole;
        cashOperatorRoles = _cashOperatorRoles;
        fiatTokenPausers = _fiatTokenPausers;
        fiatTokenUnpauser = _fiatTokenUnpauser;

        _grantRole(DEFAULT_ADMIN_ROLE, _factoryAdmin);
        _grantRole(OPERATOR_ADMIN_ROLE, _factoryAdmin);
        _grantRole(CREATE_ROLE, _factoryAdmin);
        _grantRole(CREATE_ROLE, _factoryOperator);
    }

    /// @notice Deploy a new BeaconProxy for a fiat token.
    /// @param name                   token name
    /// @param symbol                 token symbol
    /// @param limitWalkin            walk-in limit
    /// @param chfRate                CHF rate
    /// @param withdrawCharge         withdraw charge
    function createFiatToken(
        string calldata name,
        string calldata symbol,
        uint256 limitWalkin,
        uint256 chfRate,
        uint256 withdrawCharge
    ) external onlyRole(CREATE_ROLE) returns (address) {
        // prepare initialize data
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,string,string,uint256,uint256,uint256)",
            fiatTokenAdminAddress,
            accountProxyAddress,
            name, symbol, limitWalkin, chfRate, withdrawCharge
        );

        BeaconProxy proxy = new BeaconProxy(beaconAddress, initData);
        address proxyAddr = address(proxy);
        allTokens.push(proxyAddr);

        emit FiatTokenCreated(proxyAddr, fiatTokenAdminAddress);
        return proxyAddr;
    }

    /// @notice Deploy a new BeaconProxy for a fiat token and grant all roles.
    /// @param name                   token name
    /// @param symbol                 token symbol
    /// @param limitWalkin            walk-in limit
    /// @param chfRate                CHF rate
    /// @param withdrawCharge         withdraw charge
    function AuthAndCreateFiatToken(
        string calldata name,
        string calldata symbol,
        uint256 limitWalkin,
        uint256 chfRate,
        uint256 withdrawCharge
    ) external onlyRole(CREATE_ROLE) returns (address) {

        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,string,string,uint256,uint256,uint256)",
            address(this),
            accountProxyAddress,
            name, symbol, limitWalkin, chfRate, withdrawCharge
        );

        BeaconProxy proxy = new BeaconProxy(beaconAddress, initData);
        address proxyAddr = address(proxy);
        allTokens.push(proxyAddr);

        FiatToken token = FiatToken(proxyAddr);

        token.grantRole(token.DEFAULT_ADMIN_ROLE(), fiatTokenAdminAddress);
        token.grantRole(token.OPERATOR_ADMIN_ROLE(), fiatTokenOperatorAdminRole);

        for (uint256 i = 0; i < fiatTokenOperatorRoles.length; i++) {
            token.grantRole(token.OPERATOR_ROLE(), fiatTokenOperatorRoles[i]);
        }

        for (uint256 i = 0; i < cashOperatorRoles.length; i++) {
            token.grantRole(token.CASH_OPERATOR_ROLE(), cashOperatorRoles[i]);
        }

        for (uint256 i = 0; i < fiatTokenPausers.length; i++) {
            token.grantRole(token.PAUSE_ROLE(), fiatTokenPausers[i]);
        }

        if (fiatTokenUnpauser != address(0)) {
            token.grantRole(token.UNPAUSE_ROLE(), fiatTokenUnpauser);
        }

        token.revokeRole(token.OPERATOR_ROLE(), address(this));
        token.revokeRole(token.OPERATOR_ADMIN_ROLE(), address(this));
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), address(this));

        emit FiatTokenCreated(proxyAddr, fiatTokenAdminAddress);
        return proxyAddr;
    }

    /// @notice Set the account proxy address
    /// @param _accountProxyAddress The new account proxy address
    function setAccountProxyAddress(address _accountProxyAddress) external onlyRole(OPERATOR_ADMIN_ROLE) {
        address oldAddress = accountProxyAddress;
        accountProxyAddress = _accountProxyAddress;
        emit ConfigUpdated("setAccountProxyAddress(address)", abi.encode(oldAddress), abi.encode(_accountProxyAddress));
    }

    /// @notice Set the fiat token operator roles
    /// @param _fiatTokenOperatorRoles The new array of fiat token operator roles
    function setFiatTokenOperatorRoles(address[] memory _fiatTokenOperatorRoles) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_fiatTokenOperatorRoles.length != 0, "Fiat token operators cannot be zero");
        address[] memory oldRoles = fiatTokenOperatorRoles;
        fiatTokenOperatorRoles = _fiatTokenOperatorRoles;
        emit ConfigUpdated("setFiatTokenOperatorRoles(address[])", abi.encode(oldRoles), abi.encode(_fiatTokenOperatorRoles));
    }

    /// @notice Set the cash operator roles
    /// @param _cashOperatorRoles The new array of cash operator roles
    function setCashOperatorRoles(address[] memory _cashOperatorRoles) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_cashOperatorRoles.length != 0, "Cash operator roles cannot be zero");
        address[] memory oldRoles = cashOperatorRoles;
        cashOperatorRoles = _cashOperatorRoles;
        emit ConfigUpdated("setCashOperatorRoles(address[])", abi.encode(oldRoles), abi.encode(_cashOperatorRoles));
    }

    /// @notice Set the fiat token pausers
    /// @param _fiatTokenPausers The new array of fiat token pausers
    function setFiatTokenPausers(address[] memory _fiatTokenPausers) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_fiatTokenPausers.length != 0, "Pausers length cannot be zero");
        address[] memory oldPausers = fiatTokenPausers;
        fiatTokenPausers = _fiatTokenPausers;
        emit ConfigUpdated("setFiatTokenPausers(address[])", abi.encode(oldPausers), abi.encode(_fiatTokenPausers));
    }

    /// @notice Set the fiat token admin address
    /// @param _fiatTokenAdminAddress The new fiat token admin address
    function setFiatTokenAdminAddress(address _fiatTokenAdminAddress) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_fiatTokenAdminAddress != address(0), "Admin cannot be zero address");
        address oldAddress = fiatTokenAdminAddress;
        fiatTokenAdminAddress = _fiatTokenAdminAddress;
        emit ConfigUpdated("setFiatTokenAdminAddress(address)", abi.encode(oldAddress), abi.encode(_fiatTokenAdminAddress));
    }

    /// @notice Set the fiat token operator admin role
    /// @param _fiatTokenOperatorAdminRole The new fiat token operator admin role
    function setFiatTokenOperatorAdminRole(address _fiatTokenOperatorAdminRole) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_fiatTokenOperatorAdminRole != address(0), "Fiat token admin operators cannot be zero address");
        address oldRole = fiatTokenOperatorAdminRole;
        fiatTokenOperatorAdminRole = _fiatTokenOperatorAdminRole;
        emit ConfigUpdated("setFiatTokenOperatorAdminRole(address)", abi.encode(oldRole), abi.encode(_fiatTokenOperatorAdminRole));
    }

    /// @notice Set the fiat token unpauser
    /// @param _fiatTokenUnpauser The new fiat token unpauser
    function setFiatTokenUnpauser(address _fiatTokenUnpauser) external onlyRole(OPERATOR_ADMIN_ROLE) {
        require(_fiatTokenUnpauser != address(0), "Unpauser cannot be zero address");
        address oldUnpauser = fiatTokenUnpauser;
        fiatTokenUnpauser = _fiatTokenUnpauser;
        emit ConfigUpdated("setFiatTokenUnpauser(address)", abi.encode(oldUnpauser), abi.encode(_fiatTokenUnpauser));
    }

    /// @notice Add a token address to the allTokens array
    /// @param tokenAddress The token address to add
    function addTokenAddress(address tokenAddress) external onlyRole(OPERATOR_ADMIN_ROLE) {
        allTokens.push(tokenAddress);
        emit ConfigUpdated("addTokenAddress(address)", "", abi.encode(tokenAddress));
    }

    /// @notice Remove a token address from the allTokens array
    /// @param tokenAddress The token address to remove
    function removeTokenAddress(address tokenAddress) external onlyRole(OPERATOR_ADMIN_ROLE) {
        for (uint256 i = 0; i < allTokens.length; i++) {
            if (allTokens[i] == tokenAddress) {
                allTokens[i] = allTokens[allTokens.length - 1];
                allTokens.pop();
                break;
            }
        }
        emit ConfigUpdated("removeTokenAddress(address)", "", abi.encode(tokenAddress));
    }

    /// @notice Get the addresses of all deployed agents
    function getAllTokens() external view returns (address[] memory) {
        return allTokens;
    }

}