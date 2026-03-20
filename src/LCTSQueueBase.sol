// SPDX-License-Identifier: AGPL-3.0-or-later

/// LCTSQueueBase.sol -- Abstract base for LCTS (Liquidity Constrained Token Standard) queues

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

/// @title LCTSQueueBase
/// @notice Abstract base for LCTS queues (subscribe and redeem)
/// @dev Users interact directly with deposit/claim/claimAndExit.
///      Admin-only: lock(), settle(), rely(), deny().
///      Implements the generation-based model where all users in the same generation
///      share proportionally in the conversion capacity allocated to that generation.
abstract contract LCTSQueueBase {

    // --- Storage Variables ---

    mapping(address => uint256) public wards;

    uint256 public locked;

    uint256 public currentGen;
    uint256 public totalShares;
    uint256 public totalUnderlying;
    mapping(uint256 gen => uint256) public rewardPerToken; // Cumulative reward per internal share [wad]
    mapping(address => Position) public positions;

    struct Position {
        uint256 gen;        // Generation this position belongs to
        uint256 shares;     // Number of internal shares held
        uint256 rewardDebt; // rewardPerToken snapshot at entry [wad]
    }

    // --- Constants ---

    uint256 constant WAD = 10 ** 18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Lock(uint256 indexed gen);
    event Claim(address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards);
    event Deposit(address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, uint256 underlying, uint256 shares);
    event Exit(address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, address underlyingTo, uint256 underlying);
    event Settle(uint256 indexed gen, uint256 capacity, uint256 converted, uint256 received, bool finalized);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "LCTSQueueBase/not-authorized");
        _;
    }

    // --- Abstract Functions ---

    function _pullUnderlying(address from, uint256 amount) internal virtual;
    function _pushUnderlying(address to, uint256 amount) internal virtual;
    function _pushReward(address to, uint256 amount) internal virtual;
    function _convert(uint256 amount) internal virtual returns (uint256 received);

    // --- Auth Functions ---

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    /// @notice Lock the queue, preventing new deposits and exits
    function lock() external auth {
        require(locked == 0, "LCTSQueueBase/already-locked");
        locked = 1;
        emit Lock(currentGen);
    }

    function _claimRewards(address owner, Position storage pos, address rewardsTo) internal returns (uint256 rewardsAmt) {
        uint256 rpt = rewardPerToken[pos.gen];
        rewardsAmt = pos.shares * (rpt - pos.rewardDebt) / WAD;
        pos.rewardDebt = rpt;

        if (rewardsAmt > 0) {
            _pushReward(rewardsTo, rewardsAmt);
            emit Claim(owner, pos.gen, rewardsTo, rewardsAmt);
        }
    }

    /// @notice Claim accrued rewards and join (deposit) underlying assets into the queue
    /// @param owner Address to credit the deposit
    /// @param underlyingAmt Amount of underlying to deposit (pulled from msg.sender)
    /// @param rewardsTo Address to receive rewards
    /// @return rewardsAmt Amount of rewards claimed
    function claimAndJoin(address owner, address rewardsTo, uint256 underlyingAmt) external auth returns (uint256 rewardsAmt) {
        require(owner != address(0), "LCTSQueueBase/owner-zero-address");
        require(rewardsTo != address(0), "LCTSQueueBase/rewards-zero-address");
        require(underlyingAmt > 0, "LCTSQueueBase/zero-underlyingAmt");
        require(locked == 0, "LCTSQueueBase/queue-locked");

        Position storage pos = positions[owner];

        rewardsAmt = _claimRewards(owner, pos, rewardsTo);

        // Transfer underlying from caller
        _pullUnderlying(msg.sender, underlyingAmt);

        // Calculate internal shares to mint
        uint256 shares = totalShares == 0
                         ? underlyingAmt
                         : underlyingAmt * totalShares / totalUnderlying;
        require(shares > 0, "LCTSQueueBase/zero-shares");

        // Update state
        totalUnderlying += underlyingAmt;
        totalShares += shares;
        if (pos.gen < currentGen) {
            pos.gen = currentGen;
            pos.shares = shares;
            pos.rewardDebt = rewardPerToken[currentGen];
        } else {
            pos.shares += shares;
        }

        emit Deposit(owner, currentGen, rewardsTo, rewardsAmt, underlyingAmt, shares);
    }

    /// @notice Claim accrued rewards and exit the queue completely (current generation only)
    /// @param owner Address whose position to exit
    /// @param rewardsTo Address to receive rewards
    /// @param underlyingTo Address to receive underlying
    /// @return rewardsAmt Amount of rewards claimed
    /// @return underlyingAmt Amount of underlying returned
    function claimAndExit(address owner, address rewardsTo, address underlyingTo) external auth returns (uint256 rewardsAmt, uint256 underlyingAmt) {
        require(owner != address(0), "LCTSQueueBase/owner-zero-address");
        require(rewardsTo != address(0), "LCTSQueueBase/rewards-zero-address");
        require(underlyingTo != address(0), "LCTSQueueBase/underlying-zero-address");
        require(locked == 0, "LCTSQueueBase/queue-locked");
        Position storage pos = positions[owner];
        require(pos.gen == currentGen, "LCTSQueueBase/not-current-gen");
        require(pos.shares > 0, "LCTSQueueBase/zero-shares");

        // Claim pending rewards
        rewardsAmt = _claimRewards(owner, pos, rewardsTo);

        // Calculate proportional underlying
        underlyingAmt = pos.shares * totalUnderlying / totalShares;

        // Update totals
        totalUnderlying -= underlyingAmt;
        totalShares -= pos.shares;

        // Clear shares
        pos.shares = 0;

        // If last owner exits, advance generation
        if (totalShares == 0) {
            currentGen++;
            totalUnderlying = 0;
        }

        // Transfer assets
        if (underlyingAmt > 0) {
            _pushUnderlying(underlyingTo, underlyingAmt);
        }

        emit Exit(owner, currentGen, rewardsTo, rewardsAmt, underlyingTo, underlyingAmt);
    }

    /// @notice Claim accrued rewards for a user
    /// @param owner Address whose position to claim from
    /// @param rewardsTo Address to receive rewards
    /// @return rewardsAmt Amount of rewards claimed
    function claim(address owner, address rewardsTo) external auth returns (uint256 rewardsAmt) {
        require(owner != address(0), "LCTSQueueBase/owner-zero-address");
        require(rewardsTo != address(0), "LCTSQueueBase/rewardsTo-zero-address");
        Position storage pos = positions[owner];
        require(pos.gen < currentGen || locked == 0, "LCTSQueueBase/queue-locked");
        require(pos.shares > 0, "LCTSQueueBase/no-position");

        rewardsAmt = _claimRewards(owner, pos, rewardsTo);
    }

    /// @notice Settle conversions for the current epoch
    /// @param capacity Maximum amount of underlying to convert this epoch
    /// @return converted Actual amount of underlying converted
    function settle(uint256 capacity) external auth returns (uint256 converted) {
        require(locked == 1, "LCTSQueueBase/not-locked");

        // Zero-capacity settle: just unlock
        if (totalUnderlying == 0 || capacity == 0) {
            locked = 0;
            emit Settle(currentGen, capacity, 0, 0, false);
            return 0;
        }

        // Determine conversion amount
        converted = capacity < totalUnderlying ? capacity : totalUnderlying;

        // Execute conversion
        uint256 received = _convert(converted);

        // Update reward accumulator
        rewardPerToken[currentGen] += received * WAD / totalShares;

        // Reduce underlying
        totalUnderlying -= converted;

        bool finalized = totalUnderlying == 0;

        // If generation fully drained, finalize and advance
        if (finalized) {
            currentGen++;
            totalShares = 0;
        }
        locked = 0;

        emit Settle(finalized ? currentGen - 1 : currentGen, capacity, converted, received, finalized);
    }

    // --- View Functions ---

    function pendingRewards(address owner) external view returns (uint256) {
        Position memory pos = positions[owner];
        return (pos.shares == 0)
                ? 0
                : pos.shares * (rewardPerToken[pos.gen] - pos.rewardDebt) / WAD;
    }

    function underlyingBalance(address owner) external view returns (uint256) {
        Position memory pos = positions[owner];
        return (pos.shares == 0 || pos.gen < currentGen || totalShares == 0)
                ? 0
                : pos.shares * totalUnderlying / totalShares;
    }

    function isFinalized(address owner) external view returns (bool) {
        Position memory pos = positions[owner];
        return pos.shares > 0 && pos.gen < currentGen;
    }
}
