// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./interfaces/IDeploy.sol";
import "./interfaces/IQuotes.sol";
import "./interfaces/IConfig.sol";
import "./interfaces/IRounds.sol";
import "./interfaces/IErrors.sol";

/** 
 * @title Quotes contract
 * @dev Creates and manages quotes for a currency
 */
contract Quotes is IQuotes, IErrors {

    // STRUCTS AND EVENTS

    struct Quote {
        uint16 roundId; // starts with 0
        uint64 time; // creation time, as block.timestamp
        uint32 tickets; // number of tickets, with 2 decimals
        uint64 quoteRate; // quote rate in USD with 2 decimals
        uint stake; // stake value in Wei
    }

    struct AccountQuotes {
        uint32 quotesCount; // wallet address quotes count
        mapping (uint32 => Quote) quotesMap; // [quoteId] => Quote
    }

    struct RoundData {
        Status status;
        uint64 snapshotTime; // IMMUTABLE
        uint baseTicketPrice; // IMMUTABLE
        uint16 servicePercent;  // IMMUTABLE, measured in percent points, ie 1/100 of percent
        uint64 benchmarkDeviation; // IMMUTABLE, in USD with 2 decimals
        uint rewardPool;
        uint16 quotesCount;
        uint8 winnerQuotesCount;
        uint8 postedWinnerQuotes;
        bool winnerQuotesAreValidated;
        uint80 datafeedRoundId;
        uint64 snapshotPrice; // in USD with 2 decimals
        bool isAce;
    }

    struct DecodedWinnerQuote {
        address winner; // owner wallet address
        uint16 quoteId; // starts with 0
        uint8 position; // 1 to 20
        uint16 normalWeight; // measured in percent points, ie 1/100 of percent
    }
    
    struct WinnerQuote {
        address winner;
        uint16 quoteId; // starts with 0
        uint8 position; // 1 to 3
        uint16 normalWeight; // measured in percent points, ie 1/100 of percent
        uint64 deviation; // in USD with 2 decimals
        uint rewardValue; // in Wei
        uint serviceValue; // in Wei
        bool rewardIsPaid;
        bool serviceIsPaid;
    }

    struct QuoteParams {
        uint16 acePercent;  // measured in percent points, ie 1/100 of percent
        uint16 servicePercent;  // measured in percent points, ie 1/100 of percent
        uint gasReserve; // in Wei
        uint testUpperLimit; // stake upper limit (for test only), measured in Wei
    }

    event QuoteIsDeployed(
        address indexed quoter,
        uint32 quoteId,
        uint16 roundId,
        uint64 quoteTime,
        uint32 quoteTickets,
        uint64 quoteRate,
        uint quoteStake,
        uint currentRoundRewardPool,
        uint totalRewardPool
    );

    event WinnerQuotesArePosted(
        uint8 winnerQuotesCount
    );

    // PRIVATE VARIABLES
    
    RoundData private _zeroRoundData = RoundData({
        status: Status.NotStarted,
        snapshotTime: 0, // IMMUTABLE, in seconds
        baseTicketPrice: 0, // IMMUTABLE, in Wei
        servicePercent: 0,  // IMMUTABLE, measured in percent points, ie 1/100 of percent
        benchmarkDeviation: 0, // IMMUTABLE, in USD with 2 decimals
        rewardPool: 0, // round reward pool, in Wei
        quotesCount: 0,
        winnerQuotesCount: 0,
        postedWinnerQuotes: 0,
        winnerQuotesAreValidated: false,
        datafeedRoundId: 0,
        snapshotPrice: 0,
        isAce: false
    });
    uint64 private _u1;
    bool private _quotesNotLocked;

    // INTERNAL VARIABLES

    IRounds internal roundsContract;
    IConfig internal configContract;
    
    // PUBLIC VARIABLES

    // contract parameters
    string public currency;
    uint64 public deploymentTime;
    address payable public superAdmin;
    address payable public daemon;
    address payable public serviceFeeRecipient;
    uint public adjustedTicketPrice;
    uint public totalRewardPool; // in Wei
    uint public futureRoundsRewardPool; // in Wei

    uint16 public lastPostedRoundId;
    bool public readyToBeClosed;

    QuoteParams public quoteParams;

    // mappings for rounds and quotes
    mapping(uint16 => RoundData) public quoteRounds; // [roundId]
    mapping(address => AccountQuotes) public quotes; // [address]{[quotesCount],{[quoteId],..}}
    mapping(uint16 => WinnerQuote[3]) public winnerQuotes; // [roundId][winnerId]

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

    modifier closingStatusOnly() {
        if (quoteRounds[roundsContract.currentRoundId()].status != Status.Closing) {
            revert StatusIsNotClosing();
        }
        _;
    }

    modifier closedStatusOnly() {
        if (quoteRounds[roundsContract.currentRoundId()].status != Status.Closed) {
            revert StatusIsNotClosed();
        }
        _;
    }

    modifier quotesNotLocked() {
        if (_quotesNotLocked != true) {
            revert PredictionsAreTemporarilyLocked();
        }
        _quotesNotLocked = false;
        _;
        _quotesNotLocked = true;
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

        setQuoteParams(
            200, // ace percent, measured in percentage points, 1/100 of percent
            2000, // service percent, measured in percentage points, 1/100 of percent
            1_000_000 gwei, // quotes gas reserve
            50_000_000 gwei // max test stake
        );

        {
            totalRewardPool = 0;
            futureRoundsRewardPool = 0;
            _quotesNotLocked = true;
            deploymentTime = uint64(block.timestamp);
        }
        
        {
            // setting initial round
            RoundData memory _newRoundData;
            _newRoundData = _zeroRoundData;
            _newRoundData.status = roundsContract.draftRoundStatus();
            _newRoundData.snapshotTime = roundsContract.draftRoundSnapshotTime(); // in seconds
            _newRoundData.baseTicketPrice = configContract.baseTicketPrice(); // in Wei
            _newRoundData.servicePercent = quoteParams.servicePercent;  // measured in percent points, ie 1/100 of percent
            _newRoundData.benchmarkDeviation = roundsContract.benchmarkDeviation(); // in USD with 2 decimals

            quoteRounds[roundsContract.draftRoundRoundId()] = _newRoundData;
            lastPostedRoundId = roundsContract.draftRoundRoundId();
        }

        _u1 = uint64(_sqrt(configContract.MODEL_HORIZON()));
    }

    receive() external payable {}

    fallback() external payable {} 

    function setQuoteParams(
        uint16 _acePercent,  // measured in percent points, ie 1/100 of percent
        uint16 _servicePercent,  // measured in percent points, ie 1/100 of percent
        uint _gasReserve,
        uint _testUpperLimit
    ) public superAdminOnly() {
        if (_servicePercent > configContract.MAX_SERVICE_PERCENT()) {
            revert ServicePercentExceedsUpperLimit();
        }
        
        QuoteParams memory _quoteParams;
        _quoteParams.acePercent = _acePercent; // measured in percentage points, 1/100 of percent
        _quoteParams.servicePercent = _servicePercent; // measured in percentage points, 1/100 of percent
        _quoteParams.gasReserve = _gasReserve;
        _quoteParams.testUpperLimit = _testUpperLimit;

        quoteParams = _quoteParams;
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
        _newRoundData.servicePercent = quoteParams.servicePercent;  // measured in percent points, ie 1/100 of percent
        _newRoundData.benchmarkDeviation = roundsContract.benchmarkDeviation(); // in USD with 2 decimals

        quoteRounds[roundsContract.draftRoundRoundId()] = _newRoundData;
        lastPostedRoundId = roundsContract.draftRoundRoundId();
    }

    function changeCurrentRoundStatus(Status _status) public roundsOnly() {
        quoteRounds[roundsContract.currentRoundId()].status = _status;
    }

    function switchRound() public roundsOnly() closedStatusOnly() {
        futureRoundsRewardPool -= quoteRounds[roundsContract.currentRoundId()].rewardPool;
        if (address(this).balance > quoteParams.gasReserve) {
            totalRewardPool = address(this).balance - quoteParams.gasReserve;
        } else {
            totalRewardPool = 0;
        }
        
    }

    function newQuote(
        uint64 _quoteRate, // eg 2943248 with 2 decimals
        uint16 _roundId, // eg 1
        uint8 _timeLeftPercent // @dev test mode: to be deleted
    ) external payable quotesNotLocked() {
        adjustedTicketPrice = configContract.baseTicketPrice() * _u1;
        adjustedTicketPrice /= _u2(_timeLeftPercent); //measured in wei

        if ((_roundId > roundsContract.lastActiveRoundId()) || (_roundId < roundsContract.currentRoundId())) {
            revert WrongRoundId();
        }
        if(_roundId == roundsContract.currentRoundId()) {
            if (block.timestamp > quoteRounds[_roundId].snapshotTime - configContract.HALT_TIME_SPAN()) {
                revert HaltTimeDeadlock();
            }
        }
        if (msg.value < adjustedTicketPrice) {
            revert NotEnoughFunds();
        }
        if (configContract.TEST_MODE()) {
            if (msg.value > quoteParams.testUpperLimit) {
                revert StakeExceedsUpperTestLimit();
            }
        }

        uint _tickets = msg.value * 10 ** 2; // tickets are measured in units with 2 decimal digits
        _tickets /= adjustedTicketPrice;

        Quote memory _newQuote;
        _newQuote.roundId = _roundId;
        _newQuote.time = uint64(block.timestamp);
        _newQuote.stake = msg.value; // in Wei
        _newQuote.tickets = uint32(_tickets); // with 2 decimals
        _newQuote.quoteRate = _quoteRate; // measured in USD with 2 decimal digits

        quotes[msg.sender].quotesMap[quotes[msg.sender].quotesCount] = _newQuote;
        quotes[msg.sender].quotesCount++;

        quoteRounds[_roundId].quotesCount++;
        quoteRounds[_newQuote.roundId].rewardPool += msg.value;
        if (address(this).balance + msg.value > quoteParams.gasReserve) {
            totalRewardPool = address(this).balance + msg.value - quoteParams.gasReserve;
        } else {
            totalRewardPool = 0;
        }

        if(_roundId > roundsContract.currentRoundId()) {
            futureRoundsRewardPool += msg.value;
        }

        emit QuoteIsDeployed(
            msg.sender,
            quotes[msg.sender].quotesCount - 1,
            _roundId,
            quotes[msg.sender].quotesMap[quotes[msg.sender].quotesCount - 1].time,
            uint32(_tickets),
            _quoteRate, // measured in USD with 2 decimal digits
            msg.value, // measured in Wei
            totalRewardPool > futureRoundsRewardPool ? totalRewardPool - futureRoundsRewardPool : 0,
            totalRewardPool
        );
    }

    function _u2(uint8 _v) private view returns (uint64) {
        // @dev shall be changed to 
        // uint64(Utils.sqrt(rounds[currentRound].init.snapshotTime - block.timestamp));
        return uint64(_sqrt((configContract.MODEL_HORIZON()) * _v / 100));
    }

    function postSnapshotPriceAndFeedId(uint64 _snapshotPrice, uint80 _datafeedRoundId) external daemonOrSuperAdminOnly() closingStatusOnly() {
        quoteRounds[roundsContract.currentRoundId()].datafeedRoundId = _datafeedRoundId;
        quoteRounds[roundsContract.currentRoundId()].snapshotPrice = _snapshotPrice;
    }

    function postWinnerQuotes(
        uint16 _roundId,
        uint8 _numberOfWinners,
        bytes memory _encodedWinners // @dev see below
        // uint8 _numberOfWinners,
        // uint16 _roundId,
        // address _winner,
        // uint16 _quoteId,
        // uint8 _position,
        // uint16 _normalWeight
    ) external daemonOrSuperAdminOnly() closingStatusOnly() {
        if (_roundId != roundsContract.currentRoundId()) {
            revert WrongRoundId();
        }
        if (quoteRounds[roundsContract.currentRoundId()].snapshotPrice == 0) {
            revert SnapshotTimeIsNotSet();
        }
        if (_numberOfWinners > 3) {
            revert WrongNumberOfWinners();
        }

        // @dev
        /////////////////////////////////////////////////
        bytes memory _testEncodedWinners = abi.encode([
                DecodedWinnerQuote({winner: address(this), quoteId: 14, position: 1, normalWeight: 3463}),
                DecodedWinnerQuote({winner: address(this), quoteId: 6, position: 2, normalWeight: 1256}),
                DecodedWinnerQuote({winner: address(this), quoteId: 4, position: 3, normalWeight: 512})
            ]);
        /////////////////////////////////////////////////

        (DecodedWinnerQuote[] memory _decodedWinnerQuotes) = abi.decode(_testEncodedWinners, (DecodedWinnerQuote[])); // @dev
        if (_numberOfWinners !=  _decodedWinnerQuotes.length) {
            revert WrongLengthOfWinnersData();
        }

        quoteRounds[roundsContract.currentRoundId()].winnerQuotesCount = _numberOfWinners;

        uint8 position = 0;
        uint16 normalWeight = 0;

        for (uint8 i = 0; i < _numberOfWinners; i++) {    
            WinnerQuote memory _newWinnerQuote;
            _newWinnerQuote.winner = _decodedWinnerQuotes[i].winner;
            _newWinnerQuote.quoteId = _decodedWinnerQuotes[i].quoteId;
            _newWinnerQuote.position = _decodedWinnerQuotes[i].position;
            _newWinnerQuote.normalWeight = _decodedWinnerQuotes[i].normalWeight;

            _newWinnerQuote.deviation = uint64(_abs(
                int64(quotes[_newWinnerQuote.winner].quotesMap[_newWinnerQuote.quoteId].quoteRate -
                quoteRounds[roundsContract.currentRoundId()].snapshotPrice)
            ));

            _newWinnerQuote.rewardValue = 0;
            _newWinnerQuote.serviceValue = 0;
            _newWinnerQuote.rewardIsPaid = false;
            _newWinnerQuote.serviceIsPaid = false;

            if (_newWinnerQuote.position < position) {
                revert NonIncreasingPositionsData();
            }
            position = _newWinnerQuote.position;

            if (i > 0) {
                if (_newWinnerQuote.normalWeight > normalWeight) {
                    revert NonDecreasingNormalWeightsData();
                }
            }
            normalWeight = _newWinnerQuote.normalWeight;

            winnerQuotes[roundsContract.currentRoundId()][i] = _newWinnerQuote;
            quoteRounds[roundsContract.currentRoundId()].postedWinnerQuotes++;
        }

        if (winnerQuotes[roundsContract.currentRoundId()][0].deviation <= quoteParams.acePercent * quoteRounds[roundsContract.currentRoundId()].benchmarkDeviation / 10 ** 2) {
            quoteRounds[roundsContract.currentRoundId()].isAce = true;
        }

        if (!((quoteRounds[roundsContract.currentRoundId()].isAce && _numberOfWinners == 1) ||
            (!quoteRounds[roundsContract.currentRoundId()].isAce && _numberOfWinners > 1))) {
                revert WrongNumberOfWinners();
            }

        emit WinnerQuotesArePosted(
            _numberOfWinners
        );
    }

    function quotesClosing() public daemonOrSuperAdminOnly() closingStatusOnly() {
        for (uint8 i = 0; i < quoteRounds[roundsContract.currentRoundId()].winnerQuotesCount; i++) {
            winnerQuotes[roundsContract.currentRoundId()][i].rewardValue = _rewardValue(i);
            winnerQuotes[roundsContract.currentRoundId()][i].serviceValue = _serviceValue(i);

            sendReward(i, payable(winnerQuotes[roundsContract.currentRoundId()][i].winner));
            sendService(i);
        }

        readyToBeClosed = true;
    }

    function _weightsSum() private view returns (uint _sum) {
        _sum = 0;
        for (uint8 i = 0; i < quoteRounds[roundsContract.currentRoundId()].winnerQuotesCount; i++) {
            _sum += winnerQuotes[roundsContract.currentRoundId()][i].normalWeight; // 4 decimals
        }
    }

    function _ticketWeightsSum() private view returns (uint _sum) {
        _sum = 0;
        for (uint8 i = 0; i < quoteRounds[roundsContract.currentRoundId()].winnerQuotesCount; i++) {
            _sum += winnerQuotes[roundsContract.currentRoundId()][i].normalWeight * 
            quotes[winnerQuotes[roundsContract.currentRoundId()][i].winner].quotesMap[winnerQuotes[roundsContract.currentRoundId()][i].quoteId].tickets; // 6 decimals
        }
    }

    function _rewardValue(uint8 _winnerId) private view returns (uint) {
        uint _res;
        uint rewardPool;
        if (totalRewardPool > futureRoundsRewardPool) {
            rewardPool = totalRewardPool - futureRoundsRewardPool;
        } else {
            rewardPool = 0;
        }

        if (quoteRounds[roundsContract.currentRoundId()].isAce) {
            if (_winnerId == 0) {
                _res = rewardPool;
            } else {
                _res = 0;
            }
        } else {
            _res =
                winnerQuotes[roundsContract.currentRoundId()][_winnerId].normalWeight *
                quotes[winnerQuotes[roundsContract.currentRoundId()][_winnerId].winner].quotesMap[winnerQuotes[roundsContract.currentRoundId()][_winnerId].quoteId].tickets *
                _weightsSum() *
                (10 ** 4 - quoteRounds[roundsContract.currentRoundId()].servicePercent) *
                rewardPool;
            _res /= 
                10 ** 8 * 
                _ticketWeightsSum() *
                quoteRounds[roundsContract.currentRoundId()].winnerQuotesCount;
        }
        return _res;
    }

    function _serviceValue(uint _winnerId) private view returns (uint) {
        uint _res = 
            winnerQuotes[roundsContract.currentRoundId()][_winnerId].rewardValue *
            quoteRounds[roundsContract.currentRoundId()].servicePercent /
            (10 ** 4 - quoteRounds[roundsContract.currentRoundId()].servicePercent);
        return _res;
    }

    function sendReward(uint8 _winnerId, address payable _winner) public payable daemonOrSuperAdminOnly() closingStatusOnly() {
        (bool sent, ) = _winner.call{value: winnerQuotes[roundsContract.currentRoundId()][_winnerId].rewardValue}("");
        if (!sent) {
            revert FailedToSendReward();
        }
        if(sent) {
            winnerQuotes[roundsContract.currentRoundId()][_winnerId].rewardIsPaid = true;
        }
    }

    function sendService(uint8 _winnerId) public payable daemonOrSuperAdminOnly() closingStatusOnly() {
        (bool sent, ) = serviceFeeRecipient.call{value: winnerQuotes[roundsContract.currentRoundId()][_winnerId].serviceValue}("");
        if (!sent) {
            revert FailedToSendService();
        }
        if (sent) {
            winnerQuotes[roundsContract.currentRoundId()][_winnerId].serviceIsPaid = true;
        }
    }

    function _abs(int64 x) private pure returns (int64) {
        return x >= 0 ? x : -x;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function _sqrt(uint y) private pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

}
