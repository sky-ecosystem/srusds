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
    function deposit(uint256, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function settle(int256) external;
}

/// @title LCTSQueues
/// @notice Asynchronous deposit and redeem requests, settled in a daily window on scheduled days, for a single share token
/// @dev Loosely follows ERC-7540/ERC-7575: this contract is the vault users request, cancel and claim on, and
///      `share` is the separate share token. It holds everything owed to users: pending assets, pending
///      (escrowed) shares, and claimable shares/assets not yet claimed. The share token only holds the backing
///      of its outstanding supply. On settlement the share is revalued (settle) and each queue converts up to
///      its planned capacity through the share's deposit/redeem.
///
///      Roles as in ERC-7540: `owner` provides the tokens of a request, `controller` owns the request (its pending and
///      claimable amounts) and is the only one, besides its operators, who can cancel or claim it, and `receiver` gets
///      the tokens on cancel or claim. An operator approved through setOperator can act as owner or controller.
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
    // Settlement schedule, packed into one slot as it is read on every request and cancellation
    uint32  public lockTimeBgn;      // Time in the day when the settlement window opens  [seconds, e.g. 13 hours == 13:00 UTC]
    uint32  public lockTimeEnd;      // Time in the day when the settlement window closes [seconds, e.g. 16 hours == 16:00 UTC]
    uint32  public period;           // Days between settlement days [days, e.g. 7 == weekly]
    uint32  public startDay;         // First settlement day, then every `period` days after it [days since epoch]
    uint32  public lastSettleDay;    // Day of the last settlement [days since epoch]

    Queue public depositQueue;       // Underlying = assets, reward = shares (getter: currentGen, totalShares, totalUnderlying)
    Queue public redeemQueue;        // Underlying = shares, reward = assets (getter: currentGen, totalShares, totalUnderlying)

    mapping(address controller => mapping(address operator => bool)) public isOperator;

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
    event Settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity, uint256 depositsConverted, uint256 depositsReceived, uint256 redeemsConverted, uint256 redeemsReceived);
    event SetOperator(address indexed controller, address indexed operator, bool approved);
    event QueueDeposit(address indexed controller, address indexed owner, address sender, uint256 assets);
    event Referral(address indexed controller, uint256 assets, uint16 indexed referral);
    event QueueRedeem(address indexed controller, address indexed owner, address sender, uint256 shares);
    event CancelDeposit(address indexed controller, address indexed receiver, address sender, uint256 assets);
    event CancelRedeem(address indexed controller, address indexed receiver, address sender, uint256 shares);
    event ClaimDeposit(address indexed controller, address indexed receiver, address sender, uint256 shares);
    event ClaimRedeem(address indexed controller, address indexed receiver, address sender, uint256 assets);

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
            lockTimeBgn = uint32(data);
        } else if (what == "lockTimeEnd") {
            require(data <= 1 days, "LCTSQueues/incorrect-time-in-day");
            require(data > lockTimeBgn, "LCTSQueues/not-greater-lock-bgn");
            lockTimeEnd = uint32(data);
        } else if (what == "period") {
            require(data > 0, "LCTSQueues/zero-period");
            require(data <= type(uint32).max, "LCTSQueues/period-overflow");
            period = uint32(data);
        } else if (what == "startDay") {
            require(data <= type(uint32).max, "LCTSQueues/startDay-overflow");
            startDay = uint32(data);
        } else revert("LCTSQueues/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Settlement ---

    /// @dev On a settlement day, inside its window and not yet settled: requests and cancellations are closed
    ///      and settle() can be called. Settling reopens the queues for the rest of the window
    function _locked() internal view returns (bool) {
        uint256 day  = block.timestamp / 1 days;
        uint256 time = block.timestamp % 1 days;
        return day >= startDay                      // The schedule has started
            && (day - startDay) % period == 0       // Today is a settlement day
            && time >= lockTimeBgn                  // The settlement window has opened
            && time < lockTimeEnd                   // and has not closed yet
            && lastSettleDay < day;                 // Today has not been settled yet
    }

    /// @dev Convert up to capacity of a queue's underlying into its reward through the share token:
    ///      asset into shares for the deposit queue, shares into asset for the redeem queue
    function _convert(Queue storage queue, TokenLike underlying, uint256 capacity) internal returns (uint256 converted, uint256 received) {
        uint256 totalUnderlying = queue.totalUnderlying;
        uint256 totalShares = queue.totalShares;

        converted = capacity < totalUnderlying ? capacity : totalUnderlying;

        // A conversion removes underlying but keeps all shares, so the shares per unit of underlying go up.
        // With only a tiny remainder left, the next joiner would get a huge number of shares and every later
        // reward per share would round down to zero. So either drain the generation completely or leave at
        // least totalShares / MAX_SHARE_RATIO behind.
        if (converted < totalUnderlying) {
            uint256 minRemainder = totalShares / MAX_SHARE_RATIO;
            if (totalUnderlying - converted < minRemainder) {
                converted = totalUnderlying > minRemainder ? totalUnderlying - minRemainder : 0;
            }
        }

        // Nothing to convert (empty queue or no capacity); also avoids dividing by totalShares == 0 below
        if (converted == 0) return (0, 0);

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

    /// @notice Revalue the share by `profit` and convert both queues up to the given capacities, once per window
    function settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) external auth {
        require(_locked(), "LCTSQueues/not-locked");
        lastSettleDay = uint32(block.timestamp / 1 days);

        // Revalue the outstanding shares before converting at the new price
        share.settle(profit);

        // Convert both queues up to their capacity
        (uint256 depositsConverted, uint256 depositsReceived) = _convert(depositQueue, asset, depositCapacity);
        (uint256 redeemsConverted,  uint256 redeemsReceived)  = _convert(redeemQueue, share, redeemCapacity);

        emit Settle(profit, depositCapacity, redeemCapacity, depositsConverted, depositsReceived, redeemsConverted, redeemsReceived);
    }

    // --- Internal Queue Logic ---

    /// @dev Move what has converted since the last checkpoint into the stored claimable balance, without paying it out
    function _checkpoint(Queue storage queue, Position storage pos) internal {
        uint256 rpt = queue.rewardPerToken[pos.gen];
        pos.claimable += pos.shares * (rpt - pos.rewardDebt) / RAY;
        pos.rewardDebt = rpt;
    }

    /// @dev msg.sender must be `usr` or an operator approved by `usr`
    function _checkOperator(address usr) internal view {
        require(usr == msg.sender || isOperator[usr][msg.sender], "LCTSQueues/not-operator");
    }

    function _queue(Queue storage queue, TokenLike token, uint256 amount, address controller, address owner) internal {
        _checkOperator(owner);
        require(controller != address(0), "LCTSQueues/controller-zero-address");
        require(amount > 0, "LCTSQueues/zero-amount");
        require(!_locked(), "LCTSQueues/queue-locked");

        Position storage pos = queue.positions[controller];

        _checkpoint(queue, pos);

        // Escrow the queued amount from the owner
        token.transferFrom(owner, address(this), amount);

        // Calculate internal queue shares to mint
        uint256 queueShares = queue.totalShares == 0
                              ? amount
                              : amount * queue.totalShares / queue.totalUnderlying;
        require(queueShares > 0, "LCTSQueues/zero-shares");

        // Update state
        uint256 gen = queue.currentGen;
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

    function _cancel(Queue storage queue, TokenLike token, address receiver, address controller) internal returns (uint256 amount) {
        _checkOperator(controller);
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        require(!_locked(), "LCTSQueues/queue-locked");
        Position storage pos = queue.positions[controller];
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

        // If last controller cancels, clear any rounding dust so the next request starts at 1:1
        if (queue.totalShares == 0) {
            queue.totalUnderlying = 0;
        }

        // Return the pending amount
        token.transfer(receiver, amount);
    }

    function _claim(Queue storage queue, TokenLike token, uint256 amount, address receiver, address controller) internal returns (uint256 claimed) {
        _checkOperator(controller);
        require(receiver != address(0), "LCTSQueues/receiver-zero-address");
        Position storage pos = queue.positions[controller];

        _checkpoint(queue, pos);
        claimed = amount == type(uint256).max ? pos.claimable : amount;
        require(claimed <= pos.claimable, "LCTSQueues/insufficient-claimable");
        pos.claimable -= claimed;

        token.transfer(receiver, claimed);
    }

    // --- User Functions ---

    /// @notice Approve or revoke `operator` to request, cancel and claim on behalf of msg.sender
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit SetOperator(msg.sender, operator, approved);
        return true;
    }

    /// @notice Queue a deposit of `assets` taken from `owner`, credited to `controller`
    /// @param referral Referral code for attribution, emitted in a Referral event (0 if none)
    function queueDeposit(uint256 assets, address controller, address owner, uint16 referral) external {
        _queue(depositQueue, asset, assets, controller, owner);
        emit QueueDeposit(controller, owner, msg.sender, assets);
        emit Referral(controller, assets, referral);
    }

    /// @notice Queue a redeem of `shares` taken from `owner`, credited to `controller`
    function queueRedeem(uint256 shares, address controller, address owner) external {
        _queue(redeemQueue, share, shares, controller, owner);
        emit QueueRedeem(controller, owner, msg.sender, shares);
    }

    /// @notice Cancel `controller`'s pending deposit request, returning its pending assets to `receiver` (anything converted stays claimable)
    function cancelDeposit(address receiver, address controller) external returns (uint256 assets) {
        assets = _cancel(depositQueue, asset, receiver, controller);
        emit CancelDeposit(controller, receiver, msg.sender, assets);
    }

    /// @notice Cancel `controller`'s pending redeem request, returning its pending shares to `receiver` (anything converted stays claimable)
    function cancelRedeem(address receiver, address controller) external returns (uint256 shares) {
        shares = _cancel(redeemQueue, share, receiver, controller);
        emit CancelRedeem(controller, receiver, msg.sender, shares);
    }

    /// @notice Claim `shares` converted from `controller`'s deposit requests to `receiver` (type(uint256).max claims all)
    function claimDeposit(uint256 shares, address receiver, address controller) external returns (uint256 claimed) {
        claimed = _claim(depositQueue, share, shares, receiver, controller);
        emit ClaimDeposit(controller, receiver, msg.sender, claimed);
    }

    /// @notice Claim `assets` converted from `controller`'s redeem requests to `receiver` (type(uint256).max claims all)
    function claimRedeem(uint256 assets, address receiver, address controller) external returns (uint256 claimed) {
        claimed = _claim(redeemQueue, asset, assets, receiver, controller);
        emit ClaimRedeem(controller, receiver, msg.sender, claimed);
    }

    // --- View Functions ---

    /// @notice Whether requests and cancellations are currently closed: on a settlement day, inside its window and not yet settled
    function locked() external view returns (bool) {
        return _locked();
    }

    // Pending: a position with shares in the current generation is part of totalShares, so it is non-zero there

    /// @notice Assets still waiting to be converted to shares
    function pendingDeposit(address controller) external view returns (uint256) {
        Position memory pos = depositQueue.positions[controller];
        return (pos.shares == 0 || pos.gen < depositQueue.currentGen) ? 0 : pos.shares * depositQueue.totalUnderlying / depositQueue.totalShares;
    }

    /// @notice Shares still waiting to be converted to assets
    function pendingRedeem(address controller) external view returns (uint256) {
        Position memory pos = redeemQueue.positions[controller];
        return (pos.shares == 0 || pos.gen < redeemQueue.currentGen) ? 0 : pos.shares * redeemQueue.totalUnderlying / redeemQueue.totalShares;
    }

    /// @notice Shares converted from deposits and ready to claim
    function claimableDeposit(address controller) external view returns (uint256) {
        Position memory pos = depositQueue.positions[controller];
        return pos.claimable + pos.shares * (depositQueue.rewardPerToken[pos.gen] - pos.rewardDebt) / RAY;
    }

    /// @notice Assets converted from redeems and ready to claim
    function claimableRedeem(address controller) external view returns (uint256) {
        Position memory pos = redeemQueue.positions[controller];
        return pos.claimable + pos.shares * (redeemQueue.rewardPerToken[pos.gen] - pos.rewardDebt) / RAY;
    }
}
