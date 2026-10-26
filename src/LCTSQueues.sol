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
    event Settle(uint256 depositsConverted, uint256 depositsReceived, uint256 redeemsConverted, uint256 redeemsReceived);
    event DepositRequest(address indexed owner, uint256 indexed gen, uint256 assets, uint256 queueShares);
    event RedeemRequest(address indexed owner, uint256 indexed gen, uint256 shares, uint256 queueShares);
    event CancelDeposit(address indexed owner, uint256 indexed gen, address receiver, uint256 assets);
    event CancelRedeem(address indexed owner, uint256 indexed gen, address receiver, uint256 shares);
    event ClaimDeposit(address indexed owner, address receiver, uint256 shares);
    event ClaimRedeem(address indexed owner, address receiver, uint256 assets);

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

    /// @dev Convert up to capacity of a queue's underlying into its reward through the share token:
    ///      asset into shares for the deposit queue, shares into asset for the redeem queue
    function _convert(Queue storage queue, TokenLike underlying, uint256 capacity) internal returns (uint256 converted, uint256 received) {
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

        if (converted == 0) return (0, 0);

        // Nothing creditable: leave the generation untouched, as underlying must never leave the
        // queue uncredited. totalShares > 0 here, as totalUnderlying > 0 implies a non-empty generation
        received = underlying == asset ? share.convertToShares(converted) : share.convertToAssets(converted);
        if (received * RAY / totalShares == 0) return (0, 0);

        received = underlying == asset
                   ? share.deposit(converted, address(this))
                   : share.redeem(converted, address(this), address(this));

        // Update reward accumulator
        queue.rewardPerToken[queue.currentGen] += received * RAY / totalShares;

        // Reduce underlying
        totalUnderlying -= converted;
        queue.totalUnderlying = totalUnderlying;

        // If generation fully drained, finalize and advance
        if (totalUnderlying == 0) {
            queue.currentGen++;
            queue.totalShares = 0;
        }
    }

    /// @notice Settle the current cycle
    function settle() external {
        uint256 settleTimestamp = (block.timestamp / 1 days) * 1 days + settleTime;
        require(locked == 1, "LCTSQueues/not-locked");
        require(block.timestamp >= settleTimestamp, "LCTSQueues/settle-too-early");

        // Revalue the outstanding shares before converting at the new price
        share.settle(profit);

        // Convert both queues up to their planned capacity
        (uint256 depositsConverted, uint256 depositsReceived) = _convert(depositQueue, asset, depositCapacity);
        (uint256 redeemsConverted,  uint256 redeemsReceived)  = _convert(redeemQueue, share, redeemCapacity);

        // Reset settlement params
        locked          = 0;
        profit          = 0;
        depositCapacity = 0;
        redeemCapacity  = 0;

        emit Settle(depositsConverted, depositsReceived, redeemsConverted, redeemsReceived);
    }

    // --- Internal Queue Logic ---

    /// @dev Move what has converted since the last checkpoint into the stored claimable balance, without paying it out
    function _checkpoint(Queue storage queue, Position storage pos) internal {
        uint256 rpt = queue.rewardPerToken[pos.gen];
        pos.claimable += pos.shares * (rpt - pos.rewardDebt) / RAY;
        pos.rewardDebt = rpt;
    }

    function _request(Queue storage queue, TokenLike token, uint256 amount) internal returns (uint256 gen, uint256 queueShares) {
        require(amount > 0, "LCTSQueues/zero-amount");
        require(locked == 0, "LCTSQueues/queue-locked");

        Position storage pos = queue.positions[msg.sender];

        _checkpoint(queue, pos);

        // Escrow the request
        token.transferFrom(msg.sender, address(this), amount);

        // Calculate internal queue shares to mint
        queueShares = queue.totalShares == 0
                      ? amount
                      : amount * queue.totalShares / queue.totalUnderlying;
        require(queueShares > 0, "LCTSQueues/zero-shares");

        // Update state
        gen = queue.currentGen;
        queue.totalUnderlying += amount;
        queue.totalShares += queueShares;
        if (pos.gen < gen) {
            // Start a new position in the current generation; the old one's claimable balance is kept
            pos.gen = gen;
            pos.shares = queueShares;
            pos.rewardDebt = queue.rewardPerToken[gen];
        } else {
            pos.shares += queueShares;
        }
    }

    function _cancel(Queue storage queue, TokenLike token, address receiver) internal returns (uint256 gen, uint256 amount) {
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        require(locked == 0, "LCTSQueues/queue-locked");
        Position storage pos = queue.positions[msg.sender];
        gen = queue.currentGen;
        require(pos.gen == gen, "LCTSQueues/not-current-gen");
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

        // Return the pending amount
        token.transfer(receiver, amount);
    }

    function _claim(Queue storage queue, TokenLike token, uint256 amount, address receiver) internal returns (uint256 claimed) {
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        Position storage pos = queue.positions[msg.sender];

        _checkpoint(queue, pos);
        claimed = amount == type(uint256).max ? pos.claimable : amount;
        require(claimed <= pos.claimable, "LCTSQueues/insufficient-claimable");
        pos.claimable -= claimed;

        token.transfer(receiver, claimed);
    }

    // --- User Functions ---

    /// @notice Request a deposit of `assets`
    function requestDeposit(uint256 assets) external {
        (uint256 gen, uint256 queueShares) = _request(depositQueue, asset, assets);
        emit DepositRequest(msg.sender, gen, assets, queueShares);
    }

    /// @notice Request a redeem of `shares`
    function requestRedeem(uint256 shares) external {
        (uint256 gen, uint256 queueShares) = _request(redeemQueue, share, shares);
        emit RedeemRequest(msg.sender, gen, shares, queueShares);
    }

    /// @notice Cancel the pending deposit request, returning its pending assets to `receiver` (anything converted stays claimable)
    function cancelDeposit(address receiver) external returns (uint256 assets) {
        uint256 gen;
        (gen, assets) = _cancel(depositQueue, asset, receiver);
        emit CancelDeposit(msg.sender, gen, receiver, assets);
    }

    /// @notice Cancel the pending redeem request, returning its pending shares to `receiver` (anything converted stays claimable)
    function cancelRedeem(address receiver) external returns (uint256 shares) {
        uint256 gen;
        (gen, shares) = _cancel(redeemQueue, share, receiver);
        emit CancelRedeem(msg.sender, gen, receiver, shares);
    }

    /// @notice Claim `shares` converted from deposit requests (type(uint256).max claims all)
    function claimDeposit(uint256 shares, address receiver) external returns (uint256 claimed) {
        claimed = _claim(depositQueue, share, shares, receiver);
        emit ClaimDeposit(msg.sender, receiver, claimed);
    }

    /// @notice Claim `assets` converted from redeem requests (type(uint256).max claims all)
    function claimRedeem(uint256 assets, address receiver) external returns (uint256 claimed) {
        claimed = _claim(redeemQueue, asset, assets, receiver);
        emit ClaimRedeem(msg.sender, receiver, claimed);
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
