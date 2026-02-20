// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { MockERC20, MockERC4626 } from "test/mocks/MockERC4626.sol";
import { LCTSHandlerBase } from "src/lcts/LCTSHandlerBase.sol";
import { LCTSDepositQueue } from "src/lcts/LCTSDepositQueue.sol";
import { LCTSWithdrawQueue } from "src/lcts/LCTSWithdrawQueue.sol";

contract MockHandler is LCTSHandlerBase {
    uint256 public settleCalled;

    constructor(
        address depositQueue_,
        address withdrawQueue_
    ) LCTSHandlerBase(depositQueue_, withdrawQueue_) {}

    function _settle() internal override {
        settleCalled++;
    }
}

contract LCTSHandlerBaseTest is DssTest {
    MockERC20 underlying;
    MockERC4626 vault;
    LCTSDepositQueue depositQueue;
    LCTSWithdrawQueue withdrawQueue;
    MockHandler handler;

    address alice = address(0xA11CE);

    // --- Events ---

    event Lock();
    event Plan(int256 settleAmt, uint256 depositCapacity, uint256 withdrawCapacity);
    event Settle(uint256 depositsConverted, uint256 withdrawsConverted);

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND");
        vault = new MockERC4626(address(underlying));
        depositQueue = new LCTSDepositQueue(address(underlying), address(vault));
        withdrawQueue = new LCTSWithdrawQueue(address(vault));
        handler = new MockHandler(address(depositQueue), address(withdrawQueue));

        // Auth handler on both queues
        depositQueue.rely(address(handler));
        withdrawQueue.rely(address(handler));

        // Fund vault with underlying for redemptions
        underlying.mint(address(vault), 10000e18);

        // Configure daily window: lock at 13:00, settle at 16:00, 1h buffer
        handler.file("end", 16 hours);
        handler.file("bgn", 13 hours);
        handler.file("buf", 1 hours);
    }

    // Helper: warp to within lock window
    function _warpToLockWindow() internal {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 13 hours);
    }

    // Helper: warp to settlement time
    function _warpToSettleTime() internal {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 16 hours);
    }

    // Helper: seed deposit queue with underlying
    function _seedDepositQueue(uint256 amount) internal {
        underlying.mint(address(this), amount);
        underlying.approve(address(depositQueue), amount);
        depositQueue.deposit(amount, alice);
    }

    // Helper: seed withdraw queue with vault shares
    function _seedWithdrawQueue(uint256 amount) internal {
        vault.mint(address(this), amount);
        vault.approve(address(withdrawQueue), amount);
        withdrawQueue.deposit(amount, alice);
    }

    // Helper: full lock -> plan -> settle cycle
    function _lockPlanSettle(
        int256 settleAmt_,
        uint256 depositCap,
        uint256 withdrawCap
    ) internal {
        _warpToLockWindow();
        handler.lock();
        handler.plan(settleAmt_, depositCap, withdrawCap);
        _warpToSettleTime();
        handler.settle();
    }

    // --- Auth Tests ---

    function testConstructor() public {
        vm.expectEmit();
        emit Rely(address(this));
        MockHandler h = new MockHandler(address(123), address(234));
        assertEq(h.wards(address(this)), 1);
        assertEq(address(h.depositQueue()), address(123));
        assertEq(address(h.withdrawQueue()), address(234));
    }

    function testAuth() public {
        checkAuth(address(handler), "LCTSHandlerBase");
    }

    function testModifiers() public {
        bytes4[] memory authedMethods = new bytes4[](2);
        authedMethods[0] = handler.lock.selector;
        authedMethods[1] = handler.plan.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(handler), "LCTSHandlerBase/not-authorized", authedMethods);
        vm.stopPrank();
    }

    function testRelyDeny() public {
        vm.expectEmit();
        emit Rely(alice);
        handler.rely(alice);

        assertEq(handler.wards(alice), 1);

        vm.expectEmit();
        emit Deny(alice);
        handler.deny(alice);

        assertEq(handler.wards(alice), 0);
    }

    function testFile() public {
        checkFileUint(address(handler), "LCTSHandlerBase", ["bgn", "end", "buf"]);
    }

    function testFileBgn() public {
        vm.expectEmit();
        emit File("bgn", 14 hours);
        handler.file("bgn", 14 hours);

        assertEq(handler.bgn(), 14 hours);
    }

    function testFileEnd() public {
        vm.expectEmit();
        emit File("end", 17 hours);
        handler.file("end", 17 hours);

        assertEq(handler.end(), 17 hours);
    }

    function testFileBuf() public {
        vm.expectEmit();
        emit File("buf", 30 minutes);
        handler.file("buf", 30 minutes);

        assertEq(handler.buf(), 30 minutes);
    }

    function testFileBgnTooLargeReverts() public {
        vm.expectRevert("LCTSHandlerBase/incorrect-time-in-day");
        handler.file("bgn", 24 hours);
    }

    function testFileEndTooLargeReverts() public {
        vm.expectRevert("LCTSHandlerBase/incorrect-time-in-day");
        handler.file("end", 24 hours);
    }

    function testFileBgnAfterEndReverts() public {
        // bgn = 17h > end = 16h -> underflow reverts
        vm.expectRevert();
        handler.file("bgn", 17 hours);
    }

    function testFileEndBeforeBgnReverts() public {
        // end = 12h < bgn = 13h -> underflow reverts
        vm.expectRevert();
        handler.file("end", 12 hours);
    }

    function testFileBufTooLargeReverts() public {
        // buf must be < end - bgn (16h - 13h = 3h)
        vm.expectRevert("LCTSHandlerBase/incorrect-set-values");
        handler.file("buf", 3 hours);
    }

    function testFileBgnBreaksBufInvariantReverts() public {
        // bgn = 15h -> end - bgn = 1h, but buf = 1h, need buf < 1h
        vm.expectRevert("LCTSHandlerBase/incorrect-set-values");
        handler.file("bgn", 15 hours);
    }

    function testFileEndBreaksBufInvariantReverts() public {
        // end = 14 hours -> end - bgn = 1h, but buf = 1h, need buf < 1h
        vm.expectRevert("LCTSHandlerBase/incorrect-set-values");
        handler.file("end", 14 hours);
    }

    function testFileBootstrapOrder() public {
        // Deploy fresh handler with defaults (bgn=0, end=0, buf=0)
        MockHandler h = new MockHandler(address(depositQueue), address(withdrawQueue));

        // Must set end first (end >= bgn=0, buf=0 < end-0)
        h.file("end", 20 hours);
        assertEq(h.end(), 20 hours);

        // Then bgn (bgn <= end=20h, buf=0 < 20h-bgn)
        h.file("bgn", 10 hours);
        assertEq(h.bgn(), 10 hours);

        // Then buf (buf < end-bgn = 10h)
        h.file("buf", 2 hours);
        assertEq(h.buf(), 2 hours);
    }

    // --- Lock Tests ---

    function testLock() public {
        _warpToLockWindow();

        vm.expectEmit();
        emit Lock();
        handler.lock();

        assertEq(handler.locked(), 1);
        assertEq(depositQueue.locked(), 1);
        assertEq(withdrawQueue.locked(), 1);
    }

    function testLockTooEarlyReverts() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 12 hours + 59 minutes);

        vm.expectRevert("LCTSHandlerBase/lock-too-early");
        handler.lock();
    }

    function testLockTooLateReverts() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 14 hours + 1);

        vm.expectRevert("LCTSHandlerBase/lock-too-late");
        handler.lock();
    }

    function testLockAtExactBgnAllowed() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 13 hours);

        handler.lock();
        assertEq(handler.locked(), 1);
    }

    function testLockAtExactBgnPlusBufAllowed() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 14 hours);

        handler.lock();
        assertEq(handler.locked(), 1);
    }

    function testLockAlreadyLockedReverts() public {
        _warpToLockWindow();
        handler.lock();

        vm.expectRevert("LCTSHandlerBase/already-locked");
        handler.lock();
    }

    // --- Plan Tests ---

    function testPlan() public {
        _warpToLockWindow();
        handler.lock();

        vm.expectEmit();
        emit Plan(100, 200e18, 300e18);
        handler.plan(100, 200e18, 300e18);

        assertEq(handler.settleAmt(), 100);
        assertEq(handler.depositCapacity(), 200e18);
        assertEq(handler.withdrawCapacity(), 300e18);
    }

    function testPlanNegativeSettleAmt() public {
        _warpToLockWindow();
        handler.lock();

        handler.plan(-50, 0, 0);
        assertEq(handler.settleAmt(), -50);
    }

    function testPlanOverwritesPrevious() public {
        _warpToLockWindow();
        handler.lock();

        handler.plan(100, 200e18, 300e18);
        handler.plan(-50, 10e18, 20e18);

        assertEq(handler.settleAmt(), -50);
        assertEq(handler.depositCapacity(), 10e18);
        assertEq(handler.withdrawCapacity(), 20e18);
    }

    function testPlanNotLockedReverts() public {
        vm.expectRevert("LCTSHandlerBase/not-locked");
        handler.plan(0, 100e18, 100e18);
    }

    // --- Settle Tests ---

    function testSettle() public {
        _seedDepositQueue(100e18);
        _seedWithdrawQueue(50e18);

        _warpToLockWindow();
        handler.lock();
        handler.plan(0, 60e18, 30e18);
        _warpToSettleTime();

        vm.expectEmit();
        emit Settle(60e18, 30e18);
        handler.settle();

        // Verify state reset
        assertEq(handler.locked(), 0);
        assertEq(handler.settleAmt(), 0);
        assertEq(handler.depositCapacity(), 0);
        assertEq(handler.withdrawCapacity(), 0);

        // Verify _settle was called
        assertEq(handler.settleCalled(), 1);

        // Verify queues unlocked
        assertEq(depositQueue.locked(), 0);
        assertEq(withdrawQueue.locked(), 0);
    }

    function testSettleNotLockedReverts() public {
        vm.expectRevert("LCTSHandlerBase/not-locked");
        handler.settle();
    }

    function testSettleTooEarlyReverts() public {
        _warpToLockWindow();
        handler.lock();
        handler.plan(0, 0, 0);

        // Still in lock window, before end
        vm.expectRevert("LCTSHandlerBase/settle-too-early");
        handler.settle();
    }

    function testSettleAtExactEndAllowed() public {
        _warpToLockWindow();
        handler.lock();
        handler.plan(0, 0, 0);

        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 16 hours);

        handler.settle();
        assertEq(handler.locked(), 0);
    }

    function testSettleIsPermissionless() public {
        _warpToLockWindow();
        handler.lock();
        handler.plan(0, 0, 0);
        _warpToSettleTime();

        // Anyone can call settle
        vm.prank(alice);
        handler.settle();

        assertEq(handler.locked(), 0);
    }

    function testSettleWithZeroCapacities() public {
        _seedDepositQueue(100e18);
        _seedWithdrawQueue(50e18);

        _lockPlanSettle(0, 0, 0);

        // Queues should be unchanged
        assertEq(depositQueue.totalUnderlying(), 100e18);
        assertEq(withdrawQueue.totalUnderlying(), 50e18);
    }

    function testSettleProcessesQueues() public {
        _seedDepositQueue(100e18);
        _seedWithdrawQueue(50e18);

        _lockPlanSettle(0, 100e18, 50e18);

        // Deposit queue fully drained
        assertEq(depositQueue.currentGen(), 1);

        // Withdraw queue fully drained
        assertEq(withdrawQueue.currentGen(), 1);
    }

    function testSettlePartialCapacity() public {
        _seedDepositQueue(100e18);
        _seedWithdrawQueue(100e18);

        _lockPlanSettle(0, 40e18, 30e18);

        assertEq(depositQueue.totalUnderlying(), 60e18);
        assertEq(withdrawQueue.totalUnderlying(), 70e18);
    }

    // --- Full Cycle Tests ---

    function testMultipleCyclesAcrossDays() public {
        _seedDepositQueue(200e18);

        // Day 1: partial settle
        _lockPlanSettle(0, 100e18, 0);
        assertEq(depositQueue.totalUnderlying(), 100e18);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Day 2: settle the rest
        _lockPlanSettle(0, 100e18, 0);
        assertEq(depositQueue.currentGen(), 1);
    }

    function testSettleResetsAllParams() public {
        _warpToLockWindow();
        handler.lock();
        handler.plan(int256(500e18), 200e18, 300e18);
        _warpToSettleTime();

        handler.settle();

        assertEq(handler.locked(), 0);
        assertEq(handler.settleAmt(), 0);
        assertEq(handler.depositCapacity(), 0);
        assertEq(handler.withdrawCapacity(), 0);
    }
}
