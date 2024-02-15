// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Status} from "../types/Status.sol";

interface IQuotes {
    
    // setters
    function setSuperAdmin(address _superAdmin) external;

    function setDaemon(address _daemon) external;

    function setServiceFeeRecipient(address _recipient) external;

    function newRound() external;

    function changeCurrentRoundStatus(Status _status) external;

    function switchRound() external;

    function newQuote(uint64 _quoteRate, uint16 _roundId, uint8 _timeLeftPercent) external payable;

    function postSnapshotPriceAndFeedId(uint64 _snapshotPrice, uint80 _datafeedRoundId) external;

    function postWinnerQuotes(uint16 _roundId, uint8 _numberOfWinners, bytes memory _encodedWinners) external; 

    function quotesClosing() external;

    function sendReward(uint8 _winnerId, address payable _winner) external payable;

    function sendService(uint8 _winnerId) external payable;
        
    // getters
    function readyToBeClosed() external view returns (bool);

}
