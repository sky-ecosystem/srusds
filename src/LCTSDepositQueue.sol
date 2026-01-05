// SPDX-License-Identifier: AGPL-3.0-or-later

/// LCTSDepositQueue.sol -- Generic LCTS queue for asset → vault share conversions

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

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @title LCTSDepositQueue
/// @notice Generic LCTS (Liquidity Constrained Token Standard) queue for depositing assets into a vault
/// @dev Operator-only access. Users interact through an authorized operator (e.g., Handler).
///      Implements the generation-based model where all depositors in the same generation
///      share proportionally in the conversion capacity allocated to that generation.
contract LCTSDepositQueue {

    // --- Storage Variables ---

    mapping(address => uint256) public wards;

    // Generation state (active generation)
    uint256 public currentGen;        // Current generation ID
    uint256 public totalShares;       // Total internal shares in current generation
    uint256 public totalUnderlying;   // Total unconverted underlying in current generation
    uint256 public rewardPerToken;    // Cumulative vault shares per internal share [wad]

    // Finalized generation data
    struct FinalizedGen {
        uint256 finalRewardPerToken;  // rewardPerToken at finalization [wad]
        bool    finalized;            // Whether generation is finalized
    }
    mapping(uint256 => FinalizedGen) public generations;

    // User positions (one position per user)
    struct Position {
        uint256 gen;        // Generation this position belongs to
        uint256 shares;     // Number of internal shares held
        uint256 rewardDebt; // rewardPerToken snapshot at entry [wad]
    }
    mapping(address => Position) public positions;

    // --- Immutables ---

    IERC20   public immutable underlying;  // Asset users deposit
    IERC4626 public immutable vault;       // Vault receiving deposits (also the reward token)

    // --- Constants ---

    uint256 constant WAD = 10 ** 18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Deposit(address indexed user, uint256 indexed gen, uint256 assets, uint256 shares);
    event Claim(address indexed user, uint256 indexed gen, uint256 vaultShares, address indexed to);
    event Exit(address indexed user, uint256 indexed gen, uint256 assets, uint256 vaultShares, address indexed to);
    event Settle(uint256 indexed gen, uint256 capacity, uint256 converted, uint256 vaultSharesMinted, bool finalized);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "LCTSDepositQueue/not-authorized");
        _;
    }

    // --- Constructor ---

    /// @param underlying_ Address of the underlying asset (what users deposit)
    /// @param vault_ Address of the ERC4626 vault (what users receive shares of)
    constructor(address underlying_, address vault_) {
        underlying = IERC20(underlying_);
        vault = IERC4626(vault_);

        // Validate vault's asset matches underlying
        require(vault.asset() == underlying_, "LCTSDepositQueue/asset-mismatch");

        // Max approve vault to spend underlying for deposits
        underlying.approve(vault_, type(uint256).max);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Admin Functions ---

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    // --- Operator Functions ---

    /// @notice Deposit underlying assets into the queue for a user
    /// @param assets Amount of underlying to deposit
    /// @param receiver Address to receive the queue position
    /// @dev If user has position in finalized generation, settles it first.
    ///      If user has position in current generation, claims pending rewards first.
    function deposit(uint256 assets, address receiver) external auth {
        require(assets > 0, "LCTSDepositQueue/zero-amount");
        require(receiver != address(0), "LCTSDepositQueue/zero-address");

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
            shares = assets;  // 1:1 for first deposit in generation
        } else {
            shares = assets * totalShares / totalUnderlying;
        }
        require(shares > 0, "LCTSDepositQueue/zero-shares");

        // Update state
        totalUnderlying += assets;
        totalShares += shares;
        pos.gen = currentGen;
        pos.shares += shares;
        pos.rewardDebt = rewardPerToken;

        // Transfer underlying from caller (operator)
        underlying.transferFrom(msg.sender, address(this), assets);

        emit Deposit(receiver, currentGen, assets, shares);
    }

    /// @notice Claim accrued vault shares for a user
    /// @param user Address of the position owner
    /// @param to Address to receive vault shares
    /// @return vaultShares Amount of vault shares claimed
    function claim(address user, address to) external auth returns (uint256 vaultShares) {
        require(to != address(0), "LCTSDepositQueue/zero-address");
        Position storage pos = positions[user];
        require(pos.shares > 0, "LCTSDepositQueue/no-position");

        if (pos.gen < currentGen) {
            // Finalized generation - full settlement
            vaultShares = _settleFinalized(user, to);
        } else {
            // Current generation - claim rewards only
            vaultShares = _claimRewards(user, to);
        }
    }

    /// @notice Exit the queue completely for a user (current generation only)
    /// @param user Address of the position owner
    /// @param to Address to receive assets
    /// @return assets Amount of underlying returned
    /// @return vaultShares Amount of vault shares claimed
    function claimAndExit(address user, address to) external auth returns (uint256 assets, uint256 vaultShares) {
        require(to != address(0), "LCTSDepositQueue/zero-address");
        Position storage pos = positions[user];
        require(pos.shares > 0, "LCTSDepositQueue/no-position");
        require(pos.gen == currentGen, "LCTSDepositQueue/not-current-gen");

        // Calculate vault shares (rewards)
        vaultShares = pos.shares * (rewardPerToken - pos.rewardDebt) / WAD;

        // Calculate proportional underlying
        assets = pos.shares * totalUnderlying / totalShares;

        // Update totals
        totalUnderlying -= assets;
        totalShares -= pos.shares;

        // Clear position
        pos.shares = 0;
        pos.rewardDebt = 0;

        // Transfer assets
        if (vaultShares > 0) {
            IERC20(address(vault)).transfer(to, vaultShares);
        }
        if (assets > 0) {
            underlying.transfer(to, assets);
        }

        emit Exit(user, currentGen, assets, vaultShares, to);
    }

    /// @notice Settle conversions for the current epoch
    /// @param capacity Maximum amount of underlying to convert this epoch
    /// @return converted Actual amount of underlying converted
    /// @dev Called by operator during epoch settlement. Converts underlying to vault shares
    ///      and distributes rewards proportionally to all shareholders.
    function settle(uint256 capacity) external auth returns (uint256 converted) {
        if (totalUnderlying == 0 || capacity == 0) return 0;

        // Determine conversion amount
        converted = capacity < totalUnderlying ? capacity : totalUnderlying;

        // Execute conversion: deposit underlying into vault, receive vault shares
        uint256 vaultSharesReceived = vault.deposit(converted, address(this));

        // Update reward accumulator
        rewardPerToken += vaultSharesReceived * WAD / totalShares;

        // Reduce underlying
        totalUnderlying -= converted;

        bool finalized = totalUnderlying == 0;

        // If generation fully drained, finalize it
        if (finalized) {
            generations[currentGen] = FinalizedGen({
                finalRewardPerToken: rewardPerToken,
                finalized: true
            });
            currentGen++;
            totalShares = 0;
            rewardPerToken = 0;
        }

        emit Settle(finalized ? currentGen - 1 : currentGen, capacity, converted, vaultSharesReceived, finalized);
    }

    // --- Internal Functions ---

    function _claimRewards(address user, address to) internal returns (uint256 vaultShares) {
        Position storage pos = positions[user];
        vaultShares = pos.shares * (rewardPerToken - pos.rewardDebt) / WAD;
        pos.rewardDebt = rewardPerToken;

        if (vaultShares > 0) {
            IERC20(address(vault)).transfer(to, vaultShares);
            emit Claim(user, currentGen, vaultShares, to);
        }
    }

    function _settleFinalized(address user, address to) internal returns (uint256 vaultShares) {
        Position storage pos = positions[user];
        FinalizedGen storage gen = generations[pos.gen];
        require(gen.finalized, "LCTSDepositQueue/not-finalized");

        uint256 userGen = pos.gen;
        vaultShares = pos.shares * (gen.finalRewardPerToken - pos.rewardDebt) / WAD;

        // Clear position
        pos.shares = 0;
        pos.rewardDebt = 0;

        if (vaultShares > 0) {
            IERC20(address(vault)).transfer(to, vaultShares);
            emit Claim(user, userGen, vaultShares, to);
        }
    }

    // --- View Functions ---

    /// @notice Get pending vault shares for a user
    /// @param user Address to query
    /// @return Pending vault shares
    function pendingRewards(address user) external view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.shares == 0) return 0;

        uint256 rpt;
        if (pos.gen < currentGen) {
            rpt = generations[pos.gen].finalRewardPerToken;
        } else {
            rpt = rewardPerToken;
        }
        return pos.shares * (rpt - pos.rewardDebt) / WAD;
    }

    /// @notice Get unconverted underlying balance for a user
    /// @param user Address to query
    /// @return Unconverted underlying (0 if in finalized generation)
    function underlyingBalance(address user) external view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.shares == 0 || pos.gen < currentGen || totalShares == 0) return 0;
        return pos.shares * totalUnderlying / totalShares;
    }

    /// @notice Check if user's generation is finalized
    /// @param user Address to query
    /// @return True if user's generation is finalized
    function isFinalized(address user) external view returns (bool) {
        Position storage pos = positions[user];
        return pos.shares > 0 && pos.gen < currentGen;
    }

    /// @notice Get user's position details
    /// @param user Address to query
    /// @return gen Generation ID
    /// @return shares Internal shares held
    /// @return rewardDebt Reward debt snapshot
    function getPosition(address user) external view returns (uint256 gen, uint256 shares, uint256 rewardDebt) {
        Position storage pos = positions[user];
        return (pos.gen, pos.shares, pos.rewardDebt);
    }
}
