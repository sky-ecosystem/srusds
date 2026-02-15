// SPDX-License-Identifier: AGPL-3.0-or-later

/// HaloVault.sol -- ERC4626 vault with settlement-based exchange rate

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

interface PrimeLike {
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

contract HaloVault {

    // --- Storage Variables ---

    mapping(address => uint256)                      public wards;
    uint256                                          public totalSupply;
    mapping(address => uint256)                      public balanceOf;
    mapping(address => mapping(address => uint256))  public allowance;
    uint256                                          public chi; // Rate accumulator [ray]

    // --- Constants ---

    string  public constant name     = "Halo Vault";
    string  public constant symbol   = "HALO";
    uint8   public constant decimals = 18;
    uint256 private constant RAY     = 10 ** 27;

    // --- Immutables ---

    PrimeLike public immutable prime;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Settle(int256 assets, uint256 oldChi, uint256 newChi);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "HaloVault/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address prime_) {
        prime = PrimeLike(prime_);
        chi = RAY;

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Admin ---

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    /// @notice Adjust vault backing and update exchange rate
    /// @param assets Positive to add backing (increases chi), negative to remove (decreases chi)
    function settle(int256 assets) external auth returns (uint256 newChi) {
        uint256 oldChi = chi;
        uint256 totalAssets_ = totalSupply * oldChi / RAY;
        uint256 newTotalAssets;
        if (assets > 0) {
            prime.transferFrom(msg.sender, address(this), uint256(assets));
            newTotalAssets = totalAssets_ + uint256(assets);
        } else {
            uint256 assets_ = uint256(-assets);
            if (assets_ > totalAssets_) assets_ = totalAssets_;
            prime.transfer(msg.sender, assets_);
            newTotalAssets = totalAssets_ - assets_;
        }
        newChi = chi = totalAssets_ > 0 ? oldChi * newTotalAssets / totalAssets_ : 0;
        emit Settle(assets, oldChi, newChi);
    }

    // --- ERC20 ---

    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "HaloVault/invalid-address");
        uint256 balance = balanceOf[msg.sender];
        require(balance >= value, "HaloVault/insufficient-balance");

        unchecked {
            balanceOf[msg.sender] = balance - value;
            balanceOf[to] += value;
        }

        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "HaloVault/invalid-address");
        uint256 balance = balanceOf[from];
        require(balance >= value, "HaloVault/insufficient-balance");

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, "HaloVault/insufficient-allowance");
                unchecked { allowance[from][msg.sender] = allowed - value; }
            }
        }

        unchecked {
            balanceOf[from] = balance - value;
            balanceOf[to] += value;
        }

        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    // --- ERC4626 ---

    function asset() external view returns (address) {
        return address(prime);
    }

    function totalAssets() external view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return chi > 0 ? assets * RAY / chi : 0;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * chi / RAY;
    }

    function deposit(uint256 assets, address receiver) external auth returns (uint256 shares) {
        shares = assets * RAY / chi;
        require(receiver != address(0) && receiver != address(this), "HaloVault/invalid-address");

        prime.transferFrom(msg.sender, address(this), assets);

        unchecked { balanceOf[receiver] += shares; }
        totalSupply += shares;

        emit Deposit(msg.sender, receiver, assets, shares);
        emit Transfer(address(0), receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external auth returns (uint256 assets) {
        assets = shares * chi / RAY;
        require(assets > 0, "HaloVault/assets-zero");
        uint256 balance = balanceOf[owner];
        require(balance >= shares, "HaloVault/insufficient-balance");

        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "HaloVault/insufficient-allowance");
                unchecked { allowance[owner][msg.sender] = allowed - shares; }
            }
        }

        unchecked {
            balanceOf[owner] = balance - shares;
            totalSupply -= shares;
        }

        prime.transfer(receiver, assets);

        emit Transfer(owner, address(0), shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }
}
