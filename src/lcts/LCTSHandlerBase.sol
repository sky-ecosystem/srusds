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
/// @dev Manages cycle lifecycle (init, lock, settle, advance) and queue orchestration.
///      Subclasses implement product-specific settlement logic via _settle() and _settled().
abstract contract LCTSHandlerBase {

    // --- Types ---

    struct Cycle {
        uint256 end;
        int256  settleAmt;
        uint256 depositCapacity;
        uint256 withdrawCapacity;
    }

    // --- Storage Variables ---

    mapping(address usr => uint256 allowed) public wards;
    mapping(uint256 cId => Cycle cycle)     public cycles;
    uint256 public cCId;    // Current Cycle Id
    uint256 public hop;     // Cycle duration [seconds]
    uint256 public locked;  // 0 or 1, tracks lock-per-cycle

    // --- Immutables ---

    LCTSQueueLike public immutable depositQueue;
    LCTSQueueLike public immutable withdrawQueue;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Init(uint256 end);
    event Update(uint256 indexed cId, uint256 end);
    event Lock(uint256 indexed cId);
    event Plan(uint256 indexed cId, int256 settleAmt, uint256 depositCapacity, uint256 withdrawCapacity);
    event Settle(uint256 indexed cId, uint256 depositsConverted, uint256 withdrawsConverted);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "LCTSHandlerBase/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address depositQueue_, address withdrawQueue_) {
        depositQueue  = LCTSQueueLike(depositQueue_);
        withdrawQueue = LCTSQueueLike(withdrawQueue_);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Abstract Functions ---

    /// @dev Called before queue settlement. Implement product-specific logic (e.g., chi adjustment).
    function _settle(uint256 cId) internal virtual;


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
        if (what == "hop") {
            hop = data;
        } else revert("LCTSHandlerBase/file-unrecognized-param");
        emit File(what, data);
    }

    function init(uint256 end) external auth {
        require(cCId == 0, "LCTSHandlerBase/already-init");
        require(end > block.timestamp, "LCTSHandlerBase/end-too-soon");

        cycles[++cCId].end = end;
        emit Init(end);
    }

    function update(uint256 cId, uint256 end) external auth {
        require(cId == cCId, "LCTSHandlerBase/not-current-cycle");
        require(end >= block.timestamp, "LCTSHandlerBase/end-past");

        cycles[cId].end = end;
        emit Update(cId, end);
    }

    /// @notice Set settlement parameters for the current cycle
    function plan(
        uint256 cId,
        int256  settleAmt,
        uint256 depositCapacity_,
        uint256 withdrawCapacity_
    ) external auth {
        require(cId == cCId, "LCTSHandlerBase/not-current-cycle");
        Cycle storage c = cycles[cId];
        c.settleAmt        = settleAmt;
        c.depositCapacity  = depositCapacity_;
        c.withdrawCapacity = withdrawCapacity_;
        emit Plan(cId, settleAmt, depositCapacity_, withdrawCapacity_);
    }

    /// @notice Lock both queues for the current cycle
    function lock(uint256 cId) external auth {
        require(cId == cCId, "LCTSHandlerBase/not-current-cycle");
        require(locked == 0, "LCTSHandlerBase/already-locked");

        depositQueue.lock();
        withdrawQueue.lock();
        locked = 1;

        emit Lock(cId);
    }

    // --- Settlement ---

    /// @notice Settle the current cycle
    /// @param cId Cycle ID (must be current cycle and past end time)
    function settle(uint256 cId) external {
        require(cId > 0, "LCTSHandlerBase/not-init");
        require(cId == cCId, "LCTSHandlerBase/not-current-cycle");
        require(locked == 1, "LCTSHandlerBase/not-locked");
        Cycle storage c = cycles[cId];
        require(block.timestamp >= c.end, "LCTSHandlerBase/current-cycle-not-finished");

        // Product-specific settlement (e.g., chi adjustment)
        _settle(cId);

        // Process LCTS queues
        uint256 depositsConverted  = depositQueue.settle(c.depositCapacity);
        uint256 withdrawsConverted = withdrawQueue.settle(c.withdrawCapacity);

        // Advance cycle
        locked = 0;
        cycles[++cCId].end = c.end + hop;

        emit Settle(cId, depositsConverted, withdrawsConverted);
    }

    // --- View Functions ---

    /// @notice Get the end timestamp of the current cycle
    function tau() external view returns (uint256) {
        return cycles[cCId].end;
    }

    /// @notice Get cycle details
    function getCycle(uint256 cId) external view returns (
        uint256 end,
        int256  settleAmt,
        uint256 depositCapacity,
        uint256 withdrawCapacity
    ) {
        Cycle storage c = cycles[cId];
        return (c.end, c.settleAmt, c.depositCapacity, c.withdrawCapacity);
    }
}
