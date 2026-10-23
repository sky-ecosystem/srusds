// SPDX-License-Identifier: AGPL-3.0-or-later

/// LCTSQueues.sol -- LCTS (Liquidity Constrained Token Standard) deposit/withdraw queues and settlement cycle

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

interface VaultLike is TokenLike {
    function asset() external view returns (address);
    function convertToShares(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function settle(int256) external;
}

/// @title LCTSQueues
/// @notice Deposit and withdraw queues plus the daily lock/plan/settle cycle in front of a single vault
/// @dev Users join, exit and claim here. This contract holds everything owed to them: queued asset,
///      queued (escrowed) vault shares, and converted rewards not yet claimed. The vault only holds
///      the backing of its outstanding shares. On settlement the vault is revalued (settle) and each
///      queue converts up to its planned capacity through the vault's deposit/redeem.
///
///      Both queues implement the generation-based model where all users in the same generation
///      share proportionally in the conversion capacity allocated to that generation. The deposit
///      queue takes the asset and pays out vault shares; the withdraw queue is the reverse.
contract LCTSQueues is UUPSUpgradeable {

    // --- Structs ---

    struct Position {
        uint256 gen;        // Generation this position belongs to
        uint256 shares;     // Number of internal shares held
        uint256 rewardDebt; // rewardPerToken snapshot at entry [ray]
    }

    struct Queue {
        uint256 currentGen;
        uint256 totalShares;
        uint256 totalUnderlying;
        mapping(uint256 gen => uint256) rewardPerToken; // Cumulative reward per internal share [ray]
        mapping(address usr => Position) positions;
    }

    // --- Storage Variables ---

    mapping(address usr => uint256 allowed) public wards;
    uint256 public locked;           // 0 == unlocked, 1 == locked
    uint256 public lockTimeBgn;      // Time in the day when lock window opens  [seconds, e.g. 13 hours   == 13:00 UTC]
    uint256 public lockTimeEnd;      // Time in the day when lock window closes [seconds, e.g. 13.5 hours == 13:30 UTC]
    uint256 public settleTime;       // Time in the day when settlement can be executed [seconds, e.g. 16 hours == 16:00 UTC]
    int256  public profit;           // Underlying adjustment amount
    uint256 public depositCapacity;  // Deposit queue capacity [asset]
    uint256 public withdrawCapacity; // Withdraw queue capacity [vault shares]

    Queue internal depositQueue;     // Underlying = asset,        reward = vault shares
    Queue internal withdrawQueue;    // Underlying = vault shares, reward = asset

    // --- Immutables ---

    VaultLike public immutable vault;
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
    event Plan(int256 profit, uint256 depositCapacity, uint256 withdrawCapacity);
    event Settle(uint256 depositsConverted, uint256 withdrawsConverted);
    event Join(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, uint256 underlying, uint256 shares);
    event Exit(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, address underlyingTo, uint256 underlying);
    event Claim(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards);
    event Convert(bool indexed isDeposit, uint256 indexed gen, uint256 capacity, uint256 converted, uint256 received, bool finalized);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "LCTSQueues/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address vault_) {
        _disableInitializers(); // Avoid initializing in the context of the implementation

        vault = VaultLike(vault_);
        asset = TokenLike(vault.asset());
    }

    // --- Upgradability ---

    function initialize() initializer external {
        __UUPSUpgradeable_init();

        asset.approve(address(vault), type(uint256).max);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override auth {}

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    // --- View Functions ---

    function _queue(bool isDeposit) internal view returns (Queue storage) {
        return isDeposit ? depositQueue : withdrawQueue;
    }

    function totals(bool isDeposit) external view returns (uint256 currentGen, uint256 totalShares, uint256 totalUnderlying) {
        Queue storage queue = _queue(isDeposit);
        return (queue.currentGen, queue.totalShares, queue.totalUnderlying);
    }

    function positions(bool isDeposit, address owner) external view returns (uint256 gen, uint256 shares, uint256 rewardDebt) {
        Position memory pos = _queue(isDeposit).positions[owner];
        return (pos.gen, pos.shares, pos.rewardDebt);
    }

    function rewardPerToken(bool isDeposit, uint256 gen) external view returns (uint256) {
        return _queue(isDeposit).rewardPerToken[gen];
    }

    function pendingRewards(bool isDeposit, address owner) external view returns (uint256) {
        Queue storage queue = _queue(isDeposit);
        Position memory pos = queue.positions[owner];
        return (pos.shares == 0)
                ? 0
                : pos.shares * (queue.rewardPerToken[pos.gen] - pos.rewardDebt) / RAY;
    }

    function underlyingBalance(bool isDeposit, address owner) external view returns (uint256) {
        Queue storage queue = _queue(isDeposit);
        Position memory pos = queue.positions[owner];
        return (pos.shares == 0 || pos.gen < queue.currentGen || queue.totalShares == 0)
                ? 0
                : pos.shares * queue.totalUnderlying / queue.totalShares;
    }

    function isFinalized(bool isDeposit, address owner) external view returns (bool) {
        Queue storage queue = _queue(isDeposit);
        Position memory pos = queue.positions[owner];
        return pos.shares > 0 && pos.gen < queue.currentGen;
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

    /// @notice Lock both queues, preventing joins and exits
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
        uint256 withdrawCapacity_
    ) external auth {
        require(locked == 1, "LCTSQueues/not-locked");
        profit           = profit_;
        depositCapacity  = depositCapacity_;
        withdrawCapacity = withdrawCapacity_;
        emit Plan(profit_, depositCapacity_, withdrawCapacity_);
    }

    // --- Settlement ---

    /// @notice Settle the current cycle
    function settle() external {
        uint256 settleTimestamp = (block.timestamp / 1 days) * 1 days + settleTime;
        require(locked == 1, "LCTSQueues/not-locked");
        require(block.timestamp >= settleTimestamp, "LCTSQueues/settle-too-early");

        // Revalue the outstanding vault shares before converting at the new price
        vault.settle(profit);

        // Convert both queues up to their planned capacity
        uint256 depositsConverted  = _convert(true,  depositCapacity);
        uint256 withdrawsConverted = _convert(false, withdrawCapacity);

        // Reset settlement params
        locked           = 0;
        profit           = 0;
        depositCapacity  = 0;
        withdrawCapacity = 0;

        emit Settle(depositsConverted, withdrawsConverted);
    }

    // --- Internal Queue Logic ---

    function _claimRewards(bool isDeposit, Queue storage queue, address owner, Position storage pos, address rewardsTo) internal returns (uint256 rewardsAmt) {
        uint256 rpt = queue.rewardPerToken[pos.gen];
        rewardsAmt = pos.shares * (rpt - pos.rewardDebt) / RAY;
        pos.rewardDebt = rpt;

        if (rewardsAmt > 0) {
            // Deposits are rewarded in vault shares, withdrawals in asset
            (isDeposit ? TokenLike(address(vault)) : asset).transfer(rewardsTo, rewardsAmt);
            emit Claim(isDeposit, owner, pos.gen, rewardsTo, rewardsAmt);
        }
    }

    /// @dev Convert up to capacity of a queue's underlying into its reward through the vault
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
        uint256 received = converted == 0 ? 0 : isDeposit ? vault.convertToShares(converted) : vault.convertToAssets(converted);
        if (converted == 0 || received == 0 || received * RAY / totalShares == 0) {
            emit Convert(isDeposit, queue.currentGen, capacity, 0, 0, false);
            return 0;
        }

        received = isDeposit
                   ? vault.deposit(converted, address(this))
                   : vault.redeem(converted, address(this), address(this));

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

    // --- User Functions ---

    /// @notice Join a queue with `underlyingAmt` (asset for deposits, vault shares for withdrawals), claiming accrued rewards first
    function claimAndJoin(bool isDeposit, address rewardsTo, uint256 underlyingAmt) external returns (uint256 rewardsAmt) {
        require(rewardsTo != address(0), "LCTSQueues/rewardsTo-zero-address");
        require(underlyingAmt > 0, "LCTSQueues/zero-underlyingAmt");
        require(locked == 0, "LCTSQueues/queue-locked");

        Queue storage queue = _queue(isDeposit);
        Position storage pos = queue.positions[msg.sender];

        rewardsAmt = _claimRewards(isDeposit, queue, msg.sender, pos, rewardsTo);

        // Transfer underlying from the owner: asset for deposits, vault shares for withdrawals
        (isDeposit ? asset : TokenLike(address(vault))).transferFrom(msg.sender, address(this), underlyingAmt);

        // Calculate internal shares to mint
        uint256 shares = queue.totalShares == 0
                         ? underlyingAmt
                         : underlyingAmt * queue.totalShares / queue.totalUnderlying;
        require(shares > 0, "LCTSQueues/zero-shares");

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

        emit Join(isDeposit, msg.sender, queue.currentGen, rewardsTo, rewardsAmt, underlyingAmt, shares);
    }

    /// @notice Leave a queue completely (current generation only), claiming accrued rewards
    function claimAndExit(bool isDeposit, address rewardsTo, address underlyingTo) external returns (uint256 rewardsAmt, uint256 underlyingAmt) {
        require(rewardsTo != address(0), "LCTSQueues/rewardsTo-zero-address");
        require(underlyingTo != address(0), "LCTSQueues/underlying-zero-address");
        require(locked == 0, "LCTSQueues/queue-locked");
        Queue storage queue = _queue(isDeposit);
        Position storage pos = queue.positions[msg.sender];
        require(pos.gen == queue.currentGen, "LCTSQueues/not-current-gen");
        require(pos.shares > 0, "LCTSQueues/zero-shares");

        // Claim pending rewards
        rewardsAmt = _claimRewards(isDeposit, queue, msg.sender, pos, rewardsTo);

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
            (isDeposit ? asset : TokenLike(address(vault))).transfer(underlyingTo, underlyingAmt);
        }

        emit Exit(isDeposit, msg.sender, pos.gen, rewardsTo, rewardsAmt, underlyingTo, underlyingAmt);
    }

    /// @notice Claim accrued rewards
    function claim(bool isDeposit, address rewardsTo) external returns (uint256 rewardsAmt) {
        require(rewardsTo != address(0), "LCTSQueues/rewardsTo-zero-address");
        Queue storage queue = _queue(isDeposit);
        Position storage pos = queue.positions[msg.sender];
        require(pos.gen < queue.currentGen || locked == 0, "LCTSQueues/queue-locked");
        require(pos.shares > 0, "LCTSQueues/no-position");

        rewardsAmt = _claimRewards(isDeposit, queue, msg.sender, pos, rewardsTo);
    }
}
