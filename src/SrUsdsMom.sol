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
    function plan(int256) external;
}

interface SettlerLike {
    function diss(address) external;
    function file(bytes32, uint256) external;
}

contract SrUsdsMom {
    // --- Storage ---
    address public owner;
    address public authority;

    // --- Immutables ---
    HandlerLike immutable public handler;

    // --- Events ---
    event SetOwner(address indexed owner);
    event SetAuthority(address indexed authority);
    event DissSettlerBud(address indexed settler, address bud);
    event HaltSettler(address indexed settler);
    event ZeroMaxMint(address indexed settler);
    event ZeroMaxCut(address indexed settler);
    event ZeroSettle();

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "SrUsdsMom/not-owner");
        _;
    }

    modifier auth() {
        require(isAuthorized(msg.sender, msg.sig), "SrUsdsMom/not-authorized");
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
    function dissSettlerBud(address settler, address bud) external auth {
        SettlerLike(settler).diss(bud);
        emit DissSettlerBud(settler, bud);
    }

    function haltSettler(address settler) external auth {
        SettlerLike(settler).file("bad", 1);
        emit HaltSettler(settler);
    }

    function zeroMaxMint(address settler) external auth {
        SettlerLike(settler).file("maxMint", 0);
        emit ZeroMaxMint(settler);
    }

    function zeroMaxCut(address settler) external auth {
        SettlerLike(settler).file("maxCut", 0);
        emit ZeroMaxCut(settler);
    }

    function zeroSettle() external auth {
        handler.plan(0);
        emit ZeroSettle();
    }
}
