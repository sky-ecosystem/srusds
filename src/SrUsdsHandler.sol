// SPDX-License-Identifier: AGPL-3.0-or-later

/// SrUsds.sol

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
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
    function deposit(uint256, address) external;
    function redeem(uint256, address, address) external;
}

interface SUsdsLike {
    function usds() external view returns (UsdsLike);
    function previewMint(uint256) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
    function deposit(uint256, address) external returns (uint256);
    function mint(uint256, address) external;
    function redeem(uint256, address, address) external returns (uint256);
    function withdraw(uint256, address, address) external returns (uint256);
}

interface UsdsLike {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
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

contract SrUsdsHandler {

    // --- Storage Variables ---

    mapping (address usr => uint256 allowed) public wards;
    mapping (uint256 cId => Cycle cycle) public cycles;
    uint256 public cCId; // Current Cycle Id
    uint256 public hop;

    struct Cycle {
        uint256 end;
        mapping (address owner => uint256 amt) susdsIn;
        mapping (address owner => uint256 amt) srusdsOut;
        uint256 totSusdsIn;
        uint256 totSrusdsOut;
        int256  settleAmt;
        uint256 chi;
    }

    // --- Immutables ---

    SrUsdsLike   public immutable srusds;
    SUsdsLike    public immutable susds;
    UsdsLike     public immutable usds;
    UsdsJoinLike public immutable usdsJoin;
    VatLike      public immutable vat;
    address      public immutable vow;

    // --- Constants ---

    uint256 public constant RAY = 10**27;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Init(uint256 end);
    event Update         (uint256 indexed cId, uint256 end);
    event Plan           (uint256 indexed cId,  int256 susdsAmt);
    event InitiateDeposit(uint256 indexed cId, uint256 susdsAmt);
    event UndoDeposit    (uint256 indexed cId, uint256 susdsAmt,  address to);
    event InitiateRedeem (uint256 indexed cId, uint256 srUsdsAmt);
    event UndoRedeem     (uint256 indexed cId, uint256 srUsdsAmt, address to);
    event Settle         (uint256 indexed cId);
    event FinishRedeem   (uint256 indexed cId, uint256 susdsAmt,  address to);
    event FinishDeposit  (uint256 indexed cId, uint256 srUsdsAmt, address to);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "SrUsdsHandler/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address srusds_, address usdsJoin_, address vow_) {
        srusds = SrUsdsLike(srusds_);
        susds = srusds.susds();
        usds = susds.usds();
        usdsJoin = UsdsJoinLike(usdsJoin_);
        vat = VatLike(usdsJoin.vat());
        vow = vow_;

        susds.approve(address(srusds), type(uint256).max);
        usds.approve(address(susds), type(uint256).max);
        usds.approve(address(usdsJoin), type(uint256).max);
        vat.hope(address(usdsJoin));

        wards[msg.sender] = 1;

        emit Rely(msg.sender);
    }

    // --- Internals ---

    function _max(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x > y ? x : y;
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
        require(cCId == 0);
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

    function plan(uint256 cId, int256 susdsAmt) external auth {
        require(cId == cCId, "SrUsdsHandler/not-current-cycle");

        cycles[cId].settleAmt = susdsAmt;

        emit Plan(cId, susdsAmt);
    }

    // --- User functions ---

    // Initiate sUSDS/USDS -> srUSDS path

    function initiateDepositWithSUsds(uint256 cId, uint256 susdsAmt) external {
        require(cId > 0, "SrUsdsHandler/not-init");
        require(cId == cCId, "SrUsdsHandler/not-current-cId");

        susds.transferFrom(msg.sender, address(this), susdsAmt);
        cycles[cId].susdsIn[msg.sender] += susdsAmt;
        cycles[cId].totSusdsIn += susdsAmt;

        emit InitiateDeposit(cId, susdsAmt);
    }

    function initiateDepositWithUsds(uint256 cId, uint256 usdsAmt) external {
        require(cId > 0, "SrUsdsHandler/not-init");
        require(cId == cCId, "SrUsdsHandler/not-current-cId");

        usds.transferFrom(msg.sender, address(this), usdsAmt);
        uint256 susdsAmt = susds.deposit(usdsAmt, address(this));
        cycles[cId].susdsIn[msg.sender] += susdsAmt;
        cycles[cId].totSusdsIn += susdsAmt;

        emit InitiateDeposit(cId, susdsAmt);
    }

    // Undo sUSDS/USDS -> srUSDS path

    function undoDepositGetSUsds(uint256 cId, uint256 susdsAmt, address to) external {
        require(cId == cCId, "SrUsdsHandler/not-current-cId");

        cycles[cId].susdsIn[msg.sender] -= susdsAmt;
        cycles[cId].totSusdsIn -= susdsAmt;
        susds.transfer(to, susdsAmt);

        emit UndoDeposit(cId, susdsAmt, to);
    }

    function undoDepositGetUsds(uint256 cId, uint256 usdsAmt, address to) external {
        require(cId == cCId, "SrUsdsHandler/not-current-cId");

        uint256 susdsAmt = susds.withdraw(usdsAmt, to, address(this));
        cycles[cId].susdsIn[msg.sender] -= susdsAmt;
        cycles[cId].totSusdsIn -= susdsAmt;

        emit UndoDeposit(cId, susdsAmt, to);
    }

    function undoDepositGetUsdsAll(uint256 cId, address to) external returns (uint256 usdsAmt) {
        require(cId == cCId, "SrUsdsHandler/not-current-cId");

        uint256 susdsAmt = cycles[cId].susdsIn[msg.sender];
        cycles[cId].susdsIn[msg.sender] = 0;
        cycles[cId].totSusdsIn -= susdsAmt;
        usdsAmt = susds.redeem(susdsAmt, to, address(this));

        emit UndoDeposit(cId, susdsAmt, to);
    }

    // Initiate srUSDS -> sUSDS/USDS path

    function initiateRedeem(uint256 cId, uint256 srusdsAmt) external {
        require(cId > 0, "SrUsdsHandler/not-init");
        require(cId == cCId, "SrUsdsHandler/not-current-cId");

        srusds.transferFrom(msg.sender, address(this), srusdsAmt);
        cycles[cId].srusdsOut[msg.sender] += srusdsAmt;
        cycles[cId].totSrusdsOut += srusdsAmt;

        emit InitiateRedeem(cId, srusdsAmt);
    }

    // Undo srUSDS -> sUSDS/USDS path

    function undoRedeem(uint256 cId, uint256 srusdsAmt, address to) external {
        require(cId == cCId, "SrUsdsHandler/not-current-cId");
        cycles[cId].srusdsOut[msg.sender] -= srusdsAmt;
        cycles[cId].totSrusdsOut -= srusdsAmt;
        srusds.transfer(to, srusdsAmt);
        emit UndoRedeem(cId, srusdsAmt, to);
    }

    // Settle cycle and free up to finish deposits and redeems

    function settle(uint256 cId) external {
        require(cId > 0, "SrUsdsHandler/not-init");
        require(cId == cCId, "SrUsdsHandler/not-current-cId");
        uint256 end = cycles[cId].end;
        require(block.timestamp >= end, "SrUsdsHandler/current-cycle-not-finished");

        int256 susdsAmt = cycles[cId].settleAmt;
        if (susdsAmt > 0) {
            uint256 usdsAmt = susds.previewMint(uint256(susdsAmt));
            vat.suck(address(this), address(this), usdsAmt * RAY);
            usdsJoin.exit(address(this), usdsAmt);
            susds.mint(uint256(susdsAmt), address(this));
        }
        uint256 chi = srusds.settle(susdsAmt);
        // TODO: Find the best way to fix the possibility that susdAmt might be lower (due how srusds works)
        if (susdsAmt < 0) {
            uint256 usdsAmt = susds.redeem(uint256(-susdsAmt), address(this), address(this));
            usdsJoin.join(vow, usdsAmt);
        }

        // TODO: Review roundings
        uint256 totSusdsIn_   = cycles[cId].totSusdsIn;
        uint256 totSrusdsOut_ = cycles[cId].totSrusdsOut;
        uint256 totSusdsOut_  = totSrusdsOut_ * chi / RAY;
        if (totSusdsIn_ >= totSusdsOut_) {
            srusds.deposit(totSusdsIn_ - totSusdsOut_, address(this));
        } else {
            srusds.redeem(totSrusdsOut_ - totSusdsIn_ * RAY / chi, address(this), address(this));
        }

        cycles[cId].chi = chi;
        cycles[++cCId].end = end + hop;

        emit Settle(cId);
    }

    // Finish sUSDS/USDS -> srUSDS path

    function finishDeposit(uint256 cId, address to) external returns (uint256 srusdsAmt) {
        require(cId < cCId, "SrUsdsHandler/not-prev-cId");
        uint256 susdsIn_ = cycles[cId].susdsIn[msg.sender];
        require(susdsIn_ > 0, "SrUsdsHandler/no-susdsIn-available");

        cycles[cId].susdsIn[msg.sender] = 0;
        cycles[cId].totSusdsIn -= susdsIn_;
        srusdsAmt = susdsIn_ * RAY / cycles[cId].chi;
        srusds.transfer(to, srusdsAmt);

        emit FinishDeposit(cId, srusdsAmt, to);
    }

    // Finish srUSDS -> sUSDS/USDS path

    function finishRedeemGetSUsds(uint256 cId, address to) external returns (uint256 susdsAmt) {
        require(cId < cCId, "SrUsdsHandler/not-prev-cId");
        uint256 srusdsAmt = cycles[cId].srusdsOut[msg.sender];
        require(srusdsAmt > 0, "SrUsdsHandler/no-srusdsOut-available");

        cycles[cId].srusdsOut[msg.sender] = 0;
        cycles[cId].totSrusdsOut -= srusdsAmt;
        susdsAmt = srusdsAmt * cycles[cId].chi / RAY;
        susds.transfer(to, susdsAmt);

        emit FinishRedeem(cId, susdsAmt, to);
    }

    function finishRedeemGetUsds(uint256 cId, address to) external returns (uint256 usdsAmt) {
        require(cId < cCId, "SrUsdsHandler/not-prev-cId");
        uint256 srusdsAmt = cycles[cId].srusdsOut[msg.sender];
        require(srusdsAmt > 0, "SrUsdsHandler/no-srusdsOut-available");

        cycles[cId].srusdsOut[msg.sender] = 0;
        cycles[cId].totSrusdsOut -= srusdsAmt;
        uint256 susdsAmt = srusdsAmt * cycles[cId].chi / RAY;
        usdsAmt = susds.redeem(susdsAmt, to, address(this));

        emit FinishRedeem(cId, susdsAmt, to);
    }
}
