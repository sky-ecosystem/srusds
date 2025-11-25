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

    mapping (address => uint256) public wards;
    mapping (uint256 tau => mapping (address owner => uint256 amt)) public susdsIn;
    mapping (uint256 tau => mapping (address owner => uint256 amt)) public srusdsOut;
    mapping (uint256 tau => uint256 amt) public totSusdsIn;
    mapping (uint256 tau => uint256 amt) public totSrusdsOut;
    mapping (uint256 tau =>  int256 amt) public settles;
    mapping (uint256 tau => uint256 chi) public chis;

    uint256 public hop;
    uint256 public tau;

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

    // Admin
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event InitiateDeposit(uint256 tau_, uint256 susdsAmt);
    event UndoDeposit(uint256 tau_, uint256 susdsAmt);
    event InitiateRedeem(uint256 tau_, uint256 srUsdsAmt);
    event UndoRedeem(uint256 tau_, uint256 srUsdsAmt);
    event FinishRedeem(uint256 tau_, uint256 susdsAmt);
    event FinishDeposit(uint256 tau_, uint256 srUsdsAmt);

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

    function plan(uint256 tau_, int256 amt) external auth {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        settles[tau_] = amt;
    }

    // --- User functions ---

    function settle() external {
        uint256 tau_ = tau;
        require(block.timestamp >= tau_, "SrUsdsHandler/current-tau-not-finished");

        int256 susdsAmt = settles[tau_];
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
        uint256 totSusdsIn_   = totSusdsIn[tau_];
        uint256 totSrusdsOut_ = totSrusdsOut[tau_];
        uint256 totSusdsOut_  = totSrusdsOut_ * chi / RAY;
        if (totSusdsIn_ >= totSusdsOut_) {
            srusds.deposit(totSusdsIn_ - totSusdsOut_, address(this));
        } else {
            srusds.redeem(totSrusdsOut_ - totSusdsIn_ * RAY / chi, address(this), address(this));
        }

        totSusdsIn[tau_] = totSrusdsOut[tau_] = 0; // Note: No need to update but still doing to show the value is not relevant anymore
        chis[tau_] = chi;
        tau = tau_ + hop;

        // TODO: Review if necessary an event
    }

    // Initiate sUSDS/USDS -> srUSDS path

    function initiateDepositWithSUsds(uint256 tau_, uint256 susdsAmt) external {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        require(tau_ > 0, "SrUsdsHandler/missing-init");
        susds.transferFrom(msg.sender, address(this), susdsAmt);
        susdsIn[tau_][msg.sender] += susdsAmt;
        totSusdsIn[tau_] += susdsAmt;
        emit InitiateDeposit(tau_, susdsAmt);
    }

    function initiateDepositWithUsds(uint256 tau_, uint256 usdsAmt) external {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        require(tau_ > 0, "SrUsdsHandler/missing-init");
        usds.transferFrom(msg.sender, address(this), usdsAmt);
        uint256 susdsAmt = susds.deposit(usdsAmt, address(this));
        susdsIn[tau_][msg.sender] += susdsAmt;
        totSusdsIn[tau_] += susdsAmt;
        emit InitiateDeposit(tau_, susdsAmt);
    }

    // Undo sUSDS/USDS -> srUSDS path

    function undoDepositGetSUsds(uint256 tau_, uint256 susdsAmt) external {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        susdsIn[tau_][msg.sender] -= susdsAmt;
        totSusdsIn[tau_] -= susdsAmt;
        susds.transfer(msg.sender, susdsAmt);
        emit UndoDeposit(tau_, susdsAmt);
    }

    function undoDepositGetUsds(uint256 tau_, uint256 usdsAmt) external {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        uint256 susdsAmt = susds.withdraw(usdsAmt, msg.sender, address(this));
        susdsIn[tau_][msg.sender] -= susdsAmt;
        totSusdsIn[tau_] -= susdsAmt;
        emit UndoDeposit(tau_, susdsAmt);
    }

    function undoDepositGetUsdsAll(uint256 tau_) external returns (uint256 usdsAmt) {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        uint256 susdsAmt = susdsIn[tau_][msg.sender];
        susdsIn[tau_][msg.sender] = 0;
        totSusdsIn[tau_] -= susdsAmt;
        usdsAmt = susds.redeem(susdsAmt, msg.sender, address(this));
        emit UndoDeposit(tau_, susdsAmt);
    }

    // Initiate srUSDS -> sUSDS/USDS path

    function initiateRedeem(uint256 tau_, uint256 srusdsAmt) external {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        require(tau_ > 0, "SrUsdsHandler/missing-init");
        srusds.transferFrom(msg.sender, address(this), srusdsAmt);
        srusdsOut[tau_][msg.sender] += srusdsAmt;
        totSrusdsOut[tau_] += srusdsAmt;
        emit InitiateRedeem(tau_, srusdsAmt);
    }

    // Undo srUSDS -> sUSDS/USDS path

    function undoRedeem(uint256 tau_, uint256 srusdsAmt) external {
        require(tau_ == tau, "SrUsdsHandler/not-current-tau");
        srusdsOut[tau_][msg.sender] -= srusdsAmt;
        totSrusdsOut[tau_] -= srusdsAmt;
        srusds.transfer(msg.sender, srusdsAmt);
        emit UndoRedeem(tau_, srusdsAmt);
    }

    // Finish sUSDS/USDS -> srUSDS path

    function finishDeposit(uint256 tau_) external returns (uint256 srusdsAmt) {
        require(tau_ < tau, "SrUsdsHandler/current-tau");
        uint256 susdsIn_ = susdsIn[tau_][msg.sender];
        require(susdsIn_ > 0, "SrUsdsHandler/no-susdsIn-available");
        susdsIn[tau_][msg.sender] = 0;
        srusdsAmt = susdsIn_ * RAY / chis[tau_];
        srusds.transfer(msg.sender, srusdsAmt);
        emit FinishDeposit(tau_, srusdsAmt);
    }

    // Finish srUSDS -> sUSDS/USDS path

    function finishRedeemGetSUsds(uint256 tau_) external returns (uint256 susdsAmt) {
        require(tau_ < tau, "SrUsdsHandler/current-tau");
        uint256 srusdsAmt = srusdsOut[tau_][msg.sender];
        require(srusdsAmt > 0, "SrUsdsHandler/no-srusdsOut-available");
        srusdsOut[tau_][msg.sender] = 0;
        susdsAmt = srusdsAmt * chis[tau_] / RAY;
        susds.transfer(msg.sender, srusdsAmt * chis[tau_] / RAY);
        emit FinishRedeem(tau_, susdsAmt);
    }

    function finishRedeemGetUsds(uint256 tau_) external returns (uint256 usdsAmt) {
        require(tau_ < tau, "SrUsdsHandler/current-tau");
        uint256 srusdsAmt = srusdsOut[tau_][msg.sender];
        require(srusdsAmt > 0, "SrUsdsHandler/no-srusdsOut-available");
        srusdsOut[tau_][msg.sender] = 0;
        uint256 susdsAmt = srusdsAmt * chis[tau_] / RAY;
        usdsAmt = susds.redeem(susdsAmt, msg.sender, address(this));
        emit FinishRedeem(tau_, susdsAmt);
    }
}
