// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./interfaces/IDeploy.sol";
import "./interfaces/ISignals.sol";
import "./interfaces/IConfig.sol";
import "./interfaces/IRounds.sol";
import "./interfaces/IErrors.sol";
import {Status} from "./types/Status.sol";

/** 
 * @title Signals contract
 * @dev Creates and manages signals for a currency
 */
contract Signals is ISignals, IErrors {

    // STRUCTS AND EVENTS

    struct Signal {
        uint16 roundId; // starts with 0
        uint64 time; // creation time, as block.timestamp
        SignalType signalType; // signal type
        uint64 signalRate; // signal rate in USD with 2 decimals
        uint64 expirationTime; // signal expiration time
    }

    struct AccountSignals {
        uint32 signalsCount; // wallet address signals count
        mapping (uint32 => Signal) signalsMap; // [signalId] => Signal
    }

    enum SignalType {
        BuyStop, // default equal to 0
        BuyLimit, // equal to 1
        SellStop, // equal to 2
        SellLimit // equal to 3
    }

    struct RoundData {
        Status status;
        uint64 snapshotTime; // IMMUTABLE
        uint baseTicketPrice; // IMMUTABLE
        uint16 servicePercent;  // IMMUTABLE, measured in percent points, ie 1/100 of percent
        uint64 benchmarkDeviation; // IMMUTABLE, in USD with 2 decimals
        uint rewardPool;
        uint16 signalsCount;
        uint8 winnerSignalsCount;
        uint8 postedWinnerSignals;
        uint serviceValue; // in Wei
        bool serviceIsPaid;
    }

    struct DecodedWinnerSignal {
        address winner; // owner wallet address
        uint16 signalId; // starts with 0
        uint8 position; // 1 to 20
        uint32 challenge; // with 2 decimals
        uint64 exitRate; // in USD with 2 decimals
    }

    struct WinnerSignal {
        address winner; // owner wallet address
        uint16 signalId; // starts with 0
        uint8 position; // 1 to 20
        uint32 challenge; // with 2 decimals
        uint64 exitRate; // in USD with 2 decimals
        bool paid;
        uint rewardValue; // in Wei
    }

    struct SignalParams {
        uint16 servicePercent;  // measured in percent points, ie 1/100 of percent
        uint gasReserve; // in Wei
    }

    event SignalIsDeployed(
        address indexed issuer,
        uint32 signalId,
        uint16 roundId,
        uint64 signalTime,
        uint8 signalType,
        uint64 signalRate,
        uint64 expirationTime,
        uint currentRoundRewardPool,
        uint totalRewardPool
    );

    event WinnerSignalsArePosted(
        uint8 winnerSignalsCount
    );

    // PRIVATE VARIABLES
    
    RoundData private _zeroRoundData = RoundData({
        status: Status.NotStarted,
        snapshotTime: 0, // IMMUTABLE, in seconds
        baseTicketPrice: 0, // IMMUTABLE, in Wei
        servicePercent: 0,  // IMMUTABLE, measured in percent points, ie 1/100 of percent
        benchmarkDeviation: 0, // IMMUTABLE, in USD with 2 decimals
        rewardPool: 0, // round reward pool, in Wei
        signalsCount: 0, // number of round signals, integer
        winnerSignalsCount: 0, // number of winning signals, up to 20, integer
        postedWinnerSignals: 0, // number of posted winning signals, up to 20, integer
        serviceValue: 0, // in Wei
        serviceIsPaid: false
    });
    bool private _signalsNotLocked;

    // INTERNAL VARIABLES

    IRounds internal roundsContract;
    IConfig internal configContract;
    
    // PUBLIC VARIABLES

    // signals parameters
    string public currency;
    uint64 public deploymentTime;
    address payable public superAdmin;
    address payable public daemon;
    address payable public serviceFeeRecipient;
    uint public totalRewardPool; // in Wei
    uint public futureRoundsRewardPool; // in Wei

    uint16 public lastPostedRoundId;
    bool public readyToBeClosed;

    SignalParams public signalParams;

    // mappings for rounds and signals
    mapping(uint16 => RoundData) public signalRounds; // [roundId] rounds data by roundId 
    mapping(address => AccountSignals) public signals; // [address]{[signalsCount],{[signalId],..}} signals by addresses
    mapping(uint16 => WinnerSignal[20]) public winnerSignals; // [roundId][winnerId]

    // CONSTANTS & IMMUTABLES
    
    // contract constants
    address public immutable DEPLOY;
    address public immutable CONFIG;
    address public immutable ROUNDS;

    // MODIFIERS

    modifier superAdminOnly() {
        if (msg.sender != superAdmin) {
            revert CallerIsNotSuperAdmin();
        }
        _;
    }

    modifier daemonOrSuperAdminOnly() {
        if ((msg.sender != superAdmin) && (msg.sender != daemon)) {
            revert CallerIsNotDaemonOrSuperAdmin();
        }
        _;
    }

    modifier roundsOnly() {
        if (msg.sender != ROUNDS) {
            revert CallerIsNotRoundsContract();
        }
        _;
    }

    modifier activeStatusOnly() {
        if (signalRounds[roundsContract.currentRoundId()].status != Status.Active) {
            revert StatusIsNotActive();
        }
        _;
    }

    modifier closingStatusOnly() {
        if (signalRounds[roundsContract.currentRoundId()].status != Status.Closing) {
            revert StatusIsNotClosing();
        }
        _;
    }

    modifier closedStatusOnly() {
        if (signalRounds[roundsContract.currentRoundId()].status != Status.Closed) {
            revert StatusIsNotClosed();
        }
        _;
    }

    modifier signalsNotLocked() {
        if (_signalsNotLocked != true) {
            revert PredictionsAreTemporarilyLocked();
        }
        _signalsNotLocked = false;
        _;
        _signalsNotLocked = true;
    }

    constructor(address _deployAddress, string memory _currency) payable {
        superAdmin = payable(msg.sender);
        daemon = superAdmin;
        currency = _currency;
        
        DEPLOY = _deployAddress;
        CONFIG = payable(IDeploy(DEPLOY).config());
        ROUNDS = payable(IDeploy(DEPLOY).getRounds(currency));

        roundsContract = IRounds(payable(ROUNDS));
        configContract = IConfig(payable(CONFIG));

        setSignalParams(
            2000, // service rate, measured in percentage points, 1/100 of percent: 15%
            1_000_000 gwei // gas reserve: 0.0004 MATIC
        );

        {
            totalRewardPool = 0;
            futureRoundsRewardPool = 0;
            _signalsNotLocked = true;
            deploymentTime = uint64(block.timestamp);
        }
        
        {
            // setting initial round
            RoundData memory _newRoundData;
            _newRoundData = _zeroRoundData;
            _newRoundData.status = roundsContract.draftRoundStatus(); // from 0 to 4
            _newRoundData.snapshotTime = roundsContract.draftRoundSnapshotTime(); // in seconds
            _newRoundData.baseTicketPrice = configContract.baseTicketPrice(); // in Wei
            _newRoundData.servicePercent = signalParams.servicePercent;  // measured in percent points, ie 1/100 of percent
            _newRoundData.benchmarkDeviation = roundsContract.benchmarkDeviation(); // in USD with 2 decimals

            signalRounds[roundsContract.draftRoundRoundId()] = _newRoundData;
            lastPostedRoundId = roundsContract.draftRoundRoundId();
        }
    }

    receive() external payable {}

    fallback() external payable {} 

    function setSignalParams(
        uint16 _servicePercent,  // measured in percent points, ie 1/100 of percent
        uint _gasReserve
    ) public superAdminOnly() {
        if (_servicePercent > configContract.MAX_SERVICE_PERCENT()) {
            revert ServicePercentExceedsUpperLimit();
        }

        SignalParams memory _signalParams;
        _signalParams.servicePercent = _servicePercent; // measured in percentage points, 1/100 of percent
        _signalParams.gasReserve = _gasReserve;

        signalParams = _signalParams;
    }

    function setSuperAdmin(address _superAdmin) external superAdminOnly() {
        superAdmin = payable(_superAdmin);
    }

    function setDaemon(address _daemon) external superAdminOnly() {
        daemon = payable(_daemon);
    }

    function setServiceFeeRecipient(address _recipient) external superAdminOnly() {
        serviceFeeRecipient = payable(_recipient);
    }

    function newRound() public roundsOnly() {
        if (roundsContract.draftRoundRoundId() != lastPostedRoundId + 1) {
            revert WrongRoundId();
        }

        // setting new round
        RoundData memory _newRoundData;
        _newRoundData = _zeroRoundData;
        _newRoundData.status = roundsContract.draftRoundStatus();
        _newRoundData.snapshotTime = roundsContract.draftRoundSnapshotTime(); // in seconds
        _newRoundData.baseTicketPrice = configContract.baseTicketPrice(); // in Wei
        _newRoundData.servicePercent = signalParams.servicePercent;  // measured in percent points, ie 1/100 of percent
        _newRoundData.benchmarkDeviation = roundsContract.benchmarkDeviation(); // in USD with 2 decimals

        signalRounds[roundsContract.draftRoundRoundId()] = _newRoundData;
        lastPostedRoundId = roundsContract.draftRoundRoundId();
    }

    function changeCurrentRoundStatus(Status _status) public roundsOnly() {
        signalRounds[roundsContract.currentRoundId()].status = _status;
    }

    function switchRound() public roundsOnly() closedStatusOnly() {
        futureRoundsRewardPool -= signalRounds[roundsContract.currentRoundId()].rewardPool;
        if (address(this).balance > signalParams.gasReserve) {
            totalRewardPool = address(this).balance - signalParams.gasReserve;
        } else {
            totalRewardPool = 0;
        }
   
    }

    function newSignal(
        uint8 _signalType, // from 0 to 3
        uint64 _signalRate, // with 2 decimals, eg 3456798 (== USD 34567.98)
        uint64 _expirationTime // signal expiration time, in seconds
    ) external payable signalsNotLocked() {
        if (_expirationTime <= block.timestamp + 2 * 60 * 60) {
            revert WrongExpirationTime();
        }
        if (_expirationTime >= roundsContract.lastSnapshotTime() - configContract.HALT_TIME_SPAN()) {
            revert WrongExpirationTime();
        }
        if (msg.value < configContract.baseTicketPrice()) {
            revert NotEnoughFunds();
        }

        Signal memory _newSignal;
        _newSignal.time = uint64(block.timestamp);
        if ( _signalType == 0 ) {
            _newSignal.signalType = SignalType.BuyStop;
        } else if ( _signalType == 1 ) {
            _newSignal.signalType = SignalType.BuyLimit;
        } else if ( _signalType == 2 ) {
            _newSignal.signalType = SignalType.SellStop;
        } else {
            _newSignal.signalType = SignalType.SellLimit;
        }
        _newSignal.roundId = _timeToRoundId(_expirationTime);
        _newSignal.signalRate = _signalRate; // with 2 decimals eg 3128514 (=== 31285.14)
        _newSignal.expirationTime = _expirationTime;

        signals[msg.sender].signalsMap[signals[msg.sender].signalsCount] = _newSignal;
        signals[msg.sender].signalsCount++;

        signalRounds[_newSignal.roundId].signalsCount++;
        signalRounds[_newSignal.roundId].rewardPool += msg.value;
        if (address(this).balance + msg.value > signalParams.gasReserve) {
            totalRewardPool = address(this).balance + msg.value - signalParams.gasReserve;
        } else {
            totalRewardPool = 0;
        }

        if (_newSignal.roundId > roundsContract.currentRoundId()) {
            futureRoundsRewardPool += msg.value;
        }

        emit SignalIsDeployed(
            msg.sender,
            signals[msg.sender].signalsCount - 1,
            signals[msg.sender].signalsMap[signals[msg.sender].signalsCount - 1].roundId,
            signals[msg.sender].signalsMap[signals[msg.sender].signalsCount - 1].time,
            _signalType,
            _signalRate, // measured in USD with 2 decimal digits
            _expirationTime,
            totalRewardPool > futureRoundsRewardPool ? totalRewardPool - futureRoundsRewardPool : 0,
            totalRewardPool
        );
    } 

    function _timeToRoundId(uint64 _time) private view returns (uint16 _roundId) {
        for (uint16 i = roundsContract.currentRoundId(); i <= roundsContract.lastActiveRoundId(); i++) {
            if (_time <= signalRounds[i].snapshotTime - configContract.HALT_TIME_SPAN()) {
                _roundId = i;
            }
        }
    }

    function postWinnerSignals(
        uint16 _roundId,
        uint8 _numberOfWinners,
        bytes memory _encodedWinners // @dev see below
    ) external daemonOrSuperAdminOnly() closingStatusOnly() {
        if (_roundId != roundsContract.currentRoundId()) {
            revert RoundIdDoesNotMatchCurrentRoundId();
        }
        if (_numberOfWinners > 20) {
            revert WrongNumberOfWinners();
        }

        // @dev
        /////////////////////////////////////////////////
        bytes memory _testEncodedWinners = abi.encode([
                DecodedWinnerSignal({winner: address(this), signalId: 14, position: 1, challenge: 34463, exitRate: 4363456}),
                DecodedWinnerSignal({winner: address(this), signalId: 6, position: 2, challenge: 7456, exitRate: 3243456}),
                DecodedWinnerSignal({winner: address(this), signalId: 4, position: 3, challenge: 6512, exitRate: 1363456})
            ]);
        /////////////////////////////////////////////////

        (DecodedWinnerSignal[] memory _decodedWinnerSignals) = abi.decode(_testEncodedWinners, (DecodedWinnerSignal[])); // @dev
        if (_numberOfWinners !=  _decodedWinnerSignals.length) {
            revert WrongLengthOfWinnersData();
        }

        signalRounds[roundsContract.currentRoundId()].winnerSignalsCount = _numberOfWinners;

        uint8 position = 0;
        uint32 challenge = 0;  
   
        for (uint8 i = 0; i < _numberOfWinners; i++) {    
                WinnerSignal memory _newWinnerSignal;
                _newWinnerSignal.winner = _decodedWinnerSignals[i].winner;
                _newWinnerSignal.signalId = _decodedWinnerSignals[i].signalId;
                _newWinnerSignal.position = _decodedWinnerSignals[i].position;
                _newWinnerSignal.challenge = _decodedWinnerSignals[i].challenge;
                _newWinnerSignal.exitRate = _decodedWinnerSignals[i].exitRate;
                _newWinnerSignal.paid = false;
                _newWinnerSignal.rewardValue = 0;

                if (_newWinnerSignal.position < position) {
                    revert NonIncreasingPositionsData();
                }
                position = _newWinnerSignal.position;

                if (i > 0) {
                    if (_newWinnerSignal.challenge > challenge) {
                        revert NonDecreasingChallengesData();
                    }
                }
                challenge = _newWinnerSignal.challenge;
              
                winnerSignals[roundsContract.currentRoundId()][i] = _newWinnerSignal;
                signalRounds[roundsContract.currentRoundId()].postedWinnerSignals++;
        }

        emit WinnerSignalsArePosted(
            _numberOfWinners
        );
    }  

    function signalsClosing() public daemonOrSuperAdminOnly() closingStatusOnly() {
        _signalRewardAndServiceValuesCalculation();

        for (uint8 i = 0; i < signalRounds[roundsContract.currentRoundId()].winnerSignalsCount; i++) {
            sendReward(i, payable(winnerSignals[roundsContract.currentRoundId()][i].winner));
        }

        sendTotalService();
        readyToBeClosed = true;
    }

    function _signalRewardAndServiceValuesCalculation() private {
        (uint[20] memory weights, uint weightsSum) = _challengeWeights(); // 4 decimals
        uint rewardPool;

        if (totalRewardPool > futureRoundsRewardPool) {
            rewardPool = totalRewardPool - futureRoundsRewardPool;
        } else {
            rewardPool = 0;
        }

        for (uint8 i = 0; i < signalRounds[roundsContract.currentRoundId()].winnerSignalsCount; i++) {
            winnerSignals[roundsContract.currentRoundId()][i].rewardValue =  rewardPool * weights[i] / weightsSum; // in Wei
        }

        signalRounds[roundsContract.currentRoundId()].serviceValue = rewardPool * signalRounds[roundsContract.currentRoundId()].servicePercent / 10 ** 4; // in Wei
    }

    function _challengeWeights() private view returns (uint[20] memory _weights, uint _sum) {
        _sum = 0;
        for (uint8 i = 0; i < signalRounds[roundsContract.currentRoundId()].winnerSignalsCount; i++) {
            _sum += _challengeWeight(i); // 4 decimals
            _weights[i] = _challengeWeight(i); // 4 decimals
        }
    }

    function _challengeWeight(uint8 _index) private view returns (uint _weight) {
        uint8 mult = 1;
        if (signals[winnerSignals[roundsContract.currentRoundId()][_index].winner].signalsMap[winnerSignals[roundsContract.currentRoundId()][_index].signalId].signalType == SignalType.BuyStop &&
        winnerSignals[roundsContract.currentRoundId()][_index].exitRate >= signals[winnerSignals[roundsContract.currentRoundId()][_index].winner].signalsMap[winnerSignals[roundsContract.currentRoundId()][_index].signalId].signalRate) {
            mult = 2;
        }
        if (signals[winnerSignals[roundsContract.currentRoundId()][_index].winner].signalsMap[winnerSignals[roundsContract.currentRoundId()][_index].signalId].signalType == SignalType.SellStop &&
        winnerSignals[roundsContract.currentRoundId()][_index].exitRate <= signals[winnerSignals[roundsContract.currentRoundId()][_index].winner].signalsMap[winnerSignals[roundsContract.currentRoundId()][_index].signalId].signalRate) {
            mult = 2;
        }
        _weight = uint(winnerSignals[roundsContract.currentRoundId()][_index].challenge * mult); // 4 decimals
    }

    function sendReward(uint8 _winnerId, address payable _winner) public payable daemonOrSuperAdminOnly() closingStatusOnly() {
        (bool sent, ) = _winner.call{value: winnerSignals[roundsContract.currentRoundId()][_winnerId].rewardValue}("");
        if (!sent) {
            revert FailedToSendReward();
        }
        if (sent) {
            winnerSignals[roundsContract.currentRoundId()][_winnerId].paid = true;
        }
    }

    function sendTotalService() public payable daemonOrSuperAdminOnly() closingStatusOnly() {
        (bool sent, ) = serviceFeeRecipient.call{value: signalRounds[roundsContract.currentRoundId()].serviceValue}("");
        if (!sent) {
            revert FailedToSendService();
        }
        if (sent) {
            signalRounds[roundsContract.currentRoundId()].serviceIsPaid = true;
        }
    }   

}
