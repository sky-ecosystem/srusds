// SPDX-License-Identifier: AGPL-3.0-or-later

/// LCTSWithdrawQueue.sol -- Generic LCTS queue for vault share → asset conversions

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
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

/// @title LCTSWithdrawQueue
/// @notice Generic LCTS (Liquidity Constrained Token Standard) queue for redeeming vault shares
/// @dev Operator-only access. Users interact through an authorized operator (e.g., Handler).
///      Implements the generation-based model where all depositors in the same generation
///      share proportionally in the conversion capacity allocated to that generation.
contract LCTSWithdrawQueue {

    // --- Storage Variables ---

    mapping(address => uint256) public wards;

    // Generation state (active generation)
    uint256 public currentGen;        // Current generation ID
    uint256 public totalShares;       // Total internal shares in current generation
    uint256 public totalUnderlying;   // Total unconverted vault shares in current generation
    uint256 public rewardPerToken;    // Cumulative assets per internal share [wad]

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

    IERC4626 public immutable vault;       // Vault being redeemed from (also what users deposit)
    IERC20   public immutable asset;       // Underlying asset of vault (reward token)

    // --- Constants ---

    uint256 constant WAD = 10 ** 18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Deposit(address indexed user, uint256 indexed gen, uint256 vaultShares, uint256 shares);
    event Claim(address indexed user, uint256 indexed gen, uint256 assets, address indexed to);
    event Exit(address indexed user, uint256 indexed gen, uint256 vaultShares, uint256 assets, address indexed to);
    event Settle(uint256 indexed gen, uint256 capacity, uint256 redeemed, uint256 assetsReceived, bool finalized);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "LCTSWithdrawQueue/not-authorized");
        _;
    }

    // --- Constructor ---

    /// @param vault_ Address of the ERC4626 vault (what users deposit shares of)
    constructor(address vault_) {
        vault = IERC4626(vault_);
        asset = IERC20(vault.asset());

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

    /// @notice Deposit vault shares into the queue for a user
    /// @param vaultShares Amount of vault shares to deposit
    /// @param receiver Address to receive the queue position
    /// @dev If user has position in finalized generation, settles it first.
    ///      If user has position in current generation, claims pending rewards first.
    function deposit(uint256 vaultShares, address receiver) external auth {
        require(vaultShares > 0, "LCTSWithdrawQueue/zero-amount");
        require(receiver != address(0), "LCTSWithdrawQueue/zero-address");

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
            shares = vaultShares;  // 1:1 for first deposit in generation
        } else {
            shares = vaultShares * totalShares / totalUnderlying;
        }
        require(shares > 0, "LCTSWithdrawQueue/zero-shares");

        // Update state
        totalUnderlying += vaultShares;
        totalShares += shares;
        pos.gen = currentGen;
        pos.shares += shares;
        pos.rewardDebt = rewardPerToken;

        // Transfer vault shares from caller (operator)
        IERC20(address(vault)).transferFrom(msg.sender, address(this), vaultShares);

        emit Deposit(receiver, currentGen, vaultShares, shares);
    }

    /// @notice Claim accrued assets for a user
    /// @param user Address of the position owner
    /// @param to Address to receive assets
    /// @return assets Amount of underlying assets claimed
    function claim(address user, address to) external auth returns (uint256 assets) {
        require(to != address(0), "LCTSWithdrawQueue/zero-address");
        Position storage pos = positions[user];
        require(pos.shares > 0, "LCTSWithdrawQueue/no-position");

        if (pos.gen < currentGen) {
            // Finalized generation - full settlement
            assets = _settleFinalized(user, to);
        } else {
            // Current generation - claim rewards only
            assets = _claimRewards(user, to);
        }
    }

    /// @notice Exit the queue completely for a user (current generation only)
    /// @param user Address of the position owner
    /// @param to Address to receive assets
    /// @return vaultShares Amount of vault shares returned
    /// @return assets Amount of underlying assets claimed
    function claimAndExit(address user, address to) external auth returns (uint256 vaultShares, uint256 assets) {
        require(to != address(0), "LCTSWithdrawQueue/zero-address");
        Position storage pos = positions[user];
        require(pos.shares > 0, "LCTSWithdrawQueue/no-position");
        require(pos.gen == currentGen, "LCTSWithdrawQueue/not-current-gen");

        // Calculate assets (rewards)
        assets = pos.shares * (rewardPerToken - pos.rewardDebt) / WAD;

        // Calculate proportional vault shares (underlying for this queue)
        vaultShares = pos.shares * totalUnderlying / totalShares;

        // Update totals
        totalUnderlying -= vaultShares;
        totalShares -= pos.shares;

        // Clear position
        pos.shares = 0;
        pos.rewardDebt = 0;

        // Transfer assets
        if (assets > 0) {
            asset.transfer(to, assets);
        }
        if (vaultShares > 0) {
            IERC20(address(vault)).transfer(to, vaultShares);
        }

        emit Exit(user, currentGen, vaultShares, assets, to);
    }

    /// @notice Settle conversions for the current epoch
    /// @param capacity Maximum amount of vault shares to redeem this epoch
    /// @return redeemed Actual amount of vault shares redeemed
    /// @dev Called by operator during epoch settlement. Redeems vault shares for assets
    ///      and distributes rewards proportionally to all shareholders.
    function settle(uint256 capacity) external auth returns (uint256 redeemed) {
        if (totalUnderlying == 0 || capacity == 0) return 0;

        // Determine redemption amount
        redeemed = capacity < totalUnderlying ? capacity : totalUnderlying;

        // Execute conversion: redeem vault shares for assets
        uint256 assetsReceived = vault.redeem(redeemed, address(this), address(this));

        // Update reward accumulator
        rewardPerToken += assetsReceived * WAD / totalShares;

        // Reduce underlying (vault shares)
        totalUnderlying -= redeemed;

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

        emit Settle(finalized ? currentGen - 1 : currentGen, capacity, redeemed, assetsReceived, finalized);
    }

    // --- Internal Functions ---

    function _claimRewards(address user, address to) internal returns (uint256 assets) {
        Position storage pos = positions[user];
        assets = pos.shares * (rewardPerToken - pos.rewardDebt) / WAD;
        pos.rewardDebt = rewardPerToken;

        if (assets > 0) {
            asset.transfer(to, assets);
            emit Claim(user, currentGen, assets, to);
        }
    }

    function _settleFinalized(address user, address to) internal returns (uint256 assets) {
        Position storage pos = positions[user];
        FinalizedGen storage gen = generations[pos.gen];
        require(gen.finalized, "LCTSWithdrawQueue/not-finalized");

        uint256 userGen = pos.gen;
        assets = pos.shares * (gen.finalRewardPerToken - pos.rewardDebt) / WAD;

        // Clear position
        pos.shares = 0;
        pos.rewardDebt = 0;

        if (assets > 0) {
            asset.transfer(to, assets);
            emit Claim(user, userGen, assets, to);
        }
    }

    // --- View Functions ---

    /// @notice Get pending assets for a user
    /// @param user Address to query
    /// @return Pending underlying assets
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

    /// @notice Get unconverted vault shares balance for a user
    /// @param user Address to query
    /// @return Unconverted vault shares (0 if in finalized generation)
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
