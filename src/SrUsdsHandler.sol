// SPDX-License-Identifier: AGPL-3.0-or-later

/// SrUsdsHandler.sol -- Handler for srUSDS cycles with LCTS queue integration

// Copyright (C) 2017, 2018, 2019 dbrock, rain, mrchico
// Copyright (C) 2021 Dai Foundation
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

interface SrUsdsLike {
    function susds() external view returns (SUsdsLike);
    function settle(int256) external returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface SUsdsLike {
    function usds() external view returns (UsdsLike);
    function previewMint(uint256) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function approve(address, uint256) external;
    function mint(uint256, address) external;
    function redeem(uint256, address, address) external returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface UsdsLike {
    function approve(address, uint256) external;
    function transferFrom(address, address, uint256) external returns (bool);
}

interface UsdsJoinLike {
    function vat() external view returns (address);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

interface VatLike {
    function hope(address) external;
    function suck(address, address, uint256) external;
}

interface LCTSDepositQueueLike {
    function deposit(uint256 assets, address receiver) external;
    function claim(address user, address to) external returns (uint256 vaultShares);
    function claimAndExit(address user, address to) external returns (uint256 assets, uint256 vaultShares);
    function settle(uint256 capacity) external returns (uint256);
}

interface LCTSWithdrawQueueLike {
    function deposit(uint256 vaultShares, address receiver) external;
    function claim(address user, address to) external returns (uint256 assets);
    function claimAndExit(address user, address to) external returns (uint256 vaultShares, uint256 assets);
    function settle(uint256 capacity) external returns (uint256);
}

contract SrUsdsHandler {

    // --- Storage Variables ---

    mapping (address usr => uint256 allowed) public wards;
    mapping (uint256 cId => Cycle cycle) public cycles;
    uint256 public cCId; // Current Cycle Id
    uint256 public hop;

    struct Cycle {
        uint256 end;              // Cycle end timestamp
        int256  settleAmt;        // Amount to settle (affects chi)
        uint256 depositCapacity;  // Capacity for deposit queue this cycle
        uint256 withdrawCapacity; // Capacity for withdraw queue this cycle
        uint256 chi;              // Chi at settlement
    }

    // --- Immutables ---

    SrUsdsLike            public immutable srusds;
    SUsdsLike             public immutable susds;
    UsdsLike              public immutable usds;
    UsdsJoinLike          public immutable usdsJoin;
    VatLike               public immutable vat;
    address               public immutable vow;
    LCTSDepositQueueLike  public immutable depositQueue;
    LCTSWithdrawQueueLike public immutable withdrawQueue;

    // --- Constants ---

    uint256 public constant RAY = 10**27;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Init(uint256 end);
    event Update(uint256 indexed cId, uint256 end);
    event Plan(uint256 indexed cId, int256 settleAmt, uint256 depositCapacity, uint256 withdrawCapacity);
    event Settle(uint256 indexed cId, uint256 chi, uint256 depositsConverted, uint256 withdrawsConverted);
    event DepositUsds(uint256 indexed cId, address indexed receiver, uint256 usdsAmt, uint256 susdsAmt);
    event DepositSusds(uint256 indexed cId, address indexed receiver, uint256 susdsAmt);
    event ClaimDeposit(uint256 indexed cId, address indexed to, uint256 srUsdsAmt);
    event ExitDeposit(uint256 indexed cId, address indexed to, uint256 susdsAmt, uint256 srUsdsAmt);
    event Redeem(uint256 indexed cId, address indexed receiver, uint256 srUsdsAmt);
    event ClaimRedeem(uint256 indexed cId, address indexed to, uint256 susdsAmt);
    event ExitRedeem(uint256 indexed cId, address indexed to, uint256 srUsdsAmt, uint256 susdsAmt);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "SrUsdsHandler/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(
        address srusds_,
        address usdsJoin_,
        address vow_,
        address depositQueue_,
        address withdrawQueue_
    ) {
        srusds = SrUsdsLike(srusds_);
        susds = srusds.susds();
        usds = susds.usds();
        usdsJoin = UsdsJoinLike(usdsJoin_);
        vat = VatLike(usdsJoin.vat());
        vow = vow_;
        depositQueue = LCTSDepositQueueLike(depositQueue_);
        withdrawQueue = LCTSWithdrawQueueLike(withdrawQueue_);

        // Approvals for settlement (chi adjustments)
        susds.approve(address(srusds), type(uint256).max);
        usds.approve(address(susds), type(uint256).max);
        usds.approve(address(usdsJoin), type(uint256).max);
        vat.hope(address(usdsJoin));

        // Approvals for user-facing deposit queue operations
        susds.approve(depositQueue_, type(uint256).max);

        // Approvals for user-facing withdraw queue operations
        srusds.approve(withdrawQueue_, type(uint256).max);

        wards[msg.sender] = 1;

        emit Rely(msg.sender);
    }

    // --- Admin functions ---

    function rely(address usr) external auth {
        wards[usr] = 1;

        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;

        emit Deny(usr);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "hop") {
            hop = data;
        } else revert("SrUsdsHandler/file-unrecognized-param");

        emit File(what, data);
    }

    function init(uint256 end) external auth {
        require(cCId == 0, "SrUsdsHandler/already-init");
        require(end > block.timestamp, "SrUsdsHandler/end-too-soon");

        cycles[++cCId].end = end;

        emit Init(end);
    }

    function update(uint256 cId, uint256 end) external auth {
        require(cId == cCId, "SrUsdsHandler/not-current-cycle");
        require(end >= block.timestamp, "SrUsdsHandler/end-past");

        cycles[cId].end = end;

        emit Update(cId, end);
    }

    /// @notice Plan the settlement parameters for a cycle
    /// @param cId Cycle ID (must be current cycle)
    /// @param settleAmt Amount of sUSDS to add (positive) or remove (negative) from srUSDS backing
    /// @param depositCapacity_ Maximum sUSDS to convert to srUSDS via deposit queue
    /// @param withdrawCapacity_ Maximum srUSDS to convert to sUSDS via withdraw queue
    function plan(
        uint256 cId,
        int256 settleAmt,
        uint256 depositCapacity_,
        uint256 withdrawCapacity_
    ) external auth {
        require(cId == cCId, "SrUsdsHandler/not-current-cycle");

        Cycle storage c = cycles[cId];
        c.settleAmt = settleAmt;
        c.depositCapacity = depositCapacity_;
        c.withdrawCapacity = withdrawCapacity_;

        emit Plan(cId, settleAmt, depositCapacity_, withdrawCapacity_);
    }

    // --- View functions ---

    /// @notice Get the end timestamp of the current cycle
    /// @return End timestamp (used by Settler for timing checks)
    function tau() external view returns (uint256) {
        return cycles[cCId].end;
    }

    /// @notice Get cycle details
    /// @param cId Cycle ID
    /// @return end Cycle end timestamp
    /// @return settleAmt Settlement amount
    /// @return depositCapacity Deposit queue capacity
    /// @return withdrawCapacity Withdraw queue capacity
    /// @return chi Chi value at settlement (0 if not yet settled)
    function getCycle(uint256 cId) external view returns (
        uint256 end,
        int256 settleAmt,
        uint256 depositCapacity,
        uint256 withdrawCapacity,
        uint256 chi
    ) {
        Cycle storage c = cycles[cId];
        return (c.end, c.settleAmt, c.depositCapacity, c.withdrawCapacity, c.chi);
    }

    // --- User Deposit Functions (USDS/sUSDS -> srUSDS via queue) ---

    /// @notice Deposit USDS to the deposit queue (converts to sUSDS internally)
    /// @param cId Cycle ID (must be current cycle)
    /// @param usdsAmt Amount of USDS to deposit
    /// @param receiver Address to receive queue position
    function depositUsds(uint256 cId, uint256 usdsAmt, address receiver) external {
        require(cId == cCId, "SrUsdsHandler/not-current-cycle");
        usds.transferFrom(msg.sender, address(this), usdsAmt);
        uint256 susdsAmt = susds.deposit(usdsAmt, address(this));
        depositQueue.deposit(susdsAmt, receiver);
        emit DepositUsds(cId, receiver, usdsAmt, susdsAmt);
    }

    /// @notice Deposit sUSDS directly to the deposit queue
    /// @param cId Cycle ID (must be current cycle)
    /// @param susdsAmt Amount of sUSDS to deposit
    /// @param receiver Address to receive queue position
    function depositSusds(uint256 cId, uint256 susdsAmt, address receiver) external {
        require(cId == cCId, "SrUsdsHandler/not-current-cycle");
        susds.transferFrom(msg.sender, address(this), susdsAmt);
        depositQueue.deposit(susdsAmt, receiver);
        emit DepositSusds(cId, receiver, susdsAmt);
    }

    /// @notice Claim srUSDS rewards from deposit queue
    /// @param to Address to receive srUSDS
    /// @return srUsdsAmt Amount of srUSDS claimed
    function claimDeposit(address to) external returns (uint256 srUsdsAmt) {
        srUsdsAmt = depositQueue.claim(msg.sender, to);
        emit ClaimDeposit(cCId, to, srUsdsAmt);
    }

    /// @notice Claim and exit deposit queue, receive sUSDS + srUSDS
    /// @param to Address to receive assets
    /// @return susdsAmt Amount of sUSDS returned (unconverted)
    /// @return srUsdsAmt Amount of srUSDS claimed (converted rewards)
    function claimDepositAndExitAsSusds(address to) external returns (uint256 susdsAmt, uint256 srUsdsAmt) {
        (susdsAmt, srUsdsAmt) = depositQueue.claimAndExit(msg.sender, to);
        emit ExitDeposit(cCId, to, susdsAmt, srUsdsAmt);
    }

    /// @notice Claim and exit deposit queue, receive USDS + srUSDS (converts sUSDS to USDS)
    /// @param to Address to receive assets
    /// @return usdsAmt Amount of USDS returned (unconverted, converted from sUSDS)
    /// @return srUsdsAmt Amount of srUSDS claimed (converted rewards)
    function claimDepositAndExitAsUsds(address to) external returns (uint256 usdsAmt, uint256 srUsdsAmt) {
        uint256 susdsAmt;
        (susdsAmt, srUsdsAmt) = depositQueue.claimAndExit(msg.sender, address(this));
        if (susdsAmt > 0) {
            usdsAmt = susds.redeem(susdsAmt, to, address(this));
        }
        if (srUsdsAmt > 0) {
            srusds.transfer(to, srUsdsAmt);
        }
        emit ExitDeposit(cCId, to, susdsAmt, srUsdsAmt);
    }

    // --- User Redeem Functions (srUSDS -> sUSDS/USDS via queue) ---

    /// @notice Queue srUSDS for redemption
    /// @param cId Cycle ID (must be current cycle)
    /// @param srUsdsAmt Amount of srUSDS to queue for redemption
    /// @param receiver Address to receive queue position
    function redeem(uint256 cId, uint256 srUsdsAmt, address receiver) external {
        require(cId == cCId, "SrUsdsHandler/not-current-cycle");
        srusds.transferFrom(msg.sender, address(this), srUsdsAmt);
        withdrawQueue.deposit(srUsdsAmt, receiver);
        emit Redeem(cId, receiver, srUsdsAmt);
    }

    /// @notice Claim sUSDS from redeem queue
    /// @param to Address to receive sUSDS
    /// @return susdsAmt Amount of sUSDS claimed
    function claimRedeemAsSusds(address to) external returns (uint256 susdsAmt) {
        susdsAmt = withdrawQueue.claim(msg.sender, to);
        emit ClaimRedeem(cCId, to, susdsAmt);
    }

    /// @notice Claim USDS from redeem queue (converts sUSDS to USDS)
    /// @param to Address to receive USDS
    /// @return usdsAmt Amount of USDS claimed
    function claimRedeemAsUsds(address to) external returns (uint256 usdsAmt) {
        uint256 susdsAmt = withdrawQueue.claim(msg.sender, address(this));
        if (susdsAmt > 0) {
            usdsAmt = susds.redeem(susdsAmt, to, address(this));
        }
        emit ClaimRedeem(cCId, to, susdsAmt);
    }

    /// @notice Claim and exit redeem queue, receive srUSDS + sUSDS
    /// @param to Address to receive assets
    /// @return srUsdsAmt Amount of srUSDS returned (unconverted)
    /// @return susdsAmt Amount of sUSDS claimed (converted rewards)
    function claimRedeemAsSusdsAndExit(address to) external returns (uint256 srUsdsAmt, uint256 susdsAmt) {
        (srUsdsAmt, susdsAmt) = withdrawQueue.claimAndExit(msg.sender, to);
        emit ExitRedeem(cCId, to, srUsdsAmt, susdsAmt);
    }

    /// @notice Claim and exit redeem queue, receive srUSDS + USDS (converts sUSDS to USDS)
    /// @param to Address to receive assets
    /// @return srUsdsAmt Amount of srUSDS returned (unconverted)
    /// @return usdsAmt Amount of USDS claimed (converted from sUSDS)
    function claimRedeemAsUsdsAndExit(address to) external returns (uint256 srUsdsAmt, uint256 usdsAmt) {
        uint256 susdsAmt;
        (srUsdsAmt, susdsAmt) = withdrawQueue.claimAndExit(msg.sender, address(this));
        if (susdsAmt > 0) {
            usdsAmt = susds.redeem(susdsAmt, to, address(this));
        }
        if (srUsdsAmt > 0) {
            srusds.transfer(to, srUsdsAmt);
        }
        emit ExitRedeem(cCId, to, srUsdsAmt, susdsAmt);
    }

    // --- Settlement ---

    /// @notice Settle the current cycle
    /// @param cId Cycle ID (must be current cycle and past end time)
    /// @dev 1. Adjusts srUSDS chi based on settleAmt
    ///      2. Processes deposit queue conversions (sUSDS → srUSDS)
    ///      3. Processes withdraw queue conversions (srUSDS → sUSDS)
    ///      4. Advances to next cycle
    function settle(uint256 cId) external {
        require(cId > 0, "SrUsdsHandler/not-init");
        require(cId == cCId, "SrUsdsHandler/not-current-cycle");
        Cycle storage c = cycles[cId];
        require(block.timestamp >= c.end, "SrUsdsHandler/current-cycle-not-finished");

        int256 settleAmt_ = c.settleAmt;

        // Step 1: Handle settleAmt - mint or burn sUSDS to adjust chi
        if (settleAmt_ > 0) {
            // Mint sUSDS: suck USDS from vat, convert to sUSDS
            uint256 usdsAmt = susds.previewMint(uint256(settleAmt_));
            vat.suck(address(this), address(this), usdsAmt * RAY);
            usdsJoin.exit(address(this), usdsAmt);
            susds.mint(uint256(settleAmt_), address(this));
        }

        // Step 2: Update chi on srUSDS (this is based on current supply, before queue processing)
        uint256 chi = srusds.settle(settleAmt_);

        // Step 3: Handle negative settleAmt - burn sUSDS after chi update
        if (settleAmt_ < 0) {
            uint256 usdsAmt = susds.redeem(uint256(-settleAmt_), address(this), address(this));
            usdsJoin.join(vow, usdsAmt);
        }

        // Step 4: Process LCTS queues with the new chi
        // Deposit queue: sUSDS → srUSDS (users deposited sUSDS, receive srUSDS)
        uint256 depositsConverted = depositQueue.settle(c.depositCapacity);

        // Withdraw queue: srUSDS → sUSDS (users deposited srUSDS, receive sUSDS)
        uint256 withdrawsConverted = withdrawQueue.settle(c.withdrawCapacity);

        // Step 5: Record chi and advance cycle
        c.chi = chi;
        cycles[++cCId].end = c.end + hop;

        emit Settle(cId, chi, depositsConverted, withdrawsConverted);
    }
}
