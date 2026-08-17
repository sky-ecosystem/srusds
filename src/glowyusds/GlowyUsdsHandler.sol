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

// TODO(glowyusds): RENAME PENDING. Fork of src/shinyusds/ so that
// `diff src/shinyusds/ShinyUsdsHandler.sol src/glowyusds/GlowyUsdsHandler.sol` shows the functional
// delta and nothing else. Every srUSDS identifier below is intentionally UNCHANGED. Rename the
// whole tree to glowyUSDS once the functional diff has been reviewed. Handler is UNCHANGED
// from shinyusds: the rate lives entirely in the token.
//
// Functional differences from src/srusds/SrUsdsHandler.sol:
//   1. No vat backstop. srUSDS is no longer funded by sucking USDS from the Vat and minting
//      sUSDS into it; backing comes from an external asset manager (the Diamond PAU), which
//      pulls via SrUsds.take() and returns by plain sUSDS transfer. vat, usdsJoin, vow, RAY,
//      VatLike and UsdsJoinLike are therefore all gone, and the constructor loses two args.
//   2. _settle() is accounting only -- it just marks chi.
//
// All ten user-facing queue functions are unchanged.

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
    function claimAndJoin(address, address, uint256) external returns (uint256);
    function claimAndExit(address, address, address) external returns (uint256, uint256);
    function claim(address, address) external returns (uint256);
}

contract SrUsdsHandler is LCTSHandlerBase {

    // --- Immutables ---

    SrUsdsLike public immutable srusds;
    SUsdsLike  public immutable susds;
    UsdsLike   public immutable usds;

    // --- Constructor ---

    constructor(
        address srusds_,
        address depositQueue_,
        address withdrawQueue_
    ) LCTSHandlerBase(depositQueue_, withdrawQueue_) {
        srusds = SrUsdsLike(srusds_);
        susds  = srusds.susds();
        usds   = susds.usds();

        // Approval for the USDS -> sUSDS leg of the user join functions
        usds.approve(address(susds), type(uint256).max);

        // Approvals for queue token pulls
        susds.approve(depositQueue_, type(uint256).max);
        srusds.approve(withdrawQueue_, type(uint256).max);
    }

    // --- Internal Hooks ---

    /// @dev Adjust srUSDS chi based on settleAmt before queue processing.
    ///
    ///      Accounting only -- no assets move here. Backing is deployed and returned by the
    ///      asset manager out of band: it pulls via take() and returns by plain sUSDS transfer
    ///      to the token. settle() records the resulting gain or loss.
    ///
    ///      Before settle() runs, the asset manager must have returned enough backing to cover
    ///      the cycle's withdrawCapacity, otherwise the withdraw queue's redeem will revert
    ///      against a short token and the whole settlement is lost.
    function _settle() internal override {
        int256 settleAmt_ = settleAmt;

        // Update chi on srUSDS. Skipped when there is nothing to mark, so the first cycle can
        // run before any shares exist.
        if (settleAmt_ != 0) srusds.settle(settleAmt_);
    }

    // --- Deposit Queue User Functions ---

    function claimSrUsdsAndJoinSusds(address rewardsTo, uint256 susdsAmt) external returns (uint256 srUsdsAmt) {
        susds.transferFrom(msg.sender, address(this), susdsAmt);
        srUsdsAmt = LCTSQueueLike(depositQueue).claimAndJoin(msg.sender, rewardsTo, susdsAmt);
    }

    function claimSrUsdsAndJoinUsds(address rewardsTo, uint256 usdsAmt) external returns (uint256 srUsdsAmt) {
        usds.transferFrom(msg.sender, address(this), usdsAmt);
        uint256 susdsAmt = susds.deposit(usdsAmt, address(this));
        srUsdsAmt = LCTSQueueLike(depositQueue).claimAndJoin(msg.sender, rewardsTo, susdsAmt);
    }

    function claimSrUsdsAndExitSusds(address rewardsTo, address underlyingTo) external returns (uint256 srUsdsAmt, uint256 sUsdsAmt) {
        (srUsdsAmt, sUsdsAmt) = LCTSQueueLike(depositQueue).claimAndExit(msg.sender, rewardsTo, underlyingTo);
    }

    function claimSrUsdsAndExitUsds(address rewardsTo, address underlyingTo) external returns (uint256 srUsdsAmt, uint256 usdsAmt) {
        uint256 sUsdsAmt;
        (srUsdsAmt, sUsdsAmt) = LCTSQueueLike(depositQueue).claimAndExit(msg.sender, rewardsTo, address(this));
        if (sUsdsAmt > 0) usdsAmt = susds.redeem(sUsdsAmt, underlyingTo, address(this));
    }

    function claimSrUsds(address rewardsTo) external returns (uint256 srUsdsAmt) {
        srUsdsAmt = LCTSQueueLike(depositQueue).claim(msg.sender, rewardsTo);
    }

    // --- Withdraw Queue User Functions ---

    function claimSUsdsAndJoinSrUsds(address rewardsTo, uint256 srUsdsAmt) external returns (uint256 sUsdsAmt) {
        srusds.transferFrom(msg.sender, address(this), srUsdsAmt);
        sUsdsAmt = LCTSQueueLike(withdrawQueue).claimAndJoin(msg.sender, rewardsTo, srUsdsAmt);
    }

    function claimUsdsAndJoinSrUsds(address rewardsTo, uint256 srUsdsAmt) external returns (uint256 usdsAmt) {
        srusds.transferFrom(msg.sender, address(this), srUsdsAmt);
        uint256 sUsdsAmt = LCTSQueueLike(withdrawQueue).claimAndJoin(msg.sender, address(this), srUsdsAmt);
        if (sUsdsAmt > 0) usdsAmt = susds.redeem(sUsdsAmt, rewardsTo, address(this));
    }

    function claimSUsdsAndExitSrUsds(address rewardsTo, address underlyingTo) external returns (uint256 sUsdsAmt, uint256 srUsdsAmt) {
        (sUsdsAmt, srUsdsAmt) = LCTSQueueLike(withdrawQueue).claimAndExit(msg.sender, rewardsTo, underlyingTo);
    }

    function claimUsdsAndExitSrUsds(address rewardsTo, address underlyingTo) external returns (uint256 usdsAmt, uint256 srUsdsAmt)  {
        uint256 sUsdsAmt;
        (sUsdsAmt, srUsdsAmt) = LCTSQueueLike(withdrawQueue).claimAndExit(msg.sender, address(this), underlyingTo);
        if (sUsdsAmt  > 0) usdsAmt = susds.redeem(sUsdsAmt, rewardsTo, address(this));
    }

    function claimSUsds(address rewardsTo) external returns (uint256 sUsdsAmt) {
        sUsdsAmt = LCTSQueueLike(withdrawQueue).claim(msg.sender, rewardsTo);
    }

    function claimUsds(address rewardsTo) external returns (uint256 usdsAmt) {
        uint256 sUsdsAmt = LCTSQueueLike(withdrawQueue).claim(msg.sender, address(this));
        if (sUsdsAmt > 0) usdsAmt = susds.redeem(sUsdsAmt, rewardsTo, address(this));
    }
}
