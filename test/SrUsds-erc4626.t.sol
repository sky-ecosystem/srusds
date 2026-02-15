// SPDX-License-Identifier: AGPL-3.0-or-later

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

pragma solidity ^0.8.21;

import "erc4626-tests/ERC4626.test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { VatMock } from "test/mocks/VatMock.sol";
import { SUsdsMock } from "test/mocks/SUsdsMock.sol";

import { SrUsds } from "src/srusds/SrUsds.sol";

abstract contract ERC4626TestReduced is ERC4626Test {
    function test_maxDeposit(Init memory) public override { vm.skip(true); }
    function test_previewDeposit(Init memory, uint256) public override { vm.skip(true); }
    function test_maxMint(Init memory) public override { vm.skip(true); }
    function test_previewMint(Init memory, uint256) public override { vm.skip(true); }
    function test_maxRedeem(Init memory) public override { vm.skip(true); }
    function test_previewRedeem(Init memory, uint256) public override { vm.skip(true); }
    function test_mint(Init memory, uint256 , uint256) public override { vm.skip(true); }
    function test_maxWithdraw(Init memory) public override { vm.skip(true); }
    function test_previewWithdraw(Init memory, uint256) public override { vm.skip(true); }
    function test_withdraw(Init memory, uint256, uint256) public override { vm.skip(true); }
    function test_withdraw_zero_allowance(Init memory, uint256) public override { vm.skip(true); }
    function test_RT_deposit_withdraw(Init memory, uint256) public override { vm.skip(true); }
    function test_RT_redeem_mint(Init memory, uint256) public override { vm.skip(true); }
    function test_RT_mint_withdraw(Init memory, uint256) public override { vm.skip(true); }
    function test_RT_mint_redeem(Init memory, uint256) public override { vm.skip(true); }
    function test_RT_withdraw_mint(Init memory, uint256) public override { vm.skip(true); }
    function test_RT_withdraw_deposit(Init memory, uint256) public override { vm.skip(true); }
}

contract SrUsdsERC4626Test is ERC4626TestReduced {

    using stdStorage for StdStorage;

    VatMock vat;
    SUsdsMock susds;

    SrUsds srusds;

    uint256 constant private RAY = 10**27;

    function setUp() public override {
        vat = new VatMock();
        susds = new SUsdsMock();

        srusds = SrUsds(address(new ERC1967Proxy(address(new SrUsds(address(susds))), abi.encodeCall(SrUsds.initialize, ()))));

        deal(address(susds), address(this), 1_100e18);
        susds.approve(address(srusds), 1_100e18);
        srusds.deposit(1_000e18, address(this));
        srusds.settle(100e18);

        assertGt(srusds.chi(), RAY);

        _underlying_ = address(susds);
        _vault_ = address(srusds);
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = false;
    }

    // setup initial vault state
    function setUpVault(Init memory init) public override {
        for (uint256 i = 0; i < N; i++) {
            init.share[i] %= 1_000_000_000 ether;
            init.asset[i] %= 1_000_000_000 ether;
            srusds.rely(init.user[i]); // To be able to deposit and withdraw
            vm.assume(init.user[i] != address(0) && init.user[i] != address(srusds));
        }
        super.setUpVault(init);
    }

    // setup initial yield
    function setUpYield(Init memory init) public override {
        vm.assume(init.yield >= 0);
        init.yield %= 1_000_000_000 ether;
        uint256 gain = uint256(init.yield);

        uint256 supply = srusds.totalSupply();
        if (supply > 0) {
            uint256 nChi = gain * RAY / supply + srusds.chi();
            uint256 chiRho = (block.timestamp << 192) + nChi;
            vm.store(
                address(srusds),
                bytes32(uint256(5)),
                bytes32(chiRho)
            );
            assertEq(uint256(srusds.chi()), nChi);
            assertEq(uint256(srusds.rho()), block.timestamp);
            susds.mint(address(srusds), gain);
        }
    }

}
