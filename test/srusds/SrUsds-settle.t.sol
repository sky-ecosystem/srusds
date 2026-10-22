// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SUsdsMock } from "test/mocks/SUsdsMock.sol";

import { SrUsds } from "src/srusds/SrUsds.sol";
import { LCTSHandlerBase } from "src/LCTSHandlerBase.sol";
import { LCTSDepositQueue } from "src/LCTSDepositQueue.sol";
import { LCTSWithdrawQueue } from "src/LCTSWithdrawQueue.sol";

// Settles srUSDS at the same point of the cycle as SrUsdsHandler: before either queue converts
contract SettleHandler is LCTSHandlerBase {
    SrUsds immutable srusds;

    constructor(SrUsds srusds_, SUsdsMock susds_, address depositQueue_, address withdrawQueue_)
        LCTSHandlerBase(depositQueue_, withdrawQueue_)
    {
        srusds = srusds_;
        susds_.approve(address(srusds_), type(uint256).max);
    }

    function _settle() internal override {
        srusds.settle(profit);
    }
}

contract SrUsdsSettleTest is Test {
    SUsdsMock         susds;
    SrUsds            srusds;
    LCTSDepositQueue  depositQueue;
    LCTSWithdrawQueue withdrawQueue;
    SettleHandler     handler;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    uint256 constant RAY = 10**27;

    function setUp() public {
        susds  = new SUsdsMock();
        srusds = SrUsds(address(new ERC1967Proxy(address(new SrUsds(address(susds))), abi.encodeCall(SrUsds.initialize, ()))));

        depositQueue  = new LCTSDepositQueue(address(srusds));
        withdrawQueue = new LCTSWithdrawQueue(address(srusds));
        handler       = new SettleHandler(srusds, susds, address(depositQueue), address(withdrawQueue));

        srusds.rely(address(handler));
        srusds.rely(address(depositQueue));
        srusds.rely(address(withdrawQueue));
        depositQueue.rely(address(handler));
        withdrawQueue.rely(address(handler));

        handler.file("settleTime",  16 hours);
        handler.file("lockTimeEnd", 14 hours);
        handler.file("lockTimeBgn", 13 hours);

        susds.approve(address(depositQueue), type(uint256).max);
        srusds.approve(address(withdrawQueue), type(uint256).max);
    }

    function _joinDeposit(address usr, uint256 amt) internal {
        deal(address(susds), address(this), amt);
        depositQueue.claimAndJoin(usr, usr, amt);
    }

    function _joinWithdraw(address usr, uint256 amt) internal {
        vm.prank(usr); srusds.transfer(address(this), amt);
        withdrawQueue.claimAndJoin(usr, usr, amt);
    }

    function _lockAndPlan(int256 profit, uint256 depositCap, uint256 withdrawCap) internal {
        vm.warp((block.timestamp / 1 days) * 1 days + 1 days + 13 hours);
        handler.lock();
        handler.plan(profit, depositCap, withdrawCap);
        if (profit > 0) deal(address(susds), address(handler), uint256(profit));
        vm.warp((block.timestamp / 1 days) * 1 days + 16 hours);
    }

    function _cycle(int256 profit, uint256 depositCap, uint256 withdrawCap) internal {
        _lockAndPlan(profit, depositCap, withdrawCap);
        handler.settle();
    }

    /// The first cycle settles srUSDS while nothing is minted. chi must survive it for the
    /// deposit queue to ever convert.
    function testFirstSettleKeepsChi() public {
        _joinDeposit(alice, 100e18);

        _cycle(0, 100e18, 0);

        assertEq(srusds.chi(), RAY);
        depositQueue.claim(alice, alice);
        assertEq(srusds.balanceOf(alice), 100e18);
    }

    function testLifecycleThroughZeroSupply() public {
        _joinDeposit(alice, 100e18);
        _cycle(0, 100e18, 0);
        depositQueue.claim(alice, alice);

        _cycle(10e18, 0, 0);
        assertEq(srusds.chi(), 1.1e27);

        // Everyone leaves, so the next settle runs at zero supply again
        _joinWithdraw(alice, 100e18);
        _cycle(0, 0, 100e18);
        withdrawQueue.claim(alice, alice);
        assertEq(susds.balanceOf(alice), 110e18);
        assertEq(srusds.totalSupply(), 0);

        _joinDeposit(bob, 110e18);
        _cycle(0, 110e18, 0);
        assertEq(srusds.chi(), 1.1e27);
        depositQueue.claim(bob, bob);
        // Minted at the kept chi, less a wei of rounding in the queue's reward accumulator
        assertApproxEqAbs(srusds.balanceOf(bob), 110e18 * RAY / 1.1e27, 1);
    }

    /// A non-zero amount with nothing outstanding would strand the backing, so it reverts and
    /// the handler stays locked until replanned.
    function testProfitWithNothingOutstandingReverts() public {
        _joinDeposit(alice, 100e18);
        _lockAndPlan(5e18, 100e18, 0);

        vm.expectRevert("SrUsds/nothing-to-settle");
        handler.settle();
        assertEq(handler.locked(), 1);

        handler.plan(0, 100e18, 0);
        handler.settle();
        assertEq(srusds.totalSupply(), 100e18);
    }

    function testLossWithNothingOutstandingReverts() public {
        _lockAndPlan(-5e18, 0, 0);

        vm.expectRevert("SrUsds/nothing-to-settle");
        handler.settle();
    }

    function testTotalLossLeavesChiNonZero() public {
        _joinDeposit(alice, 100e18);
        _cycle(0, 100e18, 0);

        _cycle(-100e18, 0, 0);

        assertEq(srusds.chi(), 1);
        assertEq(susds.balanceOf(address(srusds)), 0);
    }
}
