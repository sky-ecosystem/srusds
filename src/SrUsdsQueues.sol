// SPDX-License-Identifier: AGPL-3.0-or-later

/// SrUsdsQueues.sol -- LCTS (Liquidity Constrained Token Standard) deposit/redeem queues and settlement cycle

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

/// @title SrUsdsQueues
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
///      Both queues pool their requests: a request adds its underlying to the pool and gets the same number of
///      units, and each settlement converts part of the pool's underlying into its reward, which stays in the
///      pool. A unit is thus a pro rata claim on both what is still pending and what has been converted, so
///      every position gets the same fraction of every conversion. The accounting is a single pool with no
///      per-position accumulator: on any action by its controller, a position leaves the pool with its share
///      of both balances, the converted part is set aside as its own claimable balance, and the pending part is
///      held again. Requests made since the last settlement are held back and join the pool at the
///      next one, so a conversion is only shared by those who were waiting for it, and what a position has
///      claimable only changes at a settlement.
///
///      Fairness is at claim time, not at settlement time: what a position has converted is only its own once
///      it has been claimed (or set aside by any other action of its controller). Left in the pool over a
///      settlement, it is shared with the requests that join then, in exchange for a larger share of the pending
///      side. Nobody's value changes, but a slow claimer gets less converted and more pending than it had, and
///      the converted part of a redeem is exposed again to the share's gains and losses.
contract SrUsdsQueues is UUPSUpgradeable {

    // --- Structs ---

    struct Position {
        uint256 units;     // Underlying requested: held until the next settlement if `cycle` is the queue's current one, in the pool otherwise
        uint256 cycle;     // Settlement cycle the units were held in
        uint256 claimable; // Converted and set aside for this position, not yet claimed
    }

    struct Queue {
        uint256 cycle;            // Number of settlements so far; requests are held under it until the next one
        uint256 units;            // Units in the pool: one per unit of underlying that joined it
        uint256 unconverted;      // Pool underlying not converted yet
        uint256 converted;        // Pool reward, converted and not yet set aside for a position
        uint256 held;             // Underlying requested since the last settlement, held back until it joins the pool at the next one
        mapping(address usr => Position) positions;
    }

    // --- Storage Variables ---

    // Upgradeable: only append new variables at the end, never reorder, remove or retype existing ones (incl. Queue fields)
    mapping(address usr => uint256 allowed) public wards;
    // Settlement schedule, packed into one slot as it is read on every request and cancellation
    uint32  public lockTimeBgn;      // Time in the day when the settlement window opens  [seconds, e.g. 13 hours == 13:00 UTC]
    uint32  public lockTimeEnd;      // Time in the day when the settlement window closes [seconds, e.g. 16 hours == 16:00 UTC]
    uint32  public period;           // Days between settlement days [days, e.g. 7 == weekly]
    uint32  public startDay;         // First settlement day, then every `period` days after it [days since epoch]
    uint32  public lastSettleDay;    // Day of the last settlement [days since epoch]

    Queue public depositQueue;       // Underlying = assets, reward = shares (getter: cycle, units, unconverted, converted, held)
    Queue public redeemQueue;        // Underlying = shares, reward = assets (getter: cycle, units, unconverted, converted, held)

    mapping(address controller => mapping(address operator => bool)) public isOperator;

    // --- Immutables ---

    ShareLike public immutable share;
    TokenLike public immutable asset;

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
        require(wards[msg.sender] == 1, "SrUsdsQueues/not-authorized");
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
            require(data < 1 days, "SrUsdsQueues/incorrect-time-in-day");
            require(data < lockTimeEnd, "SrUsdsQueues/not-less-lock-end");
            lockTimeBgn = uint32(data);
        } else if (what == "lockTimeEnd") {
            require(data <= 1 days, "SrUsdsQueues/incorrect-time-in-day");
            require(data > lockTimeBgn, "SrUsdsQueues/not-greater-lock-bgn");
            lockTimeEnd = uint32(data);
        } else if (what == "period") {
            require(data > 0, "SrUsdsQueues/zero-period");
            require(data <= type(uint32).max, "SrUsdsQueues/period-overflow");
            period = uint32(data);
        } else if (what == "startDay") {
            require(data <= type(uint32).max, "SrUsdsQueues/startDay-overflow");
            startDay = uint32(data);
        } else revert("SrUsdsQueues/file-unrecognized-param");
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

    /// @dev Let the requests held since the last settlement into the pool, one unit per unit of underlying
    function _admit(Queue storage queue) internal {
        uint256 held = queue.held;
        if (held > 0) {
            queue.units       += held;
            queue.unconverted += held;
            queue.held         = 0;
        }
        queue.cycle++;
    }

    /// @dev Convert up to capacity of a queue's underlying into its reward through the share token:
    ///      asset into shares for the deposit queue, shares into asset for the redeem queue
    function _convert(Queue storage queue, TokenLike underlying, uint256 capacity) internal returns (uint256 converted, uint256 received) {
        uint256 unconverted = queue.unconverted;
        converted = capacity < unconverted ? capacity : unconverted;

        // Nothing to convert (empty queue or no capacity)
        if (converted == 0) return (0, 0);

        received = underlying == asset
                   ? share.deposit(converted, address(this))
                   : share.redeem(converted, address(this), address(this));

        // The reward stays in the pool, so the units keep their claim on it
        queue.unconverted = unconverted - converted;
        queue.converted  += received;
    }

    /// @notice Revalue the share by `profit` and convert both queues up to the given capacities, once per window
    function settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) external auth {
        require(_locked(), "SrUsdsQueues/not-locked");
        lastSettleDay = uint32(block.timestamp / 1 days);

        // Revalue the outstanding shares before converting at the new price
        share.settle(profit);

        // Let the held requests in, then convert both queues up to their capacity
        _admit(depositQueue);
        _admit(redeemQueue);
        (uint256 depositsConverted, uint256 depositsReceived) = _convert(depositQueue, asset, depositCapacity);
        (uint256 redeemsConverted,  uint256 redeemsReceived)  = _convert(redeemQueue, share, redeemCapacity);

        emit Settle(profit, depositCapacity, redeemCapacity, depositsConverted, depositsReceived, redeemsConverted, redeemsReceived);
    }

    // --- Internal Queue Logic ---

    /// @dev Take the position out of the queue: its share of the pool's reward is set aside as its claimable
    ///      balance and its share of the pending underlying is returned, both rounded down in favour of the pool.
    ///      Units still held are returned as they are
    function _exit(Queue storage queue, Position storage pos) internal returns (uint256 pending) {
        uint256 units = pos.units;
        if (units == 0) return 0;
        if (pos.cycle == queue.cycle) {
            queue.held -= units;
            pending = units;
        } else {
            uint256 poolUnits = queue.units;
            uint256 reward = units * queue.converted   / poolUnits;
            pending        = units * queue.unconverted / poolUnits;
            queue.units        = poolUnits - units;
            queue.converted   -= reward;
            queue.unconverted -= pending;
            pos.claimable     += reward;
        }
        pos.units = 0;
    }

    /// @dev Hold `amount` of underlying for the position (which must be out of the queue) until the next settlement
    function _hold(Queue storage queue, Position storage pos, uint256 amount) internal {
        if (amount == 0) return;
        queue.held += amount;
        pos.units = amount;
        pos.cycle = queue.cycle;
    }

    /// @dev msg.sender must be `usr` or an operator approved by `usr`
    function _checkOperator(address usr) internal view {
        require(usr == msg.sender || isOperator[usr][msg.sender], "SrUsdsQueues/not-operator");
    }

    function _request(Queue storage queue, TokenLike token, uint256 amount, address controller, address owner) internal {
        _checkOperator(owner);
        require(controller != address(0), "SrUsdsQueues/controller-zero-address");
        require(amount > 0, "SrUsdsQueues/zero-amount");
        require(!_locked(), "SrUsdsQueues/queue-locked");

        Position storage pos = queue.positions[controller];

        // Set aside what has converted and hold the new amount together with what is still pending
        _hold(queue, pos, _exit(queue, pos) + amount);

        // Escrow the queued amount from the owner
        token.transferFrom(owner, address(this), amount);
    }

    function _cancel(Queue storage queue, TokenLike token, address receiver, address controller) internal returns (uint256 amount) {
        _checkOperator(controller);
        require(receiver != address(0), "SrUsdsQueues/receiver-zero-address");
        require(!_locked(), "SrUsdsQueues/queue-locked");
        Position storage pos = queue.positions[controller];

        // Set aside what has converted and return what is still pending
        amount = _exit(queue, pos);
        require(amount > 0, "SrUsdsQueues/nothing-pending");

        token.transfer(receiver, amount);
    }

    function _claim(Queue storage queue, TokenLike token, uint256 amount, address receiver, address controller) internal returns (uint256 claimed) {
        _checkOperator(controller);
        require(receiver != address(0), "SrUsdsQueues/receiver-zero-address");
        Position storage pos = queue.positions[controller];

        // Set aside what has converted and hold what is still pending again. Totals do not change, so this is
        // fine while locked: the pending moves from the pool to the held balance of the same queue
        _hold(queue, pos, _exit(queue, pos));

        claimed = amount == type(uint256).max ? pos.claimable : amount;
        require(claimed <= pos.claimable, "SrUsdsQueues/insufficient-claimable");
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
    function queueDeposit(uint256 assets, address controller, address owner, uint16 referral) external {
        _request(depositQueue, asset, assets, controller, owner);
        emit QueueDeposit(controller, owner, msg.sender, assets);
        emit Referral(controller, assets, referral);
    }

    /// @notice Queue a redeem of `shares` taken from `owner`, credited to `controller`
    function queueRedeem(uint256 shares, address controller, address owner) external {
        _request(redeemQueue, share, shares, controller, owner);
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

    function _pending(Queue storage queue, address controller) internal view returns (uint256) {
        Position storage pos = queue.positions[controller];
        uint256 units = pos.units;
        if (units == 0) return 0;
        return pos.cycle == queue.cycle ? units : units * queue.unconverted / queue.units;
    }

    function _claimable(Queue storage queue, address controller) internal view returns (uint256) {
        Position storage pos = queue.positions[controller];
        uint256 units = pos.units;
        if (units == 0 || pos.cycle == queue.cycle) return pos.claimable;
        return pos.claimable + units * queue.converted / queue.units;
    }

    /// @notice Assets still waiting to be converted to shares
    function pendingDeposit(address controller) external view returns (uint256 assets) {
        return _pending(depositQueue, controller);
    }

    /// @notice Shares still waiting to be converted to assets
    function pendingRedeem(address controller) external view returns (uint256 shares) {
        return _pending(redeemQueue, controller);
    }

    /// @notice Shares converted from deposits and ready to claim (claimed, or left in the pool over a settlement, see above)
    function claimableDeposit(address controller) external view returns (uint256 shares) {
        return _claimable(depositQueue, controller);
    }

    /// @notice Assets converted from redeems and ready to claim (claimed, or left in the pool over a settlement, see above)
    function claimableRedeem(address controller) external view returns (uint256 assets) {
        return _claimable(redeemQueue, controller);
    }
}
