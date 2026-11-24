// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import { SUsdsMock } from "certora/harness/SUsdsMock.sol";

// SrUsds reduced to what SrUsdsQueues uses: the ERC-20 transfers, deposit and redeem at the same price formulas,
// and a settle that moves the price. How SrUsds itself settles is verified in its own spec, so here settle
// leaves chi at chiAfterSettle, which is any value: the queues are verified for every price a settlement can
// leave. No authorization is modelled, the queues being a ward of the real token
contract ShareMock {
    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;

    uint256 public totalSupply;
    uint256 public chi;
    uint256 public chiAfterSettle;

    SUsdsMock public susds;

    uint256 private constant RAY = 10 ** 27;

    function asset() external view returns (address) {
        return address(susds);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SrUsds/invalid-address");
        uint256 balance = balanceOf[msg.sender];
        require(balance >= value, "SrUsds/insufficient-balance");

        balanceOf[msg.sender] = balance - value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SrUsds/invalid-address");
        uint256 balance = balanceOf[from];
        require(balance >= value, "SrUsds/insufficient-balance");

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, "SrUsds/insufficient-allowance");

                allowance[from][msg.sender] = allowed - value;
            }
        }

        balanceOf[from] = balance - value;
        balanceOf[to] += value;
        return true;
    }

    function settle(int256) external {
        chi = chiAfterSettle;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets * RAY / chi;
        require(receiver != address(0) && receiver != address(this), "SrUsds/invalid-address");

        susds.transferFrom(msg.sender, address(this), assets);

        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = shares * chi / RAY;

        uint256 balance = balanceOf[owner];
        require(balance >= shares, "SrUsds/insufficient-balance");

        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "SrUsds/insufficient-allowance");

                allowance[owner][msg.sender] = allowed - shares;
            }
        }

        balanceOf[owner] = balance - shares;
        totalSupply      = totalSupply - shares;

        susds.transfer(receiver, assets);
    }
}
