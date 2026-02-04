// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "./libraries/DigitsOfUint.sol";

contract Fiat24Account is ERC721EnumerableUpgradeable, ERC721PausableUpgradeable, AccessControlUpgradeable {
    using DigitsOfUint for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant LIMITUPDATER_ROLE = keccak256("LIMITUPDATER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant CLIENTSTATUSCHANGE_ROLE = keccak256("CLIENTSTATUSCHANGE_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");
    bytes32 public constant OPERATOR_MINT_ROLE = keccak256("OPERATOR_MINT_ROLE");

    uint256 public constant DEFAULT_MERCHANT_RATE = 55;

    enum Status {
        Na,
        SoftBlocked,
        Tourist,
        Blocked,
        Closed,
        Live
    }

    struct WalletProvider {
        string walletProvider;
        bool isAvailable;
    }

    uint8 public constant MERCHANTDIGIT = 8;
    uint8 public constant INTERNALDIGIT = 9;

    struct Limit {
        uint256 usedLimit;
        uint256 clientLimit;
        uint256 startLimitDate;
    }

    uint256 public constant LIMITLIVEDEFAULT = 100000;
    uint256 public limitTourist;

    uint256 public constant THIRTYDAYS = 2592000;

    mapping(address => uint256) public historicOwnership;
    mapping(uint256 => string) public nickNames;
    mapping(uint256 => bool) public isMerchant;
    mapping(uint256 => uint256) public merchantRate;
    mapping(uint256 => Status) public status;
    mapping(uint256 => Limit) public limit;

    uint8 public minDigitForSale; //maxDigitForMint
    uint8 public maxDigitForSale;
    mapping(uint256 => uint256) public walletProvider;
    mapping(uint256 => WalletProvider) public walletProviderMap;

    mapping(uint256 => string) public nftAvatar;

    mapping(uint256 => uint256) public oldTokenId;
    string private _baseTokenURI;

    /// @notice ETH gas fee required to collect a third-party mint, in wei
    uint256 public mintFee;
    /// @notice Fee recipient address for third-party mint collections
    address public feeReceiver;

    function initialize(address admin) public initializer {
        __Context_init_unchained();
        __ERC721_init_unchained("UR Account", "UR");
        __AccessControl_init_unchained();
        _baseTokenURI = "https://nft.ur.app/metadata%3Ftokenid%3D?";
        minDigitForSale = 10;
        maxDigitForSale = 11;
        limitTourist = 100000;
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ROLE, admin);
    }

    function mint(address _to, uint256 _tokenId) public {
        require(hasRole(OPERATOR_ROLE, msg.sender) || hasRole(MINTER_ROLE, msg.sender), "Not an operator/minter");
        require(_mintAllowed(_to, _tokenId), "mint not allowed");
        _mint(_to, _tokenId);
        status[_tokenId] = Status.Tourist;
        initilizeTouristLimit(_tokenId);
        nickNames[_tokenId] = string(abi.encodePacked("Account ", StringsUpgradeable.toString(_tokenId)));
    }

    function mintByClient(uint256 _tokenId) external {
        revert("This function is disabled");
        _mintByClient(_tokenId);
    }

    function _mintByClient(uint256 _tokenId) internal {
        revert("This function is disabled");
        require(!_tokenId.hasFirstDigit(INTERNALDIGIT), "9xx cannot be mint by client");
        require(_tokenId.numDigits() <= maxDigitForSale, "Number of digits of accountId > max. digits");
        require(_mintAllowed(_msgSender(), _tokenId), "Not allowed. The address has/had another NFT.");
        _mint(_msgSender(), _tokenId);
        status[_tokenId] = Status.Tourist;
        initilizeTouristLimit(_tokenId);
        nickNames[_tokenId] = string(abi.encodePacked("Account ", StringsUpgradeable.toString(_tokenId)));
    }

    // Allow the wallet provider (i.e. the account with the specified conditions) to
    // mint a new Fiat24 account (in the form of an NFT) for another address
    function mintByWallet(address to, uint256 _tokenId) external payable {
        revert("This function is disabled");
        require(this.balanceOf(_msgSender()) > 0, "Minting address has no account");
        uint256 minterTokenId = this.tokenOfOwnerByIndex(_msgSender(), 0);
        require(minterTokenId.hasFirstDigit(MERCHANTDIGIT) && (minterTokenId >= 8 && minterTokenId <= 8999), "Incorrect account id for wallet");
        require(walletProviderMap[minterTokenId].isAvailable, "Account not wallet provider");
        require(_tokenId.numDigits() >= minDigitForSale, "mintByWallet only for minDigitForSale digits tokens");
        require(_tokenId.numDigits() <= maxDigitForSale, "Number of digits of accountId > max. digits");
        require(!_tokenId.hasFirstDigit(INTERNALDIGIT), "9xx cannot be mint by client");
        require(!_tokenId.hasFirstDigit(MERCHANTDIGIT), "Merchant account cannot be minted by wallet");
        require(_mintAllowed(to, _tokenId), "Not allowed. The target address has an account or once had another account.");
        walletProvider[_tokenId] = minterTokenId;
        status[_tokenId] = Status.Tourist;

        require(msg.value >= mintFee, "Insufficient mint fee");
        _mint(to, _tokenId);
        payable(feeReceiver).transfer(msg.value);

    }

    /// @notice Allow OPERATOR_MINT_ROLE to mint a new Fiat24 account on behalf of a wallet provider
    /// @param to The address to receive the minted account NFT
    /// @param _tokenId The token ID to mint
    /// @param walletProviderTokenId The wallet provider's token ID (must be a valid wallet provider)
    function mintByOperator(address to, uint256 _tokenId, uint256 walletProviderTokenId) external {
        require(hasRole(OPERATOR_ROLE, msg.sender) || hasRole(OPERATOR_MINT_ROLE, msg.sender), "Not an operator/operator mint role");
        require(walletProviderTokenId.hasFirstDigit(MERCHANTDIGIT) && (walletProviderTokenId >= 8 && walletProviderTokenId <= 8999), "Incorrect wallet provider id");
        require(walletProviderMap[walletProviderTokenId].isAvailable, "Not a valid wallet provider");
        require(_tokenId.numDigits() >= minDigitForSale, "Token digits < min digits for sale");
        require(_tokenId.numDigits() <= maxDigitForSale, "Token digits > max digits for sale");
        require(!_tokenId.hasFirstDigit(INTERNALDIGIT), "9xx cannot be minted");
        require(!_tokenId.hasFirstDigit(MERCHANTDIGIT), "Merchant account cannot be minted");
        require(_mintAllowed(to, _tokenId), "Target address not allowed to mint");
        
        walletProvider[_tokenId] = walletProviderTokenId;
        status[_tokenId] = Status.Tourist;
        initilizeTouristLimit(_tokenId);
        _mint(to, _tokenId);
    }

    function burn(uint256 tokenId) public {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Not an operator");
        delete limit[tokenId];
        _burn(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual override(ERC721Upgradeable, IERC721Upgradeable) {
        super.transferFrom(from, to, tokenId);
        if (status[tokenId] != Status.Tourist) {
            historicOwnership[to] = tokenId;
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual override(ERC721Upgradeable, IERC721Upgradeable) {

        if (status[tokenId] != Status.Tourist) {
            historicOwnership[to] = tokenId;
        }
        super.safeTransferFrom(from, to, tokenId);

    }

    function exists(uint256 tokenId) public view returns (bool) {
        return _exists(tokenId);
    }

    function removeHistoricOwnership(address owner) external {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Not an operator");
        delete historicOwnership[owner];
    }

    function changeClientStatus(uint256 tokenId, Status _status) external {
        require(hasRole(OPERATOR_ROLE, msg.sender) || hasRole(CLIENTSTATUSCHANGE_ROLE, msg.sender), "Not an operator/clientstatuschange");
        if (_status == Status.Live && status[tokenId] == Status.Tourist) {
            historicOwnership[this.ownerOf(tokenId)] = tokenId;
            initializeLiveLimit(tokenId);
        }
        status[tokenId] = _status;
    }

    function close(uint256 tokenId) external {
        require(_msgSender() == this.ownerOf(tokenId), "Not account owner");
        require(status[tokenId] == Status.Live, "Not live client");

        status[tokenId] = Status.Closed;
    }

    function setMinDigitForSale(uint8 minDigit) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an admin operator");
        minDigitForSale = minDigit;
    }

    function setMaxDigitForSale(uint8 maxDigit) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an admin operator");
        maxDigitForSale = maxDigit;
    }

    function setMerchantRate(uint256 tokenId, uint256 _merchantRate) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an admin operator");
        merchantRate[tokenId] = _merchantRate;
    }

    function initilizeTouristLimit(uint256 tokenId) private {
        Limit storage limit_ = limit[tokenId];
        limit_.usedLimit = 0;
        limit_.startLimitDate = block.timestamp;
    }

    function initializeLiveLimit(uint256 tokenId) private {
        Limit storage limit_ = limit[tokenId];
        limit_.usedLimit = 0;
        limit_.clientLimit = LIMITLIVEDEFAULT;
        limit_.startLimitDate = block.timestamp;
    }

    function setClientLimit(uint256 tokenId, uint256 clientLimit) external {
        require(hasRole(CLIENTSTATUSCHANGE_ROLE, msg.sender) || hasRole(OPERATOR_ROLE, msg.sender), "Not an operator");
        require(_exists(tokenId), "Token does not exist");
        require(status[tokenId] != Status.Tourist && status[tokenId] != Status.Na, "Not in correct status for limit control");
        Limit storage limit_ = limit[tokenId];
        limit_.clientLimit = clientLimit;
    }

    function resetUsedLimit(uint256 tokenId) external {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Not an operator");
        require(_exists(tokenId), "Token does not exist");
        Limit storage limit_ = limit[tokenId];
        limit_.usedLimit = 0;
    }

    function setTouristLimit(uint256 newLimitTourist) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an admin operator");
        limitTourist = newLimitTourist;
    }

    function checkLimit(uint256 tokenId, uint256 amount) external view returns (bool) {
        if (_exists(tokenId)) {
            if (tokenId >= 9100 && tokenId <= 9299) {
                return true;
            }
            Limit storage limit_ = limit[tokenId];
            uint256 lastLimitPeriodEnd = limit_.startLimitDate + THIRTYDAYS;
            if (status[tokenId] == Status.Tourist) {
                return (lastLimitPeriodEnd < block.timestamp && amount <= limitTourist)
                    || (lastLimitPeriodEnd >= block.timestamp && (limit_.usedLimit + amount) <= limitTourist);
            } else {
                return (lastLimitPeriodEnd < block.timestamp && amount <= limit_.clientLimit)
                    || (lastLimitPeriodEnd >= block.timestamp && (limit_.usedLimit + amount) <= limit_.clientLimit);
            }
        } else {
            return false;
        }
    }

    function updateLimit(uint256 tokenId, uint256 amount) external {
        require(hasRole(LIMITUPDATER_ROLE, msg.sender), "Not a limit-updater");
        if (tokenId >= 9100 && tokenId <= 9299) {
            return;
        }
        if (status[tokenId] == Status.Live || status[tokenId] == Status.Tourist) {
            Limit storage limit_ = limit[tokenId];
            uint256 lastLimitPeriodEnd = limit_.startLimitDate + THIRTYDAYS;
            if (lastLimitPeriodEnd < block.timestamp) {
                limit_.startLimitDate = block.timestamp;
                limit_.usedLimit = amount;
            } else {
                limit_.usedLimit += amount;
            }
        }
    }

    function setNickname(uint256 tokenId, string memory nickname) public {
        require(_msgSender() == this.ownerOf(tokenId), "Not account owner");
        nickNames[tokenId] = nickname;
    }

    function addWalletProvider(uint256 number, string memory name) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an operator admin");
        walletProviderMap[number].walletProvider = name;
        walletProviderMap[number].isAvailable = true;
    }

    function removeWalletProvider(uint256 number) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an operator admin");
        delete walletProviderMap[number];
    }

    function setNftAvatar(string memory url) external {
        require(this.balanceOf(_msgSender()) > 0, "Address has no account");
        uint256 tokenId = this.tokenOfOwnerByIndex(_msgSender(), 0);
        nftAvatar[tokenId] = url;
    }

    function setBaseURI(string calldata newBaseURI) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an admin operator");
        _baseTokenURI = newBaseURI;
    }

    function setMintFee(uint256 _mintFee) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an admin operator");
        mintFee = _mintFee;
    }

    function setFeeReceiver(address _feeReceiver) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Not an admin operator");
        require(_feeReceiver != address(0), "Zero address");
        feeReceiver = _feeReceiver;
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        string memory baseURI = _baseURI();
        string memory uriStatusParam = _uriStatusParam();
        string memory uriWalletParam = _uriWalletParam();
        return bytes(baseURI).length > 0
            ? string(
                abi.encodePacked(
                    baseURI,
                    StringsUpgradeable.toString(tokenId),
                    uriStatusParam,
                    StringsUpgradeable.toString(uint256(status[tokenId])),
                    uriWalletParam,
                    StringsUpgradeable.toString(walletProvider[tokenId])
                )
            )
            : "";
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    function _uriStatusParam() internal pure returns (string memory) {
        return "&status=";
    }

    function _uriWalletParam() internal pure returns (string memory) {
        return "&wallet=";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IERC721Upgradeable).interfaceId || interfaceId == type(IERC721MetadataUpgradeable).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function pause() public {
        require(hasRole(PAUSE_ROLE, msg.sender), "Not a pauser");
        _pause();
    }

    function unpause() public {
        require(hasRole(UNPAUSE_ROLE, msg.sender), "Not an unpauser");
        _unpause();
    }

    function _mintAllowed(address to, uint256 tokenId) internal view returns (bool) {
        return (this.balanceOf(to) < 1 && (historicOwnership[to] == 0 || historicOwnership[to] == tokenId));
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        virtual
        override(ERC721EnumerableUpgradeable, ERC721PausableUpgradeable)
    {
        require(!paused(), "Account transfers suspended");
        if (AddressUpgradeable.isContract(to) && (from != address(0))) {
            require(this.status(tokenId) == Status.Tourist, "Not allowed to transfer account");
        } else {
            if ((from != address(0) && to != address(0))) {
                if (_exists(9106)) {
                    require(
                        (balanceOf(to) < 1 && (historicOwnership[to] == 0 || historicOwnership[to] == tokenId))
                            || (tokenOfOwnerByIndex(to, 0) == 9106 && this.status(tokenId) == Status.Closed),
                        "Not allowed. The target address has an account or once had another account."
                    );
                    require(
                        (this.status(tokenId) == Status.Live || this.status(tokenId) == Status.Tourist)
                            || (balanceOf(to) > 0 && tokenOfOwnerByIndex(to, 0) == 9106 && this.status(tokenId) == Status.Closed),
                        "Transfer not allowed in this status"
                    );
                } else {
                    require(
                        balanceOf(to) < 1 && (historicOwnership[to] == 0 || historicOwnership[to] == tokenId),
                        "Not allowed. The target address has an account or once had another account."
                    );
                    require(this.status(tokenId) == Status.Live || this.status(tokenId) == Status.Tourist, "Transfer not allowed in this status");
                }
            }
        }
        super._beforeTokenTransfer(from, to, tokenId);
    }
}
