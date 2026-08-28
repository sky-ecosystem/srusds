// SPDX-License-Identifier: AGPL-3.0-or-later

/// VentureHandler.sol -- Venture settlement cycle handler and queues

// Copyright (C) 2017, 2018, 2019 dbrock, rain, mrchico
// Copyright (C) 2021 Dai Foundation
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

interface TokenLike {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

interface VentureLike is TokenLike {
    function chi() external view returns (uint192);
    function settle(int256) external returns (uint256);
    function mint(uint256, address) external;
    function burn(uint256, address) external;
}

interface GemLike is TokenLike {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

/// @title VentureHandler
/// @notice Settlement cycle handler and deposit/withdraw queues for the Venture token
/// @dev Manages daily settlement cycles with explicit lock/settle timestamps. On settlement the
///      Venture chi is adjusted by profit and both queues convert up to their planned capacity.
///
///      Both queues implement the generation-based model where all users in the same generation
///      share proportionally in the conversion capacity allocated to that generation. The deposit
///      queue takes gem and pays out Venture; the withdraw queue takes Venture and pays out gem.
///
///      Conversion is where gem crosses the boundary: converting deposits mints Venture and pushes the
///      backing to the buffer, converting withdrawals pulls the backing back and burns Venture. So the
///      gem held here is only ever queued deposits plus unclaimed withdraw queue rewards, and every
///      unit of it is owed to a user. Nothing here is investable, hence there is no way to take it out.
///
///      settle() is permissionless, so a buffer short of liquidity yields a smaller withdraw
///      conversion rather than a revert: the generation stays open and the remainder rolls into the
///      next cycle. What can be pulled is the buffer's gem balance capped by the allowance it grants
///      this contract, both of which are facts rather than self-reported numbers. The deposit side has
///      no such clamp: the buffer always accepts, so depositCapacity is the only limit.
contract VentureHandler {

    // --- Structs ---

    struct Position {
        uint256 gen;        // Generation this position belongs to
        uint256 shares;     // Number of internal shares held
        uint256 rewardDebt; // rewardPerToken snapshot at entry [wad]
    }

    struct Queue {
        uint256 currentGen;
        uint256 totalShares;
        uint256 totalUnderlying;
        mapping(uint256 gen => uint256) rewardPerToken; // Cumulative reward per internal share [wad]
        mapping(address usr => Position) positions;
    }

    // --- Storage Variables ---

    mapping(address usr => uint256 allowed) public wards;
    uint256 public locked;           // 0 == unlocked, 1 == locked
    uint256 public lockTimeBgn;      // Time in the day when lock window opens  [seconds, e.g. 13 hours   == 13:00 UTC]
    uint256 public lockTimeEnd;      // Time in the day when lock window closes [seconds, e.g. 13.5 hours == 13:30 UTC]
    uint256 public settleTime;       // Time in the day when settlement can be executed [seconds, e.g. 16 hours == 16:00 UTC]
    int256  public profit;           // Underlying adjustment amount
    uint256 public depositCapacity;  // Deposit queue capacity
    uint256 public withdrawCapacity; // Withdraw queue capacity

    Queue internal depositQueue;     // Underlying = gem,   reward = Venture
    Queue internal withdrawQueue;    // Underlying = Venture, reward = gem

    address public buffer;           // Where converted backing is held before being invested

    // --- Immutables ---

    GemLike     public immutable gem;
    VentureLike public immutable venture;

    // --- Constants ---

    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);
    event Lock();
    event Plan(int256 profit, uint256 depositCapacity, uint256 withdrawCapacity);
    event Settle(uint256 depositsConverted, uint256 withdrawsConverted);
    event Join(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, uint256 underlying, uint256 shares);
    event Exit(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, address underlyingTo, uint256 underlying);
    event Claim(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards);
    event Convert(bool indexed isDeposit, uint256 indexed gen, uint256 capacity, uint256 converted, uint256 received, bool finalized);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "VentureHandler/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address gem_, address venture_) {
        gem     = GemLike(gem_);
        venture = VentureLike(venture_);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- View Functions ---

    function deposits() external view returns (uint256 currentGen, uint256 totalShares, uint256 totalUnderlying) {
        return (depositQueue.currentGen, depositQueue.totalShares, depositQueue.totalUnderlying);
    }

    function withdrawals() external view returns (uint256 currentGen, uint256 totalShares, uint256 totalUnderlying) {
        return (withdrawQueue.currentGen, withdrawQueue.totalShares, withdrawQueue.totalUnderlying);
    }

    function depositPositions(address owner) external view returns (uint256 gen, uint256 shares, uint256 rewardDebt) {
        Position memory pos = depositQueue.positions[owner];
        return (pos.gen, pos.shares, pos.rewardDebt);
    }

    function withdrawPositions(address owner) external view returns (uint256 gen, uint256 shares, uint256 rewardDebt) {
        Position memory pos = withdrawQueue.positions[owner];
        return (pos.gen, pos.shares, pos.rewardDebt);
    }

    function depositRewardPerToken(uint256 gen) external view returns (uint256) {
        return depositQueue.rewardPerToken[gen];
    }

    function withdrawRewardPerToken(uint256 gen) external view returns (uint256) {
        return withdrawQueue.rewardPerToken[gen];
    }

    function _pendingRewards(Queue storage queue, address owner) internal view returns (uint256) {
        Position memory pos = queue.positions[owner];
        return (pos.shares == 0)
                ? 0
                : pos.shares * (queue.rewardPerToken[pos.gen] - pos.rewardDebt) / WAD;
    }

    function pendingDepositRewards(address owner) external view returns (uint256) {
        return _pendingRewards(depositQueue, owner);
    }

    function pendingWithdrawRewards(address owner) external view returns (uint256) {
        return _pendingRewards(withdrawQueue, owner);
    }

    function _underlyingBalance(Queue storage queue, address owner) internal view returns (uint256) {
        Position memory pos = queue.positions[owner];
        return (pos.shares == 0 || pos.gen < queue.currentGen || queue.totalShares == 0)
                ? 0
                : pos.shares * queue.totalUnderlying / queue.totalShares;
    }

    function depositBalance(address owner) external view returns (uint256) {
        return _underlyingBalance(depositQueue, owner);
    }

    function withdrawBalance(address owner) external view returns (uint256) {
        return _underlyingBalance(withdrawQueue, owner);
    }

    function _finalized(Queue storage queue, address owner) internal view returns (bool) {
        Position memory pos = queue.positions[owner];
        return pos.shares > 0 && pos.gen < queue.currentGen;
    }

    function depositFinalized(address owner) external view returns (bool) {
        return _finalized(depositQueue, owner);
    }

    function withdrawFinalized(address owner) external view returns (bool) {
        return _finalized(withdrawQueue, owner);
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
            require(data < 1 days, "VentureHandler/incorrect-time-in-day");
            require(data < lockTimeEnd, "VentureHandler/not-less-lock-end");
            lockTimeBgn = data;
        } else if (what == "lockTimeEnd") {
            require(data < 1 days, "VentureHandler/incorrect-time-in-day");
            require(data > lockTimeBgn, "VentureHandler/not-greater-lock-bgn");
            require(data < settleTime, "VentureHandler/not-less-settle");
            lockTimeEnd = data;
        } else if (what == "settleTime") {
            require(data < 1 days, "VentureHandler/incorrect-time-in-day");
            require(data > lockTimeEnd, "VentureHandler/not-greater-lock-end");
            settleTime = data;
        } else revert("VentureHandler/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 what, address data) external auth {
        if (what == "buffer") {
            // Never unset: conversions move gem to and from it, and settle() must not be wedgeable
            require(data != address(0), "VentureHandler/buffer-zero-address");

            buffer = data;
        } else revert("VentureHandler/file-unrecognized-param");
        emit File(what, data);
    }

    /// @notice Lock both queues, preventing joins and exits
    function lock() external auth {
        require(locked == 0, "VentureHandler/already-locked");
        uint256 lockTimestampBgn = (block.timestamp / 1 days) * 1 days + lockTimeBgn;
        uint256 lockTimestampEnd = (block.timestamp / 1 days) * 1 days + lockTimeEnd;
        require(block.timestamp >= lockTimestampBgn, "VentureHandler/lock-too-early");
        require(block.timestamp <= lockTimestampEnd, "VentureHandler/lock-too-late");

        locked = 1;

        emit Lock();
    }

    /// @notice Set settlement parameters
    function plan(
        int256  profit_,
        uint256 depositCapacity_,
        uint256 withdrawCapacity_
    ) external auth {
        require(locked == 1, "VentureHandler/not-locked");
        profit           = profit_;
        depositCapacity  = depositCapacity_;
        withdrawCapacity = withdrawCapacity_;
        emit Plan(profit_, depositCapacity_, withdrawCapacity_);
    }

    // --- Settlement ---

    /// @notice Settle the current cycle
    function settle() external {
        uint256 settleTimestamp = (block.timestamp / 1 days) * 1 days + settleTime;
        require(locked == 1, "VentureHandler/not-locked");
        require(block.timestamp >= settleTimestamp, "VentureHandler/settle-too-early");

        // Revalue the outstanding shares; the backing being revalued sits at the buffer
        venture.settle(profit);

        // Convert both queues up to their planned capacity
        uint256 depositsConverted  = _convert(true);
        uint256 withdrawsConverted = _convert(false);

        // Reset settlement params
        locked           = 0;
        profit           = 0;
        depositCapacity  = 0;
        withdrawCapacity = 0;

        emit Settle(depositsConverted, withdrawsConverted);
    }

    // --- Internal Queue Logic ---

    /// @dev Token users hand over when joining a queue
    function _underlying(bool isDeposit) internal view returns (TokenLike) {
        return isDeposit ? gem : TokenLike(address(venture));
    }

    /// @dev Token a queue pays out once its underlying has been converted
    function _reward(bool isDeposit) internal view returns (TokenLike) {
        return isDeposit ? TokenLike(address(venture)) : gem;
    }

    function _claimRewards(bool isDeposit, Queue storage queue, address owner, Position storage pos, address rewardsTo) internal returns (uint256 rewardsAmt) {
        uint256 rpt = queue.rewardPerToken[pos.gen];
        rewardsAmt = pos.shares * (rpt - pos.rewardDebt) / WAD;
        pos.rewardDebt = rpt;

        if (rewardsAmt > 0) {
            _reward(isDeposit).transfer(rewardsTo, rewardsAmt);
            emit Claim(isDeposit, owner, pos.gen, rewardsTo, rewardsAmt);
        }
    }

    function _join(bool isDeposit, address owner, address rewardsTo, uint256 underlyingAmt) internal returns (uint256 rewardsAmt) {
        require(rewardsTo != address(0), "VentureHandler/rewards-zero-address");
        require(underlyingAmt > 0, "VentureHandler/zero-underlyingAmt");
        require(locked == 0, "VentureHandler/queue-locked");

        Queue storage queue = isDeposit ? depositQueue : withdrawQueue;
        Position storage pos = queue.positions[owner];

        rewardsAmt = _claimRewards(isDeposit, queue, owner, pos, rewardsTo);

        // Transfer underlying from the owner
        _underlying(isDeposit).transferFrom(owner, address(this), underlyingAmt);

        // Calculate internal shares to mint
        uint256 shares = queue.totalShares == 0
                         ? underlyingAmt
                         : underlyingAmt * queue.totalShares / queue.totalUnderlying;
        require(shares > 0, "VentureHandler/zero-shares");

        // Update state
        queue.totalUnderlying += underlyingAmt;
        queue.totalShares += shares;
        if (pos.gen < queue.currentGen) {
            pos.gen = queue.currentGen;
            pos.shares = shares;
            pos.rewardDebt = queue.rewardPerToken[queue.currentGen];
        } else {
            pos.shares += shares;
        }

        emit Join(isDeposit, owner, queue.currentGen, rewardsTo, rewardsAmt, underlyingAmt, shares);
    }

    function _exit(bool isDeposit, address owner, address rewardsTo, address underlyingTo) internal returns (uint256 rewardsAmt, uint256 underlyingAmt) {
        require(rewardsTo != address(0), "VentureHandler/rewards-zero-address");
        require(underlyingTo != address(0), "VentureHandler/underlying-zero-address");
        require(locked == 0, "VentureHandler/queue-locked");
        Queue storage queue = isDeposit ? depositQueue : withdrawQueue;
        Position storage pos = queue.positions[owner];
        require(pos.gen == queue.currentGen, "VentureHandler/not-current-gen");
        require(pos.shares > 0, "VentureHandler/zero-shares");

        // Claim pending rewards
        rewardsAmt = _claimRewards(isDeposit, queue, owner, pos, rewardsTo);

        // Calculate proportional underlying
        underlyingAmt = pos.shares * queue.totalUnderlying / queue.totalShares;

        // Update totals
        queue.totalUnderlying -= underlyingAmt;
        queue.totalShares -= pos.shares;

        // Clear shares
        pos.shares = 0;

        // If last owner exits, advance generation
        if (queue.totalShares == 0) {
            queue.currentGen++;
            queue.totalUnderlying = 0;
        }

        // Transfer assets
        if (underlyingAmt > 0) {
            _underlying(isDeposit).transfer(underlyingTo, underlyingAmt);
        }

        emit Exit(isDeposit, owner, queue.currentGen, rewardsTo, rewardsAmt, underlyingTo, underlyingAmt);
    }

    function _claim(bool isDeposit, address owner, address rewardsTo) internal returns (uint256 rewardsAmt) {
        require(rewardsTo != address(0), "VentureHandler/rewardsTo-zero-address");
        Queue storage queue = isDeposit ? depositQueue : withdrawQueue;
        Position storage pos = queue.positions[owner];
        require(pos.gen < queue.currentGen || locked == 0, "VentureHandler/queue-locked");
        require(pos.shares > 0, "VentureHandler/no-position");

        rewardsAmt = _claimRewards(isDeposit, queue, owner, pos, rewardsTo);
    }

    /// @dev Convert up to capacity of a queue's underlying into its reward token. Withdrawals are
    ///      clamped by what the buffer can pay, so a liquidity shortfall converts less than planned
    function _convert(bool isDeposit) internal returns (uint256 converted) {
        Queue storage queue;
        uint256 capacity;
        uint256 totalUnderlying;
        uint256 chi = venture.chi();
        uint256 received;

        if (isDeposit) {
            queue = depositQueue;
            capacity = depositCapacity;
            totalUnderlying = queue.totalUnderlying;
            converted = capacity < totalUnderlying ? capacity : totalUnderlying;
            received = converted * RAY / chi;
        } else {
            queue = withdrawQueue;
            capacity = withdrawCapacity;
            totalUnderlying = queue.totalUnderlying;
            converted = capacity < totalUnderlying ? capacity : totalUnderlying;
            // Clamp to the backing the buffer holds and has made available to this contract
            uint256 balance = gem.balanceOf(buffer);
            uint256 allowed = gem.allowance(buffer, address(this));
            uint256 cash = balance < allowed ? balance : allowed;
            received = converted * chi / RAY;
            if (received > cash) {
                converted = cash * RAY / chi;
                received  = converted * chi / RAY; // Re-derive so the shares burned are paid exactly
            }
        }

        // Nothing to convert: leave the generation untouched
        if (converted == 0 || received == 0) {
            emit Convert(isDeposit, queue.currentGen, capacity, 0, 0, false);
            return 0;
        }

        // Execute conversion, moving the backing to or from the buffer
        if (isDeposit) {
            venture.mint(received, address(this));
            gem.transfer(buffer, converted);
        } else {
            gem.transferFrom(buffer, address(this), received);
            venture.burn(converted, address(this));
        }

        // Update reward accumulator
        queue.rewardPerToken[queue.currentGen] += received * WAD / queue.totalShares;

        // Reduce underlying
        totalUnderlying -= converted;
        queue.totalUnderlying = totalUnderlying;

        bool finalized = totalUnderlying == 0;

        // If generation fully drained, finalize and advance
        if (finalized) {
            queue.currentGen++;
            queue.totalShares = 0;
        }

        emit Convert(isDeposit, finalized ? queue.currentGen - 1 : queue.currentGen, capacity, converted, received, finalized);
    }

    // --- Deposit Queue User Functions ---

    function claimVentureAndJoinGem(address rewardsTo, uint256 gemAmt) external returns (uint256 ventureAmt) {
        ventureAmt = _join(true, msg.sender, rewardsTo, gemAmt);
    }

    function claimVentureAndExitGem(address rewardsTo, address underlyingTo) external returns (uint256 ventureAmt, uint256 gemAmt) {
        (ventureAmt, gemAmt) = _exit(true, msg.sender, rewardsTo, underlyingTo);
    }

    function claimVenture(address rewardsTo) external returns (uint256 ventureAmt) {
        ventureAmt = _claim(true, msg.sender, rewardsTo);
    }

    // --- Withdraw Queue User Functions ---

    function claimGemAndJoinVenture(address rewardsTo, uint256 ventureAmt) external returns (uint256 gemAmt) {
        gemAmt = _join(false, msg.sender, rewardsTo, ventureAmt);
    }

    function claimGemAndExitVenture(address rewardsTo, address underlyingTo) external returns (uint256 gemAmt, uint256 ventureAmt) {
        (gemAmt, ventureAmt) = _exit(false, msg.sender, rewardsTo, underlyingTo);
    }

    function claimGem(address rewardsTo) external returns (uint256 gemAmt) {
        gemAmt = _claim(false, msg.sender, rewardsTo);
    }
}
