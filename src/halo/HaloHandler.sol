// SPDX-License-Identifier: AGPL-3.0-or-later

/// HaloHandler.sol -- Settlement handler for HaloVault

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

import { LCTSHandlerBase } from "src/LCTSHandlerBase.sol";

interface HaloVaultLike {
    function settle(int256) external returns (uint256);
}

interface PrimeLike {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

contract HaloHandler is LCTSHandlerBase {

    // --- Immutables ---

    HaloVaultLike public immutable vault;
    PrimeLike     public immutable prime;
    address       public immutable treasury;

    // --- Constructor ---

    constructor(
        address vault_,
        address prime_,
        address treasury_,
        address depositQueue_,
        address withdrawQueue_
    ) LCTSHandlerBase(depositQueue_, withdrawQueue_) {
        vault    = HaloVaultLike(vault_);
        prime    = PrimeLike(prime_);
        treasury = treasury_;

        prime.approve(vault_, type(uint256).max);
    }

    // --- Internal Hooks ---

    function _settle() internal override {
        int256 profit_ = profit;

        if (profit_ > 0) {
            prime.transferFrom(treasury, address(this), uint256(profit_));
        }

        vault.settle(profit_);

        if (profit_ < 0) {
            prime.transfer(treasury, uint256(-profit_));
        }
    }
}
