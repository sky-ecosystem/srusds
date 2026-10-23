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
///      Deviations from ERC-7540: a controller is always msg.sender (no operators), claims are all-or-nothing,
///      a new request first pays out anything claimable to `receiver`, and cancellation is synchronous.
///
///      Both queues implement the generation-based model where all requests in the same generation share
///      proportionally in the conversion capacity allocated to that generation.
contract LCTSQueues is UUPSUpgradeable {

    // --- Structs ---

    struct Position {
        uint256 gen;        // Generation this position belongs to
        uint256 shares;     // Number of internal queue shares held
        uint256 rewardDebt; // rewardPerToken snapshot at entry [ray]
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

    Queue internal depositQueue;     // Underlying = assets, reward = shares
    Queue internal redeemQueue;      // Underlying = shares, reward = assets

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
    event Request(bool indexed isDeposit, address indexed controller, uint256 indexed gen, address receiver, uint256 claimed, uint256 amount, uint256 queueShares);
    event Cancel(bool indexed isDeposit, address indexed controller, uint256 indexed gen, address receiver, uint256 claimed, uint256 amount);
    event Claim(bool indexed isDeposit, address indexed controller, uint256 indexed gen, address receiver, uint256 amount);
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

    // --- View Functions ---

    function _queue(bool isDeposit) internal view returns (Queue storage) {
        return isDeposit ? depositQueue : redeemQueue;
    }

    function totals(bool isDeposit) external view returns (uint256 currentGen, uint256 totalShares, uint256 totalUnderlying) {
        Queue storage queue = _queue(isDeposit);
        return (queue.currentGen, queue.totalShares, queue.totalUnderlying);
    }

    function positions(bool isDeposit, address controller) external view returns (uint256 gen, uint256 shares, uint256 rewardDebt) {
        Position memory pos = _queue(isDeposit).positions[controller];
        return (pos.gen, pos.shares, pos.rewardDebt);
    }

    function rewardPerToken(bool isDeposit, uint256 gen) external view returns (uint256) {
        return _queue(isDeposit).rewardPerToken[gen];
    }

    /// @notice Amount still waiting to be converted: assets for deposits, shares for redeems
    function pending(bool isDeposit, address controller) external view returns (uint256) {
        Queue storage queue = _queue(isDeposit);
        Position memory pos = queue.positions[controller];
        return (pos.shares == 0 || pos.gen < queue.currentGen || queue.totalShares == 0)
                ? 0
                : pos.shares * queue.totalUnderlying / queue.totalShares;
    }

    /// @notice Amount converted and ready to claim: shares for deposits, assets for redeems
    function claimable(bool isDeposit, address controller) external view returns (uint256) {
        Queue storage queue = _queue(isDeposit);
        Position memory pos = queue.positions[controller];
        return (pos.shares == 0)
                ? 0
                : pos.shares * (queue.rewardPerToken[pos.gen] - pos.rewardDebt) / RAY;
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

    /// @dev Convert up to capacity of a queue's underlying into its reward through the share token
    function _convert(bool isDeposit, uint256 capacity) internal returns (uint256 converted) {
        Queue storage queue = _queue(isDeposit);
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

    function _claimRewards(bool isDeposit, Queue storage queue, Position storage pos, address receiver) internal returns (uint256 claimed) {
        uint256 rpt = queue.rewardPerToken[pos.gen];
        claimed = pos.shares * (rpt - pos.rewardDebt) / RAY;
        pos.rewardDebt = rpt;

        if (claimed > 0) {
            // Deposits are claimed in shares, redeems in assets
            (isDeposit ? TokenLike(address(share)) : asset).transfer(receiver, claimed);
            emit Claim(isDeposit, msg.sender, pos.gen, receiver, claimed);
        }
    }

    function _request(bool isDeposit, uint256 amount, address receiver) internal returns (uint256 claimed) {
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        require(amount > 0, "LCTSQueues/zero-amount");
        require(locked == 0, "LCTSQueues/queue-locked");

        Queue storage queue = _queue(isDeposit);
        Position storage pos = queue.positions[msg.sender];

        claimed = _claimRewards(isDeposit, queue, pos, receiver);

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
            pos.gen = queue.currentGen;
            pos.shares = queueShares;
            pos.rewardDebt = queue.rewardPerToken[queue.currentGen];
        } else {
            pos.shares += queueShares;
        }

        emit Request(isDeposit, msg.sender, queue.currentGen, receiver, claimed, amount, queueShares);
    }

    function _cancel(bool isDeposit, address receiver) internal returns (uint256 amount, uint256 claimed) {
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        require(locked == 0, "LCTSQueues/queue-locked");
        Queue storage queue = _queue(isDeposit);
        Position storage pos = queue.positions[msg.sender];
        require(pos.gen == queue.currentGen, "LCTSQueues/not-current-gen");
        require(pos.shares > 0, "LCTSQueues/zero-shares");

        // Claim whatever already converted
        claimed = _claimRewards(isDeposit, queue, pos, receiver);

        // Calculate the still pending amount
        amount = pos.shares * queue.totalUnderlying / queue.totalShares;

        // Update totals
        queue.totalUnderlying -= amount;
        queue.totalShares -= pos.shares;

        // Clear shares
        pos.shares = 0;

        // If last controller cancels, advance generation
        if (queue.totalShares == 0) {
            queue.currentGen++;
            queue.totalUnderlying = 0;
        }

        // Return the pending amount: assets for deposits, shares for redeems
        if (amount > 0) {
            (isDeposit ? asset : TokenLike(address(share))).transfer(receiver, amount);
        }

        emit Cancel(isDeposit, msg.sender, pos.gen, receiver, claimed, amount);
    }

    function _claim(bool isDeposit, address receiver) internal returns (uint256 claimed) {
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        Queue storage queue = _queue(isDeposit);
        Position storage pos = queue.positions[msg.sender];
        require(pos.gen < queue.currentGen || locked == 0, "LCTSQueues/queue-locked");
        require(pos.shares > 0, "LCTSQueues/no-position");

        claimed = _claimRewards(isDeposit, queue, pos, receiver);
    }

    // --- User Functions ---

    /// @notice Request a deposit of `assets`, first paying any claimable shares to `receiver`
    function requestDeposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _request(true, assets, receiver);
    }

    /// @notice Request a redeem of `shares`, first paying any claimable assets to `receiver`
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = _request(false, shares, receiver);
    }

    /// @notice Cancel the pending deposit request, returning its pending assets and any claimable shares to `receiver`
    function cancelDepositRequest(address receiver) external returns (uint256 assets, uint256 shares) {
        (assets, shares) = _cancel(true, receiver);
    }

    /// @notice Cancel the pending redeem request, returning its pending shares and any claimable assets to `receiver`
    function cancelRedeemRequest(address receiver) external returns (uint256 shares, uint256 assets) {
        (shares, assets) = _cancel(false, receiver);
    }

    /// @notice Claim all shares converted from deposit requests
    function claimDeposit(address receiver) external returns (uint256 shares) {
        shares = _claim(true, receiver);
    }

    /// @notice Claim all assets converted from redeem requests
    function claimRedeem(address receiver) external returns (uint256 assets) {
        assets = _claim(false, receiver);
    }
}
