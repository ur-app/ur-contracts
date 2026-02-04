// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./Fiat24Account.sol";
import "./interfaces/SanctionsList.sol";

contract Fiat24Token is Initializable, ERC20PausableUpgradeable,ERC20PermitUpgradeable, AccessControlUpgradeable {
    using SafeMathUpgradeable for uint256;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant RATES_UPDATER_OPERATOR_ROLE = keccak256("RATES_UPDATER_OPERATOR_ROLE");
    bytes32 public constant CASH_OPERATOR_ROLE = keccak256("CASH_OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    uint256 constant ORIGIN_YEAR = 1970;
    uint256 constant DAY_IN_SECONDS = 86400;
    uint256 constant YEAR_IN_SECONDS = 31536000;
    uint256 constant LEAP_YEAR_IN_SECONDS = 31622400;

    uint256 public ChfRate;
    uint256 public LimitWalkin;
    uint256 public WithdrawCharge;
    uint256 public constant MINIMALCOMMISIONFEE = 10;
    Fiat24Account fiat24account;

    bool public sanctionCheck;
    address public sanctionContract;

    mapping(string => uint256) public pacs008;
    address public fiat24lockAddress;

    uint256 public minimalPayoutAmount;

    event CashDeposit(uint256 indexed recipientAccountId, address indexed recipientAddress, uint256 depositAccount, uint256 amount, string exaccId, string bankId, string trxId);
    event CashDepositNOK(uint256 indexed recipientAccountId, uint256 depositAccount, uint256 amount, string exaccId, string bankId, string trxId);
    event CashPayout(uint256 indexed senderAccountId, address indexed senderAddress, uint256 payoutAccount, uint256 amount, string bankId, string trxId);
    event ClientPayout(uint256 indexed tokenId, address indexed sender, uint256 payoutAccount, uint256 amount, string contactId, string txid);
    event ClientPayoutRef(
        uint256 indexed tokenId, address indexed sender, uint256 payoutAccount, uint256 amount, string contactId, string txid, uint256 purposeId, string ref
    );
    event PermitFailed(address indexed owner, address indexed spender, uint256 value);
    event TransferByAccountId(address indexed from, address indexed to, uint256 amount);


    function __Fiat24Token_init_(
        address admin,
        address fiat24accountProxyAddress,
        string memory name_,
        string memory symbol_,
        uint256 limitWalkin,
        uint256 chfRate,
        uint256 withdrawCharge
    ) internal onlyInitializing {
        __AccessControl_init_unchained();
        __ERC20_init_unchained(name_, symbol_);
        __ERC20Permit_init(name_);
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ADMIN_ROLE, admin);
        _setupRole(OPERATOR_ROLE, admin);
        fiat24account = Fiat24Account(fiat24accountProxyAddress);
        LimitWalkin = limitWalkin;
        ChfRate = chfRate;
        WithdrawCharge = withdrawCharge;
    }

    function mint(uint256 amount) public {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Fiat24Token: Not an operator");
        _mint(fiat24account.ownerOf(9101), amount);
    }

    function burn(uint256 amount) public {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Fiat24Token: Not an operator");
        _burn(fiat24account.ownerOf(9104), amount);
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = allowance(sender, _msgSender());
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        unchecked {
            _approve(sender, _msgSender(), currentAllowance - amount);
        }

        return true;
    }

    function permitAndTransferFrom(
        address userAddress,
        address recipient,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public returns (bool) {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Fiat24Token: Not a Cash Operator");
        return _permitAndTransferFrom(userAddress, recipient, amount, deadline, v, r, s);
    }


    function _permitAndTransferFrom(
        address userAddress,
        address recipient,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (bool) {
        try IERC20PermitUpgradeable(address(this)).permit(
            userAddress,
            address(this),
            amount,
            deadline,
            v, r, s
        ) {
        } catch {
            emit PermitFailed(userAddress, address(this), amount);
        }

        return IERC20Upgradeable(address(this)).transferFrom(userAddress,recipient,amount);
    }

    function cashDepositOK(uint256 recipientAccountId, uint256 amount, string memory exaccId, string memory bankId, string memory trxId) external {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Fiat24Token: Not a Cash Operator");
        bytes32 key = keccak256(abi.encodePacked(bankId, "-", trxId));
        require(pacs008[bytes32ToString(key)] == 0, "Fiat24Token: pacs008 already processed");
        pacs008[bytes32ToString(key)] = block.number;
        transferFrom(fiat24account.ownerOf(9101), fiat24account.ownerOf(recipientAccountId), amount);
        emit CashDeposit(recipientAccountId, fiat24account.ownerOf(recipientAccountId), recipientAccountId, amount, exaccId, bankId, trxId);
    }

    function cashDepositNOK(uint256 recipientAccountId, uint256 amount, string memory exaccId, string memory bankId, string memory trxId) external {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Fiat24Token: Not a Cash Operator");
        bytes32 key = keccak256(abi.encodePacked(bankId, "-", trxId));
        require(pacs008[bytes32ToString(key)] == 0, "Fiat24Token: pacs008 already processed");
        pacs008[bytes32ToString(key)] = block.number;
        transferFrom(fiat24account.ownerOf(9101), fiat24account.ownerOf(9103), amount);
        emit CashDepositNOK(recipientAccountId, 9103, amount, exaccId, bankId, trxId);
    }

    function cashPayoutOK(uint256 senderAccountId, uint256 amount, string memory bankId, string memory trxId) external {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Fiat24Token: Not a Cash Operator");
        bytes32 key = keccak256(abi.encodePacked(bankId, "-", trxId));
        require(pacs008[bytes32ToString(key)] == 0, "Fiat24Token: pacs008 already processed");
        pacs008[bytes32ToString(key)] = block.number;
        transferFrom(fiat24account.ownerOf(9102), fiat24account.ownerOf(9104), amount);
        emit CashPayout(senderAccountId, fiat24account.ownerOf(senderAccountId), 9104, amount, bankId, trxId);
    }

    function cashPayoutNOK(uint256 senderAccountId, uint256 amount, string memory bankId, string memory trxId) external {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Fiat24Token: Not a Cash Operator");
        bytes32 key = keccak256(abi.encodePacked(bankId, "-", trxId));
        require(pacs008[bytes32ToString(key)] == 0, "Fiat24Token: pacs008 already processed");
        // pacs008[bytes32ToString(key)] = ArbSys(address(100)).arbBlockNumber();
        pacs008[bytes32ToString(key)] = block.number;
        transferFrom(fiat24account.ownerOf(9102), fiat24account.ownerOf(9103), amount);
        emit CashPayout(senderAccountId, fiat24account.ownerOf(senderAccountId), 9103, amount, bankId, trxId);
    }

    function getPacs008(string memory bankId, string memory trxId) public view returns (uint256) {
        bytes32 bytesKey = keccak256(abi.encodePacked(bankId, "-", trxId));
        return pacs008[bytes32ToString(bytesKey)];
    }

    function clientPayout(uint256 amount, string memory contactId) external {
        require(amount >= minimalPayoutAmount, "Fiat24Token: amount < minimal payout amount");
        uint256 tokenId = fiat24account.tokenOfOwnerByIndex(msg.sender, 0);
        // string memory txid = string(abi.encodePacked(uintToString(tokenId), "-", uintToString(ArbSys(address(100)).arbBlockNumber())));
        string memory txid = string(abi.encodePacked(uintToString(tokenId), "-", uintToString(block.number)));
        transferByAccountId(9102, amount);
        emit ClientPayout(tokenId, msg.sender, 9102, amount, contactId, txid);
    }

    function clientPayoutRef(uint256 amount, string memory contactId, uint256 purposeId, string memory ref) external {
        require(amount >= minimalPayoutAmount, "Fiat24Token: amount < minimal payout amount");
        uint256 tokenId = fiat24account.tokenOfOwnerByIndex(msg.sender, 0);
        // string memory txid = string(abi.encodePacked(uintToString(tokenId), "-", uintToString(ArbSys(address(100)).arbBlockNumber())));
        string memory txid = string(abi.encodePacked(uintToString(tokenId), "-", uintToString(block.number)));
        transferByAccountId(9102, amount);
        emit ClientPayoutRef(tokenId, msg.sender, 9102, amount, contactId, txid, purposeId, ref);
    }

    function permitAndClientPayout(
        address userAddress,
        uint256 amount,
        string memory contactId,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Not a Cash Operator");
        (uint256 tokenId, string memory txid) = _doPayout(userAddress, amount, deadline, v, r, s);
        emit ClientPayout(tokenId, userAddress, 9102, amount, contactId, txid);
    }

    function permitAndClientPayoutRef(
        address userAddress,
        uint256 amount,
        string memory contactId,
        uint256 purposeId,
        string memory ref,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Not a Cash Operator");
        (uint256 tokenId, string memory txid) = _doPayout(userAddress, amount, deadline, v, r, s);
        emit ClientPayoutRef(tokenId, userAddress, 9102, amount, contactId, txid, purposeId, ref);
    }

    function _doPayout(
        address userAddress,
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) internal returns (uint256 tokenId, string memory txid) {

        try IERC20PermitUpgradeable(address(this)).permit(
            userAddress,
            address(this),
            amount,
            deadline,
            v, r, s
        ) {
        } catch {
            emit PermitFailed(userAddress, address(this), amount);
        }

        require(amount >= minimalPayoutAmount, "Fiat24Token: amount < minimal payout");
        tokenId = fiat24account.tokenOfOwnerByIndex(userAddress, 0);
        txid = string(
            abi.encodePacked(uintToString(tokenId), "-", uintToString(block.number))
        );

        address recipient = fiat24account.ownerOf(9102);
        IERC20Upgradeable(address(this)).transferFrom(userAddress, recipient, amount);
    }

    function transferByAccountId(uint256 recipientAccountId, uint256 amount) public returns (bool) {
        address recipient = fiat24account.ownerOf(recipientAccountId);
        bool success = transfer(recipient, amount);
        if (success) {
            emit TransferByAccountId(msg.sender, recipient, amount);
        }
        return success;
    }

    function permitAndTransferFromByAccountId(
        address userAddress,
        uint256 recipientAccountId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public returns (bool) {
        require(hasRole(CASH_OPERATOR_ROLE, _msgSender()), "Fiat24Token: Not a Cash Operator");
        address recipient = fiat24account.ownerOf(recipientAccountId);
        bool success = _permitAndTransferFrom(userAddress, recipient, amount, deadline, v, r, s);
        if (success) {
            emit TransferByAccountId(userAddress, recipient, amount);
        }
        return success;
    }

    function transferFromByAccountId(address userAddress, uint256 recipientAccountId, uint256 amount) public returns (bool) {
        return transferFrom(userAddress,fiat24account.ownerOf(recipientAccountId), amount);
    }

    function balanceOfByAccountId(uint256 accountId) public view returns (uint256) {
        return balanceOf(fiat24account.ownerOf(accountId));
    }

    function tokenTransferAllowed(address from, address to, uint256 amount) public view returns (bool) {
        require(!fiat24account.paused(), "Fiat24Token: All account transfers are paused");
        require(!paused(), "Fiat24Token: All account transfers of this currency are paused");
        if (sanctionCheck) {
            SanctionsList sanctionsList = SanctionsList(sanctionContract);
            bool toIsSanctioned = sanctionsList.isSanctioned(to);
            require(!toIsSanctioned, "Fiat24Token: Transfer to sanctioned address");
            bool fromIsSanctioned = sanctionsList.isSanctioned(from);
            require(!fromIsSanctioned, "Fiat24Token: Transfer from sanctioned address");
        }
        if (from != address(0) && to != address(0)) {
            if (balanceOf(from) < amount) {
                return false;
            }
            uint256 toAmount = amount + balanceOf(to);
            Fiat24Account.Status fromClientStatus;
            uint256 accountIdFrom = fiat24account.historicOwnership(from);
            if (accountIdFrom != 0) {
                fromClientStatus = fiat24account.status(accountIdFrom);
            } else if (from != address(0) && fiat24account.balanceOf(from) > 0) {
                fromClientStatus = Fiat24Account.Status.Tourist;
                accountIdFrom = fiat24account.tokenOfOwnerByIndex(from, 0);
            } else {
                fromClientStatus = Fiat24Account.Status.Na;
            }
            Fiat24Account.Status toClientStatus;
            uint256 accountIdTo = fiat24account.historicOwnership(to);
            if (accountIdTo != 0) {
                toClientStatus = fiat24account.status(accountIdTo);
            } else if (to != address(0) && fiat24account.balanceOf(to) > 0) {
                toClientStatus = Fiat24Account.Status.Tourist;
                accountIdTo = fiat24account.tokenOfOwnerByIndex(to, 0);
            } else {
                toClientStatus = Fiat24Account.Status.Na;
            }
            uint256 amountInChf = convertToChf(amount);
            bool fromLimitCheck = fiat24account.checkLimit(accountIdFrom, amountInChf);
            bool toLimitCheck = fiat24account.checkLimit(accountIdTo, amountInChf);
            // When the money from 91xx, we don't consider the client limit
            if (accountIdFrom >= 9100 && accountIdFrom <= 9199) {
                toLimitCheck = true;
            }
            return (
                fromClientStatus == Fiat24Account.Status.Live
                    && (toClientStatus == Fiat24Account.Status.Live || toClientStatus == Fiat24Account.Status.SoftBlocked) && fromLimitCheck && toLimitCheck
            )
                || (
                    fromClientStatus == Fiat24Account.Status.Live && fromLimitCheck
                        && ((toClientStatus == Fiat24Account.Status.Na || toClientStatus == Fiat24Account.Status.Tourist) && toAmount <= LimitWalkin)
                );
        }
        return false;
    }

    function convertToChf(uint256 amount) public view returns (uint256) {
        return amount.mul(ChfRate).div(1000);
    }

    function convertFromChf(uint256 amount) public view returns (uint256) {
        return amount.mul(1000).div(ChfRate);
    }

    function updateChfRate(uint256 _chfRate) external {
        require(hasRole(RATES_UPDATER_OPERATOR_ROLE, msg.sender), "Fiat24Token: Not a rate updater operator");
        ChfRate = _chfRate;
    }

    function setWithdrawCharge(uint256 withdrawCharge) public {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Fiat24Token: Not an operator admin");
        WithdrawCharge = withdrawCharge;
    }

    function setMinimalPayoutAmount(uint256 minimalPayoutAmount_) public {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Fiat24Token: Not an operator admin");
        minimalPayoutAmount = minimalPayoutAmount_;
    }

    function sendToSundry(address from, uint256 amount) public {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Fiat24Token: Not an operator");
        _transfer(from, fiat24account.ownerOf(9103), amount);
    }

    function setWalkinLimit(uint256 newLimitWalkin) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Fiat24Token: Not an operator admin");
        LimitWalkin = newLimitWalkin;
    }

    function setSanctionCheck(bool sanctionCheck_) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Fiat24Token: Not an operator admin");
        sanctionCheck = sanctionCheck_;
    }

    function setSanctionCheckContract(address sanctionContract_) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Fiat24Token: Not an operator admin");
        sanctionContract = sanctionContract_;
    }

    function setFiat24LockAddress(address fiat24lockAddress_) external {
        require(hasRole(OPERATOR_ADMIN_ROLE, msg.sender), "Fiat24Token: Not an operator admin");
        fiat24lockAddress = fiat24lockAddress_;
    }

    function decimals() public view virtual override returns (uint8) {
        return 2;
    }

    function createTxId(uint256 tokenId_) public view returns (string memory) {
        string memory prefix = "F24-";
        string memory tokenId = uintToString(tokenId_);
        uint256 timestamp = block.timestamp;
        uint256 year;
        uint256 month;
        uint256 day;
        uint256 hour;
        uint256 minute;
        uint256 second;

        (year, month, day, hour, minute, second) = getDateTimeComponents(timestamp);

        string memory timestampStr = string(
            abi.encodePacked(
                uintToString(year),
                padZero(month, 2), // Pad month with zero if needed
                padZero(day, 2) // Pad day with zero if needed
                    /*
                padZero(hour, 2),    // Pad hour with zero if needed
                padZero(minute, 2),  // Pad minute with zero if needed
                padZero(second, 2)   // Pad second with zero if needed
                      */
            )
        );

        // Concatenate the strings
        return string(
            // abi.encodePacked(prefix, tokenId, "-", timestampStr, "-", uintToString(ArbSys(address(100)).arbBlockNumber()) /*,"-", randomFourDigitNumber*/ )
            abi.encodePacked(prefix, tokenId, "-", timestampStr, "-", uintToString(block.number) /*,"-", randomFourDigitNumber*/ )
        );
    }

    function getDateTimeComponents(uint256 timestamp) internal pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        uint256 year;
        uint256 month;
        uint256 day;
        uint256 hour;
        uint256 minute;
        uint256 second;

        year = ORIGIN_YEAR;
        while (timestamp >= YEAR_IN_SECONDS) {
            uint256 secondsInYear = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? LEAP_YEAR_IN_SECONDS : YEAR_IN_SECONDS;
            if (timestamp >= secondsInYear) {
                timestamp -= secondsInYear;
                year++;
            } else {
                break;
            }
        }

        month = 1;
        while (true) {
            uint8[12] memory monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
            if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
                monthDays[1] = 29; // Leap year
            }

            uint256 secondsInMonth = uint256(monthDays[month - 1]) * DAY_IN_SECONDS;

            if (timestamp < secondsInMonth) {
                break;
            }

            timestamp -= secondsInMonth;
            month++;
        }

        day = timestamp / DAY_IN_SECONDS + 1;
        timestamp %= DAY_IN_SECONDS;
        hour = timestamp / 3600;
        timestamp %= 3600;
        minute = timestamp / 60;
        second = timestamp % 60;

        return (year, month, day, hour, minute, second);
    }

    function uintToString(uint256 _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        return string(bstr);
    }

    function padZero(uint256 number, uint256 width) internal pure returns (string memory) {
        if (width == 0) {
            return "";
        }

        uint256 tempNumber = number;
        uint256 digits;
        while (tempNumber != 0) {
            digits++;
            tempNumber /= 10;
        }

        if (digits >= width) {
            return uintToString(number);
        } else {
            bytes memory buffer = new bytes(width);
            uint256 index = width;
            tempNumber = number;
            while (tempNumber != 0) {
                index--;
                buffer[index] = bytes1(uint8(48 + tempNumber % 10)); // Convert to ASCII
                tempNumber /= 10;
            }

            while (index > 0) {
                index--;
                buffer[index] = bytes1(uint8(48)); // Pad with zero
            }

            return string(buffer);
        }
    }

    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        bytes memory bytesArray = new bytes(32);
        uint256 bytesArrayIndex = 0;
        for (uint256 i = 0; i < 32; i++) {
            if (_bytes32[i] != 0) {
                bytesArray[bytesArrayIndex] = _bytes32[i];
                bytesArrayIndex++;
            }
        }
        bytes memory trimmedBytes = new bytes(bytesArrayIndex);
        for (uint256 j = 0; j < bytesArrayIndex; j++) {
            trimmedBytes[j] = bytesArray[j];
        }
        return string(trimmedBytes);
    }

    function pause() public {
        require(hasRole(PAUSE_ROLE, msg.sender), "Fiat24Token: Not a pauser");
        _pause();
    }

    function unpause() public {
        require(hasRole(UNPAUSE_ROLE, msg.sender), "Fiat24Token: Not an unpauser");
        _unpause();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        require(!fiat24account.paused(), "Fiat24Token: all account transfers are paused");
        require(!paused(), "Fiat24Token: all account transfers of this currency are paused");
        if (from != address(0) && to != address(0) && to != fiat24account.ownerOf(9103) && from != fiat24account.ownerOf(9103)) {
            require(tokenTransferAllowed(from, to, amount), "Fiat24Token: Transfer not allowed for various reason");
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        if (from != address(0) && to != address(0) && to != fiat24account.ownerOf(9103) && from != fiat24account.ownerOf(9103)) {
            uint256 accountIdFrom = fiat24account.historicOwnership(from);
            if (accountIdFrom == 0 && fiat24account.balanceOf(from) > 0) {
                accountIdFrom = fiat24account.tokenOfOwnerByIndex(from, 0);
            }
            uint256 accountIdTo = fiat24account.historicOwnership(to);
            if (accountIdTo == 0 && fiat24account.balanceOf(to) > 0) {
                accountIdTo = fiat24account.tokenOfOwnerByIndex(to, 0);
            }
            fiat24account.updateLimit(accountIdFrom, convertToChf(amount));
            fiat24account.updateLimit(accountIdTo, convertToChf(amount));
        }
        super._afterTokenTransfer(from, to, amount);
    }
}
