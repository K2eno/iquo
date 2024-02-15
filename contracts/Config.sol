// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./interfaces/IDeploy.sol";
import "./interfaces/IErrors.sol";

/** 
 * @title Deploy contract
 * @dev Manages all contract addresses for a currency
 */
contract Deploy is IDeploy, IErrors {

    address public superAdmin;
    address public config;

    struct Addresses {
        address rounds;
        address signals;
        address quotes;
    }

    mapping (string => Addresses) contracts; // [currency] => {addresses}

    modifier superAdminOnly() {
        if (msg.sender != superAdmin) {
            revert CallerIsNotSuperAdmin();
        }
        _;
    }

    constructor() {
        superAdmin = msg.sender; // contract creator is super admin
    }

    function setSuperAdmin(address _superAdmin) external superAdminOnly() {
        superAdmin = _superAdmin;
    }

    function setConfig(address _config) external superAdminOnly() {
        config = _config;
    }

    function setRounds(string memory _currency, address _rounds) external superAdminOnly() {
        contracts[_currency].rounds = _rounds;
    }

    function setSignals(string memory _currency, address _signals) external superAdminOnly() {
        contracts[_currency].signals = _signals;
    }

    function setQuotes(string memory _currency, address _quotes) external superAdminOnly() {
        contracts[_currency].quotes = _quotes;
    }

    function getRounds(string memory _currency) external view returns (address) {
        return contracts[_currency].rounds;
    }

    function getSignals(string memory _currency) external view returns (address) {
        return contracts[_currency].signals;
    }

    function getQuotes(string memory _currency) external view returns (address) {
        return contracts[_currency].quotes;
    }

}
