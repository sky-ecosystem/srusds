// SPDX-License-Identifier: AGPL-3.0-or-later

/// LCTSWithdrawQueue.sol -- LCTS queue for vault share → asset conversions

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

import { LCTSQueueBase } from "src/lcts/LCTSQueueBase.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC4626 {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

/// @title LCTSWithdrawQueue
/// @notice LCTS queue for redeeming vault shares (redeem side)
/// @dev Underlying = vault shares users deposit, Reward = assets received after conversion
contract LCTSWithdrawQueue is LCTSQueueBase {

    IERC4626 public immutable vault;
    IERC20   public immutable asset;

    constructor(address vault_) {
        vault = IERC4626(vault_);
        asset = IERC20(vault.asset());

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function _pullUnderlying(address from, uint256 amount) internal override {
        IERC20(address(vault)).transferFrom(from, address(this), amount);
    }

    function _pushUnderlying(address to, uint256 amount) internal override {
        IERC20(address(vault)).transfer(to, amount);
    }

    function _pushReward(address to, uint256 amount) internal override {
        asset.transfer(to, amount);
    }

    function _convert(uint256 amount) internal override returns (uint256) {
        return vault.redeem(amount, address(this), address(this));
    }
}
