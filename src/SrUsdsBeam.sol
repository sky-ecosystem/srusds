// SPDX-FileCopyrightText: 2025 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
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

interface QueuesLike {
    function settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) external;
}

contract SrUsdsBeam {
    // --- Storage Variables ---
    mapping(address => uint256) public wards;
    mapping(address => uint256) public buds;
    uint8   public bad;                // Circuit breaker flag
    uint256 public maxMint;            // Max mint value [wad]
    uint256 public maxCut;             // Max cut value [wad]
    uint256 public maxDepositCapacity; // Max deposit queue capacity [wad]
    uint256 public maxRedeemCapacity;  // Max redeem queue capacity [wad]

    // --- Immutables ---
    QueuesLike public immutable queues;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity);

    // --- Modifiers ---
    modifier auth() {
        require(wards[msg.sender] == 1, "SrUsdsBeam/not-authorized");
        _;
    }

    modifier toll() {
        require(buds[msg.sender] == 1, "SrUsdsBeam/not-facilitator");
        _;
    }

    modifier good() {
        require(bad == 0, "SrUsdsBeam/module-halted");
        _;
    }

    constructor(address _queues) {
        queues = QueuesLike(_queues);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function kiss(address usr) external auth {
        buds[usr] = 1;
        emit Kiss(usr);
    }

    function diss(address usr) external auth {
        buds[usr] = 0;
        emit Diss(usr);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "bad") {
            require(data == 0 || data == 1, "SrUsdsBeam/invalid-bad-value");
            bad = uint8(data);
        } else if (what == "maxMint") {
            maxMint = data;
        } else if (what == "maxCut") {
            maxCut = data;
        } else if (what == "maxDepositCapacity") {
            maxDepositCapacity = data;
        } else if (what == "maxRedeemCapacity") {
            maxRedeemCapacity = data;
        } else revert("SrUsdsBeam/file-unrecognized-param");
        emit File(what, data);
    }

    /// @notice Settle the queues within the facilitator's limits
    /// @param profit Amount to add (positive) or remove (negative) from vault backing
    /// @param depositCapacity Maximum underlying to convert via deposit queue
    /// @param redeemCapacity Maximum shares to convert via redeem queue
    function settle(
        int256 profit,
        uint256 depositCapacity,
        uint256 redeemCapacity
    ) external toll good {
        require(profit <= 0 || uint256(profit) <= maxMint, "SrUsdsBeam/maxMint-exceed");
        require(profit >= 0 || uint256(-profit) <= maxCut, "SrUsdsBeam/maxCut-exceed");
        require(depositCapacity <= maxDepositCapacity, "SrUsdsBeam/maxDepositCapacity-exceed");
        require(redeemCapacity <= maxRedeemCapacity, "SrUsdsBeam/maxRedeemCapacity-exceed");

        queues.settle(profit, depositCapacity, redeemCapacity);

        emit Settle(profit, depositCapacity, redeemCapacity);
    }
}
