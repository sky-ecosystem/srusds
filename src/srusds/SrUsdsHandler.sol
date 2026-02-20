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

import { LCTSHandlerBase } from "src/lcts/LCTSHandlerBase.sol";

interface SrUsdsLike {
    function susds() external view returns (SUsdsLike);
    function settle(int256) external returns (uint256);
}

interface SUsdsLike {
    function usds() external view returns (UsdsLike);
    function previewMint(uint256) external view returns (uint256);
    function mint(uint256, address) external;
    function redeem(uint256, address, address) external returns (uint256);
    function approve(address, uint256) external;
}

interface UsdsLike {
    function approve(address, uint256) external;
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
        srusds  = SrUsdsLike(srusds_);
        susds   = srusds.susds();
        UsdsLike usds = susds.usds();
        usdsJoin = UsdsJoinLike(usdsJoin_);
        vat      = VatLike(usdsJoin.vat());
        vow      = vow_;

        // Approvals for settlement (chi adjustments)
        susds.approve(address(srusds), type(uint256).max);
        usds.approve(address(susds), type(uint256).max);
        usds.approve(address(usdsJoin), type(uint256).max);
        vat.hope(address(usdsJoin));
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
}
