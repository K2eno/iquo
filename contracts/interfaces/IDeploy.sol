// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

interface IDeploy {

    // setters
    function setSuperAdmin(address _superAdmin) external;

    function setConfig(address _config) external;

    function setRounds(string memory _currency, address _rounds) external;

    function setSignals(string memory _currency, address _signals) external;

    function setQuotes(string memory _currency, address _quotes) external;

    // getters
    function getRounds(string memory _currency) external returns (address);

    function getSignals(string memory _currency) external returns (address);

    function getQuotes(string memory _currency) external returns (address);

    function superAdmin() external returns (address);
    
    function config() external returns (address);

}
