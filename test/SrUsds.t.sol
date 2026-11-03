// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "token-tests/TokenFuzzChecks.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { VatMock } from "test/mocks/VatMock.sol";
import { UsdsMock } from "test/mocks/UsdsMock.sol";
import { UsdsJoinMock } from "test/mocks/UsdsJoinMock.sol";
import { SUsdsMock } from "test/mocks/SUsdsMock.sol";

import { SrUsds } from "src/SrUsds.sol";

/// @dev Settlement against the Vat, with mocks. The fork test in test/srusds covers deployment and the real sUSDS
contract SrUsdsTest is TokenFuzzChecks {
    VatMock      vat;
    UsdsMock     usds;
    UsdsJoinMock join;
    SUsdsMock    susds;
    SrUsds       srusds;

    address constant VOW = address(0x5EE);

    event Settle(int256 assets, uint256 oldChi, uint256 newChi);

    function setUp() public {
        vat   = new VatMock();
        usds  = new UsdsMock();
        join  = new UsdsJoinMock(address(vat), address(usds));
        susds = new SUsdsMock(address(usds));
        usds.rely(address(join));
        usds.rely(address(susds));
        vat.suck(address(0xDEAD), address(join), 1e9 * 1e45); // Backing for the USDS the join mock exits on losses

        srusds = SrUsds(address(new ERC1967Proxy(
            address(new SrUsds(address(join), VOW, address(susds))),
            abi.encodeCall(SrUsds.initialize, ())
        )));
        vat.rely(address(srusds));
    }

    function _deposit(address usr, uint256 assets) internal returns (uint256 shares) {
        susds.mint(address(this), assets);
        susds.approve(address(srusds), assets);
        shares = srusds.deposit(assets, usr);
    }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked { z = x != 0 ? ((x - 1) / y) + 1 : 0; }
    }

    function testInitialize() public {
        assertEq(srusds.chi(), RAY);
        assertEq(srusds.wards(address(this)), 1);
        assertEq(address(srusds.usdsJoin()), address(join));
        assertEq(address(srusds.vat()), address(vat));
        assertEq(address(srusds.usds()), address(usds));
        assertEq(srusds.vow(), VOW);
        assertEq(address(srusds.susds()), address(susds));
        assertEq(srusds.asset(), address(susds));
        assertEq(vat.can(address(srusds), address(join)), 1);
        assertEq(usds.allowance(address(srusds), address(susds)), type(uint256).max);
        assertEq(usds.allowance(address(srusds), address(join)), type(uint256).max);
    }

    function testAuth() public {
        checkAuth(address(srusds), "SrUsds");
    }

    function testERC20() public {
        checkBulkERC20(address(srusds), "SrUsds", "Senior Risk USDS", "srUSDS", "1", 18);
    }

    function testPermit() public {
        checkBulkPermit(address(srusds), "SrUsds");
    }

    function testERC20Fuzz(address from, address to, uint256 amount1, uint256 amount2) public {
        checkBulkERC20Fuzz(address(srusds), "SrUsds", from, to, amount1, amount2);
    }

    function testPermitFuzz(uint128 privKey, address to, uint256 amount, uint256 deadline, uint256 nonce) public {
        checkBulkPermitFuzz(address(srusds), "SrUsds", privKey, to, amount, deadline, nonce);
    }

    // --- Deposit and redeem (only through the queues) ---

    function testDepositRedeemAuth() public {
        vm.startPrank(address(0xBEEF));
        vm.expectRevert("SrUsds/not-authorized");
        srusds.deposit(1e18, address(0xBEEF));
        vm.expectRevert("SrUsds/not-authorized");
        srusds.redeem(1e18, address(0xBEEF), address(0xBEEF));
        vm.stopPrank();
        assertEq(srusds.maxDeposit(address(0xBEEF)), 0);
        assertEq(srusds.maxRedeem(address(0xBEEF)), 0);
    }

    function testDepositRedeemAtPrice() public {
        _deposit(address(0x111), 100e18);
        srusds.settle(10e18); // chi 1.1
        assertEq(srusds.chi(), 1.1e27);

        assertEq(_deposit(address(0xBEEF), 110e18), 100e18);
        assertEq(srusds.convertToShares(110e18), 100e18);
        assertEq(srusds.convertToAssets(100e18), 110e18);

        srusds.rely(address(0xBEEF));
        vm.prank(address(0xBEEF)); assertEq(srusds.redeem(100e18, address(0xAAA), address(0xBEEF)), 110e18);
        assertEq(susds.balanceOf(address(0xAAA)), 110e18);
        assertEq(srusds.balanceOf(address(0xBEEF)), 0);
    }

    // --- Settle ---

    /// A gain is generated as USDS through vat.suck against the vow, converted to exactly that much sUSDS, and
    /// credited to chi rounded down
    function testSettleGain() public {
        _deposit(address(0x111), 100e18);
        uint256 sinBefore = vat.sin(VOW);

        vm.expectEmit();
        emit Settle(10e18, RAY, 1.1e27);
        srusds.settle(10e18);

        assertEq(srusds.chi(), 1.1e27);
        assertEq(susds.balanceOf(address(srusds)), 110e18);
        assertEq(srusds.totalAssets(), 110e18);
        assertEq(vat.sin(VOW), sinBefore + 10e18 * RAY);
    }

    function testSettleGainRoundsDown() public {
        _deposit(address(0x111), 3e18);
        srusds.settle(1);
        assertEq(srusds.chi(), RAY + 333333333);
        assertEq(susds.balanceOf(address(srusds)), 3e18 + 1);
        assertLe(srusds.totalAssets(), susds.balanceOf(address(srusds)));
    }

    /// A loss redeems sUSDS to USDS, returns it to the vow, and is debited from chi rounded up
    function testSettleLoss() public {
        _deposit(address(0x111), 100e18);
        uint256 daiBefore = vat.dai(VOW);

        vm.expectEmit();
        emit Settle(-10e18, RAY, 0.9e27);
        srusds.settle(-10e18);

        assertEq(srusds.chi(), 0.9e27);
        assertEq(susds.balanceOf(address(srusds)), 90e18);
        assertEq(srusds.totalAssets(), 90e18);
        assertEq(vat.dai(VOW), daiBefore + 10e18 * RAY);
    }

    function testSettleLossRoundsUp() public {
        _deposit(address(0x111), 3e18);
        srusds.settle(-1);
        assertEq(srusds.chi(), RAY - _divup(RAY, 3e18));
        assertEq(susds.balanceOf(address(srusds)), 3e18 - 1);
        assertLe(srusds.totalAssets(), susds.balanceOf(address(srusds)));
    }

    /// A loss is capped at the backing and leaves chi at 0: deposits revert, redeems pay nothing, and nothing
    /// can be revalued again
    function testSettleTotalLoss() public {
        _deposit(address(0x111), 100e18);
        srusds.settle(-200e18);

        assertEq(srusds.chi(), 0);
        assertEq(susds.balanceOf(address(srusds)), 0);
        assertEq(srusds.totalAssets(), 0);
        assertEq(srusds.convertToShares(1e18), 0);
        assertEq(srusds.convertToAssets(1e18), 0);

        susds.mint(address(this), 1e18);
        susds.approve(address(srusds), 1e18);
        vm.expectRevert(stdError.divisionError);
        srusds.deposit(1e18, address(this));

        srusds.settle(50e18); // Nothing outstanding to revalue
        assertEq(srusds.chi(), 0);
        assertEq(susds.balanceOf(address(srusds)), 0);

        srusds.rely(address(0x111));
        vm.prank(address(0x111)); assertEq(srusds.redeem(100e18, address(0x111), address(0x111)), 0);
    }

    function testSettleNothingOutstandingIsNoop() public {
        uint256 sinBefore = vat.sin(VOW);
        srusds.settle(10e18);
        assertEq(srusds.chi(), RAY);
        assertEq(susds.balanceOf(address(srusds)), 0);
        assertEq(vat.sin(VOW), sinBefore);

        _deposit(address(0x111), 100e18);
        srusds.settle(0);
        assertEq(srusds.chi(), RAY);
    }

    function testSettleAuth() public {
        vm.prank(address(0xBEEF)); vm.expectRevert("SrUsds/not-authorized");
        srusds.settle(1);
    }

    function testTransferInvalidAddress() public {
        _deposit(address(this), 1e18);
        vm.expectRevert("SrUsds/invalid-address");
        srusds.transfer(address(0), 1);
        vm.expectRevert("SrUsds/invalid-address");
        srusds.transfer(address(srusds), 1);
        vm.expectRevert("SrUsds/invalid-address");
        srusds.deposit(1, address(srusds));
    }
}
