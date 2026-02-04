// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./libraries/Multicall3.sol";

/**
 * @title SafeExecutor
 * @dev A contract to safely execute multiple calls (multicall) with role-based access control
 * and a once-per-day execution guarantee based on a provided date string.
 * The caller is responsible for formatting the calls into the Multicall3.Call3 struct array.
 */
contract F24Multicall is AccessControl {

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    mapping(string => bool) public isDateExecuted;

    event ExecutionRecorded(string date, address indexed executor);

    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    /**
     * @dev Sets up the contract, granting admin and executor roles to the deployer.
     * @param admin The address of the admin role.
     */
    constructor(address admin) {

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    /**
     * @dev Executes a batch of calls formatted as Multicall3.Call3 structs.
     * @param calls An array of Multicall3.Call3 structs.
     * @param dateString A unique string representing the date, e.g., "20250728".
     */
    function execute(
        Call3[] calldata calls,
        string calldata dateString
    ) external payable onlyRole(EXECUTOR_ROLE) {

        require(!isDateExecuted[dateString], "SafeExecutor: Already executed for this date");

        aggregate3(calls);

        // Record that the execution for this date has been completed.
        isDateExecuted[dateString] = true;
        emit ExecutionRecorded(dateString, _msgSender());
    }

    /// @notice Aggregate calls, ensuring each returns success if required
    /// @param calls An array of Call3 structs
    /// @return returnData An array of Result structs
    function aggregate3(Call3[] calldata calls) public payable onlyRole(EXECUTOR_ROLE) returns (Result[] memory returnData) {
        uint256 length = calls.length;
        returnData = new Result[](length);
        Call3 calldata calli;
        for (uint256 i = 0; i < length;) {
            Result memory result = returnData[i];
            calli = calls[i];
            (result.success, result.returnData) = calli.target.call(calli.callData);
            assembly {
            // Revert if the call fails and failure is not allowed
            // `allowFailure := calldataload(add(calli, 0x20))` and `success := mload(result)`
                if iszero(or(calldataload(add(calli, 0x20)), mload(result))) {
                // set "Error(string)" signature: bytes32(bytes4(keccak256("Error(string)")))
                    mstore(0x00, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                // set data offset
                    mstore(0x04, 0x0000000000000000000000000000000000000000000000000000000000000020)
                // set length of revert string
                    mstore(0x24, 0x0000000000000000000000000000000000000000000000000000000000000017)
                // set revert string: bytes32(abi.encodePacked("Multicall3: call failed"))
                    mstore(0x44, 0x4d756c746963616c6c333a2063616c6c206661696c6564000000000000000000)
                    revert(0x00, 0x64)
                }
            }
            unchecked { ++i; }
        }
    }
}