// SPDX-License-Identifier: AGPL-3.0-or-later

/// LCTSQueues.sol -- LCTS (Liquidity Constrained Token Standard) deposit/redeem queues and settlement cycle

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

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface TokenLike {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

interface ShareLike is TokenLike {
    function asset() external view returns (address);
    function convertToShares(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function settle(int256) external;
}

/// @title LCTSQueues
/// @notice Asynchronous deposit and redeem requests, settled in a daily lock/plan/settle cycle, for a single share token
/// @dev Loosely follows ERC-7540/ERC-7575: this contract is the vault users request, cancel and claim on, and
///      `share` is the separate share token. It holds everything owed to users: pending assets, pending
///      (escrowed) shares, and claimable shares/assets not yet claimed. The share token only holds the backing
///      of its outstanding supply. On settlement the share is revalued (settle) and each queue converts up to
///      its planned capacity through the share's deposit/redeem.
///
///      Deviations from ERC-7540: the request owner is always msg.sender (no separate controller, no operators), claims are in output units only,
///      and cancellation is synchronous.
///
///      Both queues implement the generation-based model where all requests in the same generation share
///      proportionally in the conversion capacity allocated to that generation.
contract LCTSQueues is UUPSUpgradeable {

    // --- Structs ---

    struct Position {
        uint256 gen;        // Generation this position belongs to
        uint256 shares;     // Number of internal queue shares held // TODO: should we rename to units / queueUnits?
        uint256 rewardDebt; // rewardPerToken snapshot at the last checkpoint [ray]
        uint256 claimable;  // Converted and not yet claimed, as of the last checkpoint
    }

    struct Queue {
        uint256 currentGen;
        uint256 totalShares;
        uint256 totalUnderlying;
        mapping(uint256 gen => uint256) rewardPerToken; // Cumulative reward per internal queue share [ray]
        mapping(address usr => Position) positions;
    }

    // --- Storage Variables ---

    mapping(address usr => uint256 allowed) public wards;
    uint256 public locked;           // 0 == unlocked, 1 == locked
    uint256 public lockTimeBgn;      // Time in the day when lock window opens  [seconds, e.g. 13 hours   == 13:00 UTC]
    uint256 public lockTimeEnd;      // Time in the day when lock window closes [seconds, e.g. 13.5 hours == 13:30 UTC]
    uint256 public settleTime;       // Time in the day when settlement can be executed [seconds, e.g. 16 hours == 16:00 UTC]
    int256  public profit;           // Underlying adjustment amount
    uint256 public depositCapacity;  // Deposit queue capacity [assets]
    uint256 public redeemCapacity;   // Redeem queue capacity  [shares]

    Queue public depositQueue;       // Underlying = assets, reward = shares (getter: currentGen, totalShares, totalUnderlying)
    Queue public redeemQueue;        // Underlying = shares, reward = assets (getter: currentGen, totalShares, totalUnderlying)

    // --- Immutables ---

    ShareLike public immutable share;
    TokenLike public immutable asset;

    // --- Constants ---

    uint256 constant RAY = 10 ** 27;
    // Largest totalShares:totalUnderlying a generation may carry. Conversion is the only thing
    // that raises it, so bounding the remainder a conversion may leave bounds the ratio itself.
    uint256 constant MAX_SHARE_RATIO = 10 ** 9;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Lock();
    event Plan(int256 profit, uint256 depositCapacity, uint256 redeemCapacity);
    event Settle(uint256 depositsConverted, uint256 redeemsConverted);
    event Request(bool indexed isDeposit, address indexed owner, uint256 indexed gen, uint256 amount, uint256 queueShares);
    event Cancel(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address receiver, uint256 amount);
    event Claim(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address receiver, uint256 amount);
    event Convert(bool indexed isDeposit, uint256 indexed gen, uint256 capacity, uint256 converted, uint256 received, bool finalized);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "LCTSQueues/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address share_) {
        _disableInitializers(); // Avoid initializing in the context of the implementation

        share = ShareLike(share_);
        asset = TokenLike(share.asset());
    }

    // --- Upgradability ---

    function initialize() initializer external {
        __UUPSUpgradeable_init();

        asset.approve(address(share), type(uint256).max);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override auth {}

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
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
            require(data < 1 days, "LCTSQueues/incorrect-time-in-day");
            require(data < lockTimeEnd, "LCTSQueues/not-less-lock-end");
            lockTimeBgn = data;
        } else if (what == "lockTimeEnd") {
            require(data < 1 days, "LCTSQueues/incorrect-time-in-day");
            require(data > lockTimeBgn, "LCTSQueues/not-greater-lock-bgn");
            require(data < settleTime, "LCTSQueues/not-less-settle");
            lockTimeEnd = data;
        } else if (what == "settleTime") {
            require(data < 1 days, "LCTSQueues/incorrect-time-in-day");
            require(data > lockTimeEnd, "LCTSQueues/not-greater-lock-end");
            settleTime = data;
        } else revert("LCTSQueues/file-unrecognized-param");
        emit File(what, data);
    }

    /// @notice Lock both queues, preventing requests and cancellations
    function lock() external auth {
        require(locked == 0, "LCTSQueues/already-locked");
        uint256 lockTimestampBgn = (block.timestamp / 1 days) * 1 days + lockTimeBgn;
        uint256 lockTimestampEnd = (block.timestamp / 1 days) * 1 days + lockTimeEnd;
        require(block.timestamp >= lockTimestampBgn, "LCTSQueues/lock-too-early");
        require(block.timestamp <= lockTimestampEnd, "LCTSQueues/lock-too-late");

        locked = 1;

        emit Lock();
    }

    /// @notice Set settlement parameters
    function plan(
        int256  profit_,
        uint256 depositCapacity_,
        uint256 redeemCapacity_
    ) external auth {
        require(locked == 1, "LCTSQueues/not-locked");
        profit          = profit_;
        depositCapacity = depositCapacity_;
        redeemCapacity  = redeemCapacity_;
        emit Plan(profit_, depositCapacity_, redeemCapacity_);
    }

    // --- Settlement ---

    /// @dev Convert up to capacity of a queue's underlying into its reward through the share token
    function _convert(bool isDeposit, uint256 capacity) internal returns (uint256 converted) {
        Queue storage queue = isDeposit ? depositQueue : redeemQueue;
        uint256 totalUnderlying = queue.totalUnderlying;
        uint256 totalShares = queue.totalShares;

        converted = capacity < totalUnderlying ? capacity : totalUnderlying;

        // Never leave a remainder small enough to let totalShares/totalUnderlying run away: shares
        // survive a conversion while underlying does not, so a sliver of leftover underlying mints
        // an unbounded share count to the next joiner and truncates every later accrual to zero.
        // Either drain the generation or leave enough behind to stay precise.
        if (converted < totalUnderlying) {
            uint256 minRemainder = totalShares / MAX_SHARE_RATIO;
            if (totalUnderlying - converted < minRemainder) {
                converted = totalUnderlying > minRemainder ? totalUnderlying - minRemainder : 0;
            }
        }

        // Nothing to convert, or nothing creditable: leave the generation untouched. The third
        // term is the one that matters -- underlying must never leave the queue uncredited.
        // totalShares > 0 past the first term, as totalUnderlying > 0 implies a non-empty generation
        uint256 received = converted == 0 ? 0 : isDeposit ? share.convertToShares(converted) : share.convertToAssets(converted);
        if (converted == 0 || received == 0 || received * RAY / totalShares == 0) {
            emit Convert(isDeposit, queue.currentGen, capacity, 0, 0, false);
            return 0;
        }

        received = isDeposit
                   ? share.deposit(converted, address(this))
                   : share.redeem(converted, address(this), address(this));

        // Update reward accumulator
        queue.rewardPerToken[queue.currentGen] += received * RAY / totalShares;

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

    /// @notice Settle the current cycle
    function settle() external {
        uint256 settleTimestamp = (block.timestamp / 1 days) * 1 days + settleTime;
        require(locked == 1, "LCTSQueues/not-locked");
        require(block.timestamp >= settleTimestamp, "LCTSQueues/settle-too-early");

        // Revalue the outstanding shares before converting at the new price
        share.settle(profit);

        // Convert both queues up to their planned capacity
        uint256 depositsConverted = _convert(true,  depositCapacity);
        uint256 redeemsConverted  = _convert(false, redeemCapacity);

        // Reset settlement params
        locked          = 0;
        profit          = 0;
        depositCapacity = 0;
        redeemCapacity  = 0;

        emit Settle(depositsConverted, redeemsConverted);
    }

    // --- Internal Queue Logic ---

    /// @dev Move what has converted since the last checkpoint into the stored claimable balance, without paying it out
    function _checkpoint(Queue storage queue, Position storage pos) internal {
        uint256 rpt = queue.rewardPerToken[pos.gen];
        pos.claimable += pos.shares * (rpt - pos.rewardDebt) / RAY;
        pos.rewardDebt = rpt;
    }

    function _request(bool isDeposit, uint256 amount) internal {
        require(amount > 0, "LCTSQueues/zero-amount");
        require(locked == 0, "LCTSQueues/queue-locked");

        Queue storage queue = isDeposit ? depositQueue : redeemQueue;
        Position storage pos = queue.positions[msg.sender];

        _checkpoint(queue, pos);

        // Escrow the request: assets for deposits, shares for redeems
        (isDeposit ? asset : TokenLike(address(share))).transferFrom(msg.sender, address(this), amount);

        // Calculate internal queue shares to mint
        uint256 queueShares = queue.totalShares == 0
                              ? amount
                              : amount * queue.totalShares / queue.totalUnderlying;
        require(queueShares > 0, "LCTSQueues/zero-shares");

        // Update state
        queue.totalUnderlying += amount;
        queue.totalShares += queueShares;
        if (pos.gen < queue.currentGen) {
            // Start a new position in the current generation; the old one's claimable balance is kept
            pos.gen = queue.currentGen;
            pos.shares = queueShares;
            pos.rewardDebt = queue.rewardPerToken[queue.currentGen];
        } else {
            pos.shares += queueShares;
        }

        emit Request(isDeposit, msg.sender, queue.currentGen, amount, queueShares);
    }

    function _cancel(bool isDeposit, address receiver) internal returns (uint256 amount) {
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        require(locked == 0, "LCTSQueues/queue-locked");
        Queue storage queue = isDeposit ? depositQueue : redeemQueue;
        Position storage pos = queue.positions[msg.sender];
        require(pos.gen == queue.currentGen, "LCTSQueues/not-current-gen");
        require(pos.shares > 0, "LCTSQueues/zero-shares");

        // Keep whatever already converted claimable
        _checkpoint(queue, pos);

        // Calculate the still pending amount
        amount = pos.shares * queue.totalUnderlying / queue.totalShares;

        // Update totals
        queue.totalUnderlying -= amount;
        queue.totalShares -= pos.shares;

        // Clear shares
        pos.shares = 0;

        // If last owner cancels, advance generation
        if (queue.totalShares == 0) {
            queue.currentGen++;
            queue.totalUnderlying = 0;
        }

        // Return the pending amount: assets for deposits, shares for redeems
        if (amount > 0) {
            (isDeposit ? asset : TokenLike(address(share))).transfer(receiver, amount);
        }

        emit Cancel(isDeposit, msg.sender, pos.gen, receiver, amount);
    }

    function _claim(bool isDeposit, uint256 amount, address receiver) internal returns (uint256 claimed) {
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        Queue storage queue = isDeposit ? depositQueue : redeemQueue;
        Position storage pos = queue.positions[msg.sender];

        _checkpoint(queue, pos);
        claimed = amount == type(uint256).max ? pos.claimable : amount;
        require(claimed <= pos.claimable, "LCTSQueues/insufficient-claimable");
        pos.claimable -= claimed;

        if (claimed > 0) {
            // Deposits are claimed in shares, redeems in assets
            (isDeposit ? TokenLike(address(share)) : asset).transfer(receiver, claimed);
            emit Claim(isDeposit, msg.sender, pos.gen, receiver, claimed);
        }
    }

    // --- User Functions ---

    /// @notice Request a deposit of `assets`
    function requestDeposit(uint256 assets) external {
        _request(true, assets);
    }

    /// @notice Request a redeem of `shares`
    function requestRedeem(uint256 shares) external {
        _request(false, shares);
    }

    /// @notice Cancel the pending deposit request, returning its pending assets to `receiver` (anything converted stays claimable)
    function cancelDeposit(address receiver) external returns (uint256 assets) {
        assets = _cancel(true, receiver);
    }

    /// @notice Cancel the pending redeem request, returning its pending shares to `receiver` (anything converted stays claimable)
    function cancelRedeem(address receiver) external returns (uint256 shares) {
        shares = _cancel(false, receiver);
    }

    /// @notice Claim `shares` converted from deposit requests (type(uint256).max claims all)
    function claimDeposit(uint256 shares, address receiver) external returns (uint256 claimed) {
        claimed = _claim(true, shares, receiver);
    }

    /// @notice Claim `assets` converted from redeem requests (type(uint256).max claims all)
    function claimRedeem(uint256 assets, address receiver) external returns (uint256 claimed) {
        claimed = _claim(false, assets, receiver);
    }

    // --- View Functions ---

    // Pending: a position with shares in the current generation is part of totalShares, so it is non-zero there

    /// @notice Assets still waiting to be converted to shares
    function pendingDeposit(address owner) external view returns (uint256) {
        Position memory pos = depositQueue.positions[owner];
        return (pos.shares == 0 || pos.gen < depositQueue.currentGen) ? 0 : pos.shares * depositQueue.totalUnderlying / depositQueue.totalShares;
    }

    /// @notice Shares still waiting to be converted to assets
    function pendingRedeem(address owner) external view returns (uint256) {
        Position memory pos = redeemQueue.positions[owner];
        return (pos.shares == 0 || pos.gen < redeemQueue.currentGen) ? 0 : pos.shares * redeemQueue.totalUnderlying / redeemQueue.totalShares;
    }

    /// @notice Shares converted from deposits and ready to claim
    function claimableDeposit(address owner) external view returns (uint256) {
        Position memory pos = depositQueue.positions[owner];
        return pos.claimable + pos.shares * (depositQueue.rewardPerToken[pos.gen] - pos.rewardDebt) / RAY;
    }

    /// @notice Assets converted from redeems and ready to claim
    function claimableRedeem(address owner) external view returns (uint256) {
        Position memory pos = redeemQueue.positions[owner];
        return pos.claimable + pos.shares * (redeemQueue.rewardPerToken[pos.gen] - pos.rewardDebt) / RAY;
    }
}
