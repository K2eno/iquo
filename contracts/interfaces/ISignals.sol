// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Status} from "../types/Status.sol";

interface ISignals {

    // setters
    function setSuperAdmin(address _superAdmin) external;

    function setDaemon(address _daemon) external;

    function setServiceFeeRecipient(address _recipient) external;

    function newRound() external;

    function changeCurrentRoundStatus(Status _status) external;

    function switchRound() external;

    function newSignal(uint8 _signalType, uint64 _signalRate, uint64 _expirationTime) external payable;

    function postWinnerSignals(uint16 _roundId, uint8 _numberOfWinners, bytes memory _encodedWinners) external;

    function signalsClosing() external;

    function sendReward(uint8 _winnerId, address payable _winner) external payable;

    function sendTotalService() external payable;

    // getters
    function readyToBeClosed() external view returns (bool);
    
}
