// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Status} from "../types/Status.sol";

interface IRounds {

    // setters
    function setCurrencyParameters(string memory _currency, uint64 _benchmarkDeviation) external;

    function setSuperAdmin(address _superAdmin) external;

    function setDaemon(address _daemon) external;

    function setServiceFeeRecipient(address _recipient) external;

    function setSignalsAndQuotesAddresses() external;

    function setCurrentRoundSnapshotTime(uint64 _snapshotTime) external;

    function postAndActivateNewRound() external;

    function changeRoundStatus() external;

    function closeRound() external;

    function switchToNextRound(uint16 _nextRoundId) external;

    // getters
    function currentRoundId() external view returns (uint16);

    function lastActiveRoundId() external view returns (uint16);

    function draftRoundStatus() external view returns (Status);

    function draftRoundSnapshotTime() external view returns (uint64);

    function draftRoundRoundId() external view returns (uint16);

    function benchmarkDeviation() external view returns (uint64);

    function lastSnapshotTime() external view returns (uint64);

}
