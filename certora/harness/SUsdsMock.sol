// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import { UsdsMock } from "certora/harness/UsdsMock.sol";

// sUSDS reduced to what SrUsds and SrUsdsQueues use: the ERC-20 transfers, and the conversions between USDS and
// sUSDS at a fixed chi. The real token accrues chi before converting, which inside one call gives previewMint,
// mint and redeem the same price, as here
contract SUsdsMock {
    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;

    uint256 public totalSupply;
    uint256 public chi;

    UsdsMock public usds;

    uint256 private constant RAY = 10 ** 27;

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x != 0 ? ((x - 1) / y) + 1 : 0;
        }
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SUsds/invalid-address");
        uint256 balance = balanceOf[msg.sender];
        require(balance >= value, "SUsds/insufficient-balance");

        balanceOf[msg.sender] = balance - value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SUsds/invalid-address");
        uint256 balance = balanceOf[from];
        require(balance >= value, "SUsds/insufficient-balance");

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, "SUsds/insufficient-allowance");

                allowance[from][msg.sender] = allowed - value;
            }
        }

        balanceOf[from] = balance - value;
        balanceOf[to] += value;
        return true;
    }

    function previewMint(uint256 shares) public view returns (uint256 assets) {
        assets = _divup(shares * chi, RAY);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(receiver != address(0) && receiver != address(this), "SUsds/invalid-address");
        assets = _divup(shares * chi, RAY);

        usds.transferFrom(msg.sender, address(this), assets);

        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = shares * chi / RAY;

        uint256 balance = balanceOf[owner];
        require(balance >= shares, "SUsds/insufficient-balance");

        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "SUsds/insufficient-allowance");

                allowance[owner][msg.sender] = allowed - shares;
            }
        }

        balanceOf[owner] = balance - shares;
        totalSupply      = totalSupply - shares;

        usds.transfer(receiver, assets);
    }
}
