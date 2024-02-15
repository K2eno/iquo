// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

interface IErrors {
    error CallerIsNotSuperAdmin();
    error CallerIsNotGlobalAdmin();
    error CallerIsNotDaemonOrSuperAdmin();
    error CallerIsNotRoundsContract();
    error StatusIsNotActive();
    error StatusIsNotClosing();
    error StatusIsNotClosed();
    error PredictionsAreTemporarilyLocked();
    error ServicePercentExceedsUpperLimit();
    error WrongStartTime();
    error WrongStartAndEndTime();
    error WrongSnapshotTime();
    error WrongRoundId();
    error NoNewActiveRounds();
    error WrongExpirationTime();
    error HaltTimeDeadlock();
    error NotEnoughFunds();
    error StakeExceedsUpperTestLimit();
    error RoundIdDoesNotMatchCurrentRoundId();
    error SignalsNotReadyToBeClosed();
    error QuotesNotReadyToBeClosed();
    error SnapshotTimeIsNotSet();
    error WrongNumberOfWinners();
    error WrongLengthOfWinnersData();
    error NonIncreasingPositionsData();
    error NonDecreasingChallengesData();
    error NonDecreasingNormalWeightsData();
    error FailedToSendReward();
    error FailedToSendService();
}
