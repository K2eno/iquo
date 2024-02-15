// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./interfaces/IConfig.sol";
import "./interfaces/IErrors.sol";

/** 
 * @title Config contract
 * @dev Stores global parameters
 */
contract Config is IConfig, IErrors {

    // VARIABLES

    address public globalAdmin;
    uint public  baseTicketPrice = 1_000_000 gwei; // minimal ticket price in native BC currency, measured in gWei: 0.0005 MATIC

    // CONSTANTS

    uint64 public constant MODEL_HORIZON = 28 * 24 * 60 * 60; // max predictions duration, in seconds: 28 days
    uint64 public constant HALT_TIME_SPAN = 2 * 60 * 60; // time period immediately preceding snapshot time, in seconds: 2 hours
    uint8 public constant MAX_NUMBER_OF_ACTIVE_ROUNDS = 4;
    uint16 public constant MAX_SERVICE_PERCENT = 2000; // max applicable service fee percent, in percent points: 20.00%
    bool public constant TEST_MODE = true;

    // MODIFIERS

    modifier globalAdminOnly() {
        if (msg.sender != globalAdmin) {
            revert CallerIsNotGlobalAdmin();
        }
        _;
    }
    
    constructor() payable {
        globalAdmin = msg.sender; // contract creator is global admin
    }

    function setGlobalAdmin(address _globalAdmin) external globalAdminOnly() {
        globalAdmin = _globalAdmin;
    }

    function setBaseTicketPrice(uint _baseTicketPrice) external globalAdminOnly() {
        baseTicketPrice = _baseTicketPrice;
    }

}
