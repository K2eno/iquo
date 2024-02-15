// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./interfaces/IDeploy.sol";
import "./interfaces/IRounds.sol";
import "./interfaces/IConfig.sol";
import "./interfaces/ISignals.sol";
import "./interfaces/IQuotes.sol";
import "./interfaces/IErrors.sol";
import {Status} from "./types/Status.sol";

/** 
 * @title Rounds contract
 * @dev Creates and manages rounds for a currency
 */
contract Rounds is IRounds, IErrors {

    // STRUCTS AND EVENTS

    struct Round {
        Status status;
        uint64 snapshotTime;
    }

    event RoundStatusHasChanged(
        uint16 indexed roundId,
        uint8 newStatusIndex
    );

    event NewRoundIsActivated(
        uint16 indexed roundId // new created round ID
    );

    event RoundIsSwitched(
        uint16 indexed roundId // new current round ID
    );

    // PRIVATE VARIABLES

    // INTERNAL VARIABLES

    // PUBLIC VARIABLES

    // currency parameters
    string public currency;
    uint64 public benchmarkDeviation; // in USD with 2 decimals

    // draft round parameters
    Status public draftRoundStatus;
    uint64 public draftRoundSnapshotTime;
    uint16 public draftRoundRoundId;

    // signals and quotes contract addresses
    address payable public signalsAddress;
    address payable public quotesAddress;

    // contract parameters
    uint64 public deploymentTime;
    uint16 public currentRoundId;
    uint16 public lastActiveRoundId;
    uint64 public lastSnapshotTime;
    address payable public superAdmin;
    address payable public daemon;
    address payable public serviceFeeRecipient;

    // mappings
    mapping(uint16 => Round) public rounds; // [roundId]

    // CONSTANTS & IMMUTABLES
    
    // contract constants
    address public immutable DEPLOY;
    address public immutable CONFIG;

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

    modifier closingStatusOnly() {
        if (rounds[currentRoundId].status != Status.Closing) {
            revert StatusIsNotClosing();
        }
        _;
    }

    modifier closedStatusOnly() {
        if (rounds[currentRoundId].status != Status.Closed) {
            revert StatusIsNotClosed();
        }
        _;
    }

    constructor(address _deployAddress, string memory _currency, uint64 _benchmarkDeviation) payable {
        superAdmin = payable(msg.sender); // contract creator is super admin
        daemon = superAdmin;

        DEPLOY = _deployAddress;
        CONFIG = IDeploy(DEPLOY).config();

        setCurrencyParameters(
            _currency, // as string, eg 'BTC', 'ETH'
            _benchmarkDeviation // benchmark deviation, measured in USD with 2 decimal digits
        );

        {
            currentRoundId = 0; // starts with 0 for the first round
            lastActiveRoundId = 0;
            deploymentTime = uint64(block.timestamp);
        }
        
        {
            // @test has to be changed
            // round initialization
            Round memory _initialRound;
            _initialRound.status = Status.NotStarted;
            _initialRound.snapshotTime = deploymentTime + 7 * 24 * 60 * 60; // plus 7 days from deployment time

            rounds[0] = _initialRound;
            lastSnapshotTime = _initialRound.snapshotTime;
        }
    }

    receive() external payable {}

    fallback() external payable {}

    function setCurrencyParameters(
        string memory _currency,
        uint64 _benchmarkDeviation
    ) public superAdminOnly() {
        currency = _currency;
        benchmarkDeviation = _benchmarkDeviation; // measured in USD with 2 decimal digits
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

    function setSignalsAndQuotesAddresses() external superAdminOnly() {
        signalsAddress = payable(IDeploy(DEPLOY).getSignals(currency));
        quotesAddress = payable(IDeploy(DEPLOY).getQuotes(currency));
    }

    // @test to be deleted in production
    function setCurrentRoundSnapshotTime(uint64 _snapshotTime) external superAdminOnly() {
        rounds[currentRoundId].snapshotTime = _snapshotTime;
    }

    function draftNewRound(
        uint64 _snapshotTime,
        uint16 _roundId
    ) public superAdminOnly() {
        if (_snapshotTime <= block.timestamp + 3 * 24 * 60 * 60) {
            revert WrongSnapshotTime();
        }
        if (_roundId != lastActiveRoundId + 1) {
            revert WrongRoundId();
        }
        
        draftRoundStatus = Status.NotStarted;
        draftRoundSnapshotTime = _snapshotTime;
        draftRoundRoundId = _roundId;
    }

    function postAndActivateNewRound() external daemonOrSuperAdminOnly() {
        if (draftRoundRoundId != lastActiveRoundId + 1) {
            revert WrongRoundId();
        }
        if (draftRoundRoundId >= currentRoundId + IConfig(CONFIG).MAX_NUMBER_OF_ACTIVE_ROUNDS()) {
            revert WrongRoundId();
        }
        
        rounds[lastActiveRoundId + 1].snapshotTime = draftRoundSnapshotTime;
        rounds[lastActiveRoundId + 1].status = Status.Active;
        lastActiveRoundId++;
        lastSnapshotTime = rounds[lastActiveRoundId].snapshotTime;

        ISignals(signalsAddress).newRound();
        IQuotes(quotesAddress).newRound();

        emit NewRoundIsActivated(
            lastActiveRoundId // last active round ID
        );
    }

    function changeRoundStatus() external daemonOrSuperAdminOnly() {
        if (rounds[currentRoundId].status == Status.NotStarted) {
            rounds[currentRoundId].status = Status.Active;
        } else if (rounds[currentRoundId].status == Status.Active) {
            rounds[currentRoundId].status = Status.Halt;
        } else if (rounds[currentRoundId].status == Status.Halt) {
            rounds[currentRoundId].status = Status.Closing;
        } else {
            // nothing happens
        }

        ISignals(signalsAddress).changeCurrentRoundStatus(rounds[currentRoundId].status);
        IQuotes(quotesAddress).changeCurrentRoundStatus(rounds[currentRoundId].status);

        emit RoundStatusHasChanged(
            currentRoundId,
            uint8(rounds[currentRoundId].status)
        );
    }

    function closeRound() external daemonOrSuperAdminOnly() closingStatusOnly() {
        if (!ISignals(signalsAddress).readyToBeClosed()) {
            revert SignalsNotReadyToBeClosed();
        }
        if (!IQuotes(quotesAddress).readyToBeClosed()) {
            revert QuotesNotReadyToBeClosed();
        }

        rounds[currentRoundId].status = Status.Closed;

        ISignals(signalsAddress).changeCurrentRoundStatus(rounds[currentRoundId].status);
        IQuotes(quotesAddress).changeCurrentRoundStatus(rounds[currentRoundId].status);

        emit RoundStatusHasChanged(
            currentRoundId,
            uint8(rounds[currentRoundId].status)
        );
    }

    function switchToNextRound(uint16 _nextRoundId) external daemonOrSuperAdminOnly() closedStatusOnly() {
        if (rounds[currentRoundId].status != Status.Closed) {
            revert StatusIsNotClosed();
        }
        if (lastActiveRoundId < currentRoundId + 1) {
            revert NoNewActiveRounds();
        }
        if (_nextRoundId != currentRoundId + 1) {
            revert WrongRoundId();
        }

        currentRoundId++;

        ISignals(signalsAddress).switchRound();
        IQuotes(quotesAddress).switchRound();

        emit RoundIsSwitched(
            currentRoundId
        );
    }

}
