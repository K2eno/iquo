// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

interface IConfig {

    // setters
    function setGlobalAdmin(address _globalAdmin) external;

    function setBaseTicketPrice(uint _baseTicketPrice) external;

    // getters
    function baseTicketPrice() external view returns (uint);

    function MODEL_HORIZON() external view returns (uint64);

    function HALT_TIME_SPAN() external view returns (uint64);

    function MAX_NUMBER_OF_ACTIVE_ROUNDS() external view returns (uint8);

    function MAX_SERVICE_PERCENT() external view returns (uint16);

    function TEST_MODE() external view returns (bool);

}
