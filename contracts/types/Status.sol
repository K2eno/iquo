// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

enum Status {
    NotStarted, // 0 default for a new round
    Active, // 1 predictions processing
    Halt, // 2 predictions are not accepted
    Closing, // 3 posting winners and payments processing
    Closed // 4 permanent, requires all closing procedures to be completed
}
