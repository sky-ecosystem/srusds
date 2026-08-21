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

interface AuthorityLike {
    function canCall(address, address, bytes4) external view returns (bool);
}

interface HandlerLike {
    function plan(int256 settleAmt, uint256 depositCapacity, uint256 withdrawCapacity) external;
}

interface BeamLike {
    function diss(address) external;
    function file(bytes32, uint256) external;
}

contract VentureMom {
    // --- Storage ---
    address public owner;
    address public authority;

    // --- Immutables ---
    HandlerLike immutable public handler;

    // --- Events ---
    event SetOwner(address indexed owner);
    event SetAuthority(address indexed authority);
    event DissBeamBud(address indexed beam, address bud);
    event HaltBeam(address indexed beam);
    event ZeroMaxMint(address indexed beam);
    event ZeroMaxCut(address indexed beam);
    event ZeroMaxDepositCapacity(address indexed beam);
    event ZeroMaxWithdrawCapacity(address indexed beam);
    event ZeroSettle();

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "VentureMom/not-owner");
        _;
    }

    modifier auth() {
        require(isAuthorized(msg.sender, msg.sig), "VentureMom/not-authorized");
        _;
    }

    constructor(address handler_) {
        handler = HandlerLike(handler_);

        owner = msg.sender;
        emit SetOwner(msg.sender);
    }

    // --- Administration ---
    function setOwner(address owner_) external onlyOwner {
        owner = owner_;
        emit SetOwner(owner_);
    }

    function setAuthority(address authority_) external onlyOwner {
        authority = authority_;
        emit SetAuthority(authority_);
    }

    // --- Internal Functions ---
    function isAuthorized(address src, bytes4 sig) internal view returns (bool) {
        if (src == owner) {
            return true;
        } else if (authority == address(0)) {
            return false;
        } else {
            return AuthorityLike(authority).canCall(src, address(this), sig);
        }
    }

    // --- Emergency Actions ---
    function dissBeamBud(address beam, address bud) external auth {
        BeamLike(beam).diss(bud);
        emit DissBeamBud(beam, bud);
    }

    function haltBeam(address beam) external auth {
        BeamLike(beam).file("bad", 1);
        emit HaltBeam(beam);
    }

    function zeroMaxMint(address beam) external auth {
        BeamLike(beam).file("maxMint", 0);
        emit ZeroMaxMint(beam);
    }

    function zeroMaxCut(address beam) external auth {
        BeamLike(beam).file("maxCut", 0);
        emit ZeroMaxCut(beam);
    }

    function zeroMaxDepositCapacity(address beam) external auth {
        BeamLike(beam).file("maxDepositCapacity", 0);
        emit ZeroMaxDepositCapacity(beam);
    }

    function zeroMaxWithdrawCapacity(address beam) external auth {
        BeamLike(beam).file("maxWithdrawCapacity", 0);
        emit ZeroMaxWithdrawCapacity(beam);
    }

    /// @notice Emergency action to zero all settlement parameters
    function zeroSettle() external auth {
        handler.plan(0, 0, 0);
        emit ZeroSettle();
    }
}
