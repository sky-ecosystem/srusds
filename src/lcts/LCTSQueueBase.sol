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

    // --- Types ---

    enum Status { DORMANT, ACTIVE, LOCKED }

    struct Position {
        uint256 gen;        // Generation this position belongs to
        uint256 shares;     // Number of internal shares held
        uint256 rewardDebt; // rewardPerToken snapshot at entry [wad]
    }

    // --- Storage Variables ---

    mapping(address => uint256) public wards;

    Status public status;

    uint256 public currentGen;
    uint256 public totalShares;
    uint256 public totalUnderlying;
    uint256 public rewardPerToken;    // Cumulative reward per internal share [wad]

    mapping(uint256 gen => uint256 rewardPerToken) public finalRewardPerToken; // [wad]
    mapping(address => Position) public positions;

    // --- Constants ---

    uint256 constant WAD = 10 ** 18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Deposit(address indexed user, uint256 indexed gen, uint256 amount, uint256 shares);
    event Claim(address indexed user, uint256 indexed gen, uint256 reward, address indexed to);
    event Exit(address indexed user, uint256 indexed gen, uint256 underlying, uint256 reward, address indexed to);
    event Lock(uint256 indexed gen);
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
    /// @dev Reverts if not ACTIVE.
    function lock() external auth {
        require(status == Status.ACTIVE, "LCTSQueueBase/not-active");
        status = Status.LOCKED;
        emit Lock(currentGen);
    }

    // --- User Functions ---

    /// @notice Deposit underlying assets into the queue
    /// @param amount Amount of underlying to deposit (pulled from msg.sender)
    /// @param receiver Address to receive the queue position
    function deposit(uint256 amount, address receiver) external {
        require(status != Status.LOCKED, "LCTSQueueBase/queue-locked");
        require(amount > 0, "LCTSQueueBase/zero-amount");
        require(receiver != address(0), "LCTSQueueBase/zero-address");

        // Lazy activation: DORMANT → ACTIVE on first deposit
        if (status == Status.DORMANT) {
            status = Status.ACTIVE;
        }

        Position storage pos = positions[receiver];

        // If user has position in finalized generation, settle it first
        if (pos.shares > 0 && pos.gen < currentGen) {
            _settleFinalized(receiver, receiver);
        }

        // If user has position in current generation, claim pending rewards
        if (pos.shares > 0 && pos.gen == currentGen) {
            _claimRewards(receiver, receiver);
        }

        // Calculate internal shares to mint
        uint256 shares;
        if (totalShares == 0) {
            shares = amount;  // 1:1 for first deposit in generation
        } else {
            shares = amount * totalShares / totalUnderlying;
        }
        require(shares > 0, "LCTSQueueBase/zero-shares");

        // Update state
        totalUnderlying += amount;
        totalShares += shares;
        pos.gen = currentGen;
        pos.shares += shares;
        pos.rewardDebt = rewardPerToken;

        // Transfer underlying from caller
        _pullUnderlying(msg.sender, amount);

        emit Deposit(receiver, currentGen, amount, shares);
    }

    /// @notice Claim accrued rewards for msg.sender
    /// @param to Address to receive rewards
    /// @return reward Amount of reward claimed
    function claim(address to) external returns (uint256 reward) {
        require(to != address(0), "LCTSQueueBase/zero-address");
        Position storage pos = positions[msg.sender];
        require(pos.shares > 0, "LCTSQueueBase/no-position");

        if (pos.gen < currentGen) {
            // Finalized generation - full settlement (always allowed)
            reward = _settleFinalized(msg.sender, to);
        } else {
            // Current generation - claim rewards only (requires ACTIVE)
            require(status == Status.ACTIVE, "LCTSQueueBase/queue-not-active");
            reward = _claimRewards(msg.sender, to);
        }
    }

    /// @notice Exit the queue completely (current generation only)
    /// @param to Address to receive assets
    /// @return underlyingOut Amount of underlying returned
    /// @return rewardOut Amount of reward claimed
    function claimAndExit(address to) external returns (uint256 underlyingOut, uint256 rewardOut) {
        require(status == Status.ACTIVE, "LCTSQueueBase/queue-not-active");
        require(to != address(0), "LCTSQueueBase/zero-address");
        Position storage pos = positions[msg.sender];
        require(pos.shares > 0, "LCTSQueueBase/no-position");
        require(pos.gen == currentGen, "LCTSQueueBase/not-current-gen");

        // Claim pending rewards
        rewardOut = _claimRewards(msg.sender, to);

        // Calculate proportional underlying
        underlyingOut = pos.shares * totalUnderlying / totalShares;

        // Update totals
        totalUnderlying -= underlyingOut;
        totalShares -= pos.shares;

        // Clear position
        pos.shares = 0;
        pos.rewardDebt = 0;

        // If last user exits, go DORMANT and advance generation
        if (totalShares == 0) {
            currentGen++;
            totalUnderlying = 0;
            rewardPerToken = 0;
            status = Status.DORMANT;
        }

        // Transfer assets
        if (underlyingOut > 0) {
            _pushUnderlying(to, underlyingOut);
        }

        emit Exit(msg.sender, currentGen, underlyingOut, rewardOut, to);
    }

    /// @notice Settle conversions for the current epoch
    /// @param capacity Maximum amount of underlying to convert this epoch
    /// @return converted Actual amount of underlying converted
    function settle(uint256 capacity) external auth returns (uint256 converted) {
        require(status == Status.LOCKED, "LCTSQueueBase/not-locked");

        // Zero-capacity settle: just unlock back to ACTIVE
        if (totalUnderlying == 0 || capacity == 0) {
            status = Status.ACTIVE;
            emit Settle(currentGen, capacity, 0, 0, false);
            return 0;
        }

        // Determine conversion amount
        converted = capacity < totalUnderlying ? capacity : totalUnderlying;

        // Execute conversion
        uint256 received = _convert(converted);

        // Update reward accumulator
        rewardPerToken += received * WAD / totalShares;

        // Reduce underlying
        totalUnderlying -= converted;

        bool finalized = totalUnderlying == 0;

        // If generation fully drained, finalize it and go DORMANT
        if (finalized) {
            finalRewardPerToken[currentGen] = rewardPerToken;
            currentGen++;
            totalShares = 0;
            rewardPerToken = 0;
            status = Status.DORMANT;
        } else {
            status = Status.ACTIVE;
        }

        emit Settle(finalized ? currentGen - 1 : currentGen, capacity, converted, received, finalized);
    }

    // --- Internal Functions ---

    function _claimRewards(address user, address to) internal returns (uint256 reward) {
        Position storage pos = positions[user];
        reward = pos.shares * (rewardPerToken - pos.rewardDebt) / WAD;
        pos.rewardDebt = rewardPerToken;

        if (reward > 0) {
            _pushReward(to, reward);
            emit Claim(user, currentGen, reward, to);
        }
    }

    function _settleFinalized(address user, address to) internal returns (uint256 reward) {
        Position storage pos = positions[user];
        uint256 userGen = pos.gen;
        uint256 fRpt = finalRewardPerToken[userGen];
        require(fRpt > 0, "LCTSQueueBase/not-finalized");

        reward = pos.shares * (fRpt - pos.rewardDebt) / WAD;

        // Clear position
        pos.shares = 0;
        pos.rewardDebt = 0;

        if (reward > 0) {
            _pushReward(to, reward);
            emit Claim(user, userGen, reward, to);
        }
    }

    // --- View Functions ---

    function pendingRewards(address user) external view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.shares == 0) return 0;

        uint256 rpt;
        if (pos.gen < currentGen) {
            rpt = finalRewardPerToken[pos.gen];
        } else {
            rpt = rewardPerToken;
        }
        return pos.shares * (rpt - pos.rewardDebt) / WAD;
    }

    function underlyingBalance(address user) external view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.shares == 0 || pos.gen < currentGen || totalShares == 0) return 0;
        return pos.shares * totalUnderlying / totalShares;
    }

    function isFinalized(address user) external view returns (bool) {
        Position storage pos = positions[user];
        return pos.shares > 0 && pos.gen < currentGen;
    }

    function getPosition(address user) external view returns (uint256 gen, uint256 shares, uint256 rewardDebt) {
        Position storage pos = positions[user];
        return (pos.gen, pos.shares, pos.rewardDebt);
    }
}
