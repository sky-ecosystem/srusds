// SPDX-License-Identifier: AGPL-3.0-or-later

/// LCTSHandlerBase.sol -- Abstract base for LCTS settlement cycle handlers

// Copyright (C) 2025 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

interface LCTSQueueLike {
    function lock() external;
    function settle(uint256 capacity) external returns (uint256);
}

/// @title LCTSHandlerBase
/// @notice Abstract base for LCTS settlement cycle handlers
/// @dev Manages daily settlement cycles with explicit lock/settle timestamps.
///      Subclasses implement product-specific settlement logic via _settle().
abstract contract LCTSHandlerBase {

    // --- Storage Variables ---

    mapping(address usr => uint256 allowed) public wards;
    uint256 public locked;           // 0 == unlocked, 1 == locked
    uint256 public lockTimeBgn;      // Time in the day when lock window opens  [seconds, e.g. 13 hours   == 13:00 UTC]
    uint256 public lockTimeEnd;      // Time in the day when lock window closes [seconds, e.g. 13.5 hours == 13:30 UTC]
    uint256 public settleTime;       // Time in the day when settlement can be executed [seconds, e.g. 16 hours == 16:00 UTC]
    int256  public profit;           // Underlying adjustment amount
    uint256 public depositCapacity;  // Deposit queue capacity
    uint256 public withdrawCapacity; // Withdraw queue capacity

    // --- Immutables ---

    address public immutable depositQueue;
    address public immutable withdrawQueue;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Lock();
    event Plan(int256 profit, uint256 depositCapacity, uint256 withdrawCapacity);
    event Settle(uint256 depositsConverted, uint256 withdrawsConverted);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "LCTSHandlerBase/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address depositQueue_, address withdrawQueue_) {
        depositQueue  = depositQueue_;
        withdrawQueue = withdrawQueue_;

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Auth Functions ---

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "lockTimeBgn") {
            require(data < 1 days, "LCTSHandlerBase/incorrect-time-in-day");
            require(data < lockTimeEnd, "LCTSHandlerBase/not-less-lock-end");
            lockTimeBgn = data;
        } else if (what == "lockTimeEnd") {
            require(data < 1 days, "LCTSHandlerBase/incorrect-time-in-day");
            require(data > lockTimeBgn, "LCTSHandlerBase/not-greater-lock-bgn");
            require(data < settleTime, "LCTSHandlerBase/not-less-settle");
            lockTimeEnd = data;
        } else if (what == "settleTime") {
            require(data < 1 days, "LCTSHandlerBase/incorrect-time-in-day");
            require(data > lockTimeEnd, "LCTSHandlerBase/not-greater-lock-end");
            settleTime = data;
        } else revert("LCTSHandlerBase/file-unrecognized-param");
        emit File(what, data);
    }

    /// @notice Lock both queues
    function lock() external auth {
        require(locked == 0, "LCTSHandlerBase/already-locked");
        uint256 lockTimestampBgn = (block.timestamp / 1 days) * 1 days + lockTimeBgn;
        uint256 lockTimestampEnd = (block.timestamp / 1 days) * 1 days + lockTimeEnd;
        require(block.timestamp >= lockTimestampBgn, "LCTSHandlerBase/lock-too-early");
        require(block.timestamp <= lockTimestampEnd, "LCTSHandlerBase/lock-too-late");

        LCTSQueueLike(depositQueue).lock();
        LCTSQueueLike(withdrawQueue).lock();
        locked = 1;

        emit Lock();
    }

    /// @notice Set settlement parameters
    function plan(
        int256  profit_,
        uint256 depositCapacity_,
        uint256 withdrawCapacity_
    ) external auth {
        require(locked == 1, "LCTSHandlerBase/not-locked");
        profit           = profit_;
        depositCapacity  = depositCapacity_;
        withdrawCapacity = withdrawCapacity_;
        emit Plan(profit_, depositCapacity_, withdrawCapacity_);
    }

    /// @dev Called before queue settlement. Implement product-specific logic.
    function _settle() internal virtual;

    // --- Settlement ---

    /// @notice Settle the current cycle
    function settle() external {
        uint256 settleTimestamp = (block.timestamp / 1 days) * 1 days + settleTime;
        require(locked == 1, "LCTSHandlerBase/not-locked");
        require(block.timestamp >= settleTimestamp, "LCTSHandlerBase/settle-too-early");

        _settle();

        // Process LCTS queues
        uint256 depositsConverted  = LCTSQueueLike(depositQueue).settle(depositCapacity);
        uint256 withdrawsConverted = LCTSQueueLike(withdrawQueue).settle(withdrawCapacity);

        // Reset settlement params
        locked           = 0;
        profit           = 0;
        depositCapacity  = 0;
        withdrawCapacity = 0;

        emit Settle(depositsConverted, withdrawsConverted);
    }
}
