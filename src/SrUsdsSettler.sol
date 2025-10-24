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

interface Handler {
    function tau() external view returns (uint256);
    function plan(int256) external;
}

contract SrUsdsSettler {
    // --- Storage Variables ---
    mapping(address => uint256) public wards;
    mapping(address => uint256) public buds;
    uint8   public bad;     // Circuit breaker flag
    uint256 public maxMint; // Max mint value [wad]
    uint256 public maxCut;  // Max cut value [wad]
    uint256 public zzz;     // Time before tau is reached until the settler can update the value [seconds]

    // --- Immutables ---
    Handler public immutable handler;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Plan(int256 amount);

    // --- Modifiers ---
    modifier auth() {
        require(wards[msg.sender] == 1, "SrUsdsSettler/not-authorized");
        _;
    }

    modifier toll() {
        require(buds[msg.sender] == 1, "SrUsdsSettler/not-facilitator");
        _;
    }

    modifier good() {
        require(bad == 0, "SrUsdsSettler/module-halted");
        _;
    }

    constructor(address _handler) {
        handler = Handler(_handler);

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
            require(data == 0 || data == 1, "SrUsdsSettler/invalid-bad-value");
            bad = uint8(data);
        } else if (what == "maxMint") {
            maxMint = data;
        } else if (what == "maxCut") {
            maxCut = data;
        }  else if (what == "zzz") {
            zzz = data;
        } else revert("SrUsdsSettler/file-unrecognized-param");
        emit File(what, data);
    }

    function plan(int256 amount) external toll good {
        require(handler.tau() > block.timestamp + zzz, "SrUsdsSettler/too-late");
        require(amount <= 0 || uint256(amount) <= maxMint, "SrUsdsSettler/maxMint-exceed");
        require(amount >= 0 || uint256(-amount) <= maxCut, "SrUsdsSettler/maxCut-exceed");

        handler.plan(amount);

        emit Plan(amount);
    }
}
