// SPDX-License-Identifier: AGPL-3.0-or-later

/// SrUsdsHandler.sol -- srUSDS settlement cycle handler

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

import { LCTSHandlerBase } from "src/LCTSHandlerBase.sol";

interface SrUsdsLike {
    function susds() external view returns (SUsdsLike);
    function settle(int256) external returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

interface SUsdsLike {
    function usds() external view returns (UsdsLike);
    function previewMint(uint256) external view returns (uint256);
    function mint(uint256, address) external;
    function redeem(uint256, address, address) external returns (uint256);
    function approve(address, uint256) external;
    function deposit(uint256, address) external returns (uint256);
    function transferFrom(address, address, uint256) external;
}

interface UsdsLike {
    function approve(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

interface LCTSQueueLike {
    function deposit(uint256, address) external;
    function claim(address, address) external returns (uint256);
    function claimAndExit(address, address) external returns (uint256, uint256);
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

contract SrUsdsHandler is LCTSHandlerBase {

    // --- Immutables ---

    SrUsdsLike   public immutable srusds;
    SUsdsLike    public immutable susds;
    UsdsLike     public immutable usds;
    UsdsJoinLike public immutable usdsJoin;
    VatLike      public immutable vat;
    address      public immutable vow;

    // --- Constants ---

    uint256 public constant RAY = 10**27;

    // --- Constructor ---

    constructor(
        address srusds_,
        address usdsJoin_,
        address vow_,
        address depositQueue_,
        address withdrawQueue_
    ) LCTSHandlerBase(depositQueue_, withdrawQueue_) {
        srusds   = SrUsdsLike(srusds_);
        susds    = srusds.susds();
        usds     = susds.usds();
        usdsJoin = UsdsJoinLike(usdsJoin_);
        vat      = VatLike(usdsJoin.vat());
        vow      = vow_;

        // Approvals for settlement (chi adjustments)
        susds.approve(address(srusds), type(uint256).max);
        usds.approve(address(susds), type(uint256).max);
        usds.approve(address(usdsJoin), type(uint256).max);
        vat.hope(address(usdsJoin));

        // Approvals for queue token pulls
        susds.approve(depositQueue_, type(uint256).max);
        srusds.approve(withdrawQueue_, type(uint256).max);
    }

    // --- Internal Hooks ---

    /// @dev Adjust srUSDS chi based on settleAmt before queue processing
    function _settle() internal override {
        int256 settleAmt_ = settleAmt;

        // Mint sUSDS: suck USDS from vat, convert to sUSDS
        if (settleAmt_ > 0) {
            uint256 usdsAmt = susds.previewMint(uint256(settleAmt_));
            vat.suck(address(this), address(this), usdsAmt * RAY);
            usdsJoin.exit(address(this), usdsAmt);
            susds.mint(uint256(settleAmt_), address(this));
        }

        // Update chi on srUSDS
        srusds.settle(settleAmt_);

        // Burn sUSDS: redeem to USDS, join back to vat
        if (settleAmt_ < 0) {
            uint256 usdsAmt = susds.redeem(uint256(-settleAmt_), address(this), address(this));
            usdsJoin.join(vow, usdsAmt);
        }
    }

    // --- Deposit Queue User Functions ---

    function depositUsds(uint256 usdsAmt, address receiver) external {
        usds.transferFrom(msg.sender, address(this), usdsAmt);
        uint256 susdsAmt = susds.deposit(usdsAmt, address(this));
        LCTSQueueLike(depositQueue).deposit(susdsAmt, receiver);
    }

    function depositSusds(uint256 susdsAmt, address receiver) external {
        susds.transferFrom(msg.sender, address(this), susdsAmt);
        LCTSQueueLike(depositQueue).deposit(susdsAmt, receiver);
    }

    function claimSrUsds(address to) external {
        LCTSQueueLike(depositQueue).claim(msg.sender, to);
    }

    function claimSrUsdsAndExitSusds(address to) external {
        LCTSQueueLike(depositQueue).claimAndExit(msg.sender, to);
    }

    function claimSrUsdsAndExitUsds(address to) external {
        (uint256 susdsOut, uint256 srUsdsOut) = LCTSQueueLike(depositQueue).claimAndExit(msg.sender, address(this));
        if (susdsOut  > 0) susds.redeem(susdsOut, to, address(this));
        if (srUsdsOut > 0) srusds.transfer(to, srUsdsOut);
    }

    // --- Withdraw Queue User Functions ---

    function depositSrUsds(uint256 srUsdsAmt, address to) external {
        srusds.transferFrom(msg.sender, address(this), srUsdsAmt);
        LCTSQueueLike(withdrawQueue).deposit(srUsdsAmt, to);
    }

    function claimSusds(address to) external {
        LCTSQueueLike(withdrawQueue).claim(msg.sender, to);
    }

    function claimUsds(address to) external {
        uint256 susdsOut = LCTSQueueLike(withdrawQueue).claim(msg.sender, address(this));
        if (susdsOut > 0) susds.redeem(susdsOut, to, address(this));
    }

    function claimSusdsAndExitSrUsds(address to) external {
        LCTSQueueLike(withdrawQueue).claimAndExit(msg.sender, to);
    }

    function claimUsdsAndExitSrUsds(address to) external {
        (uint256 srUsdsOut, uint256 susdsOut) = LCTSQueueLike(withdrawQueue).claimAndExit(msg.sender, address(this));
        if (susdsOut  > 0) susds.redeem(susdsOut, to, address(this));
        if (srUsdsOut > 0) srusds.transfer(to, srUsdsOut);
    }
}
