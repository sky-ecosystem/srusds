// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { Venture } from "src/Venture.sol";
import { VentureHandler } from "src/VentureHandler.sol";

contract VentureHandlerTest is DssTest {
    MockERC20    gem;
    Venture        token;
    VentureHandler handler;

    address buffer = address(0xBFFE8);

    address alice = address(0xA11CE);

    // --- Events ---

    event Lock();
    event Plan(int256 profit, uint256 depositCapacity, uint256 withdrawCapacity);
    event Settle(uint256 depositsConverted, uint256 withdrawsConverted);

    function setUp() public {
        gem = new MockERC20("Gem", "GEM");

        token = Venture(address(new ERC1967Proxy(
            address(new Venture()),
            abi.encodeCall(Venture.initialize, ())
        )));

        handler = _deployHandler();

        // Handler needs auth to call settle(), mint() and burn() on the token
        token.rely(address(handler));
        handler.file("buffer", buffer);

        // The buffer lets the handler pull the backing it needs
        vm.prank(buffer); gem.approve(address(handler), type(uint256).max);

        // Seed outstanding shares, with their backing sitting at the buffer
        token.mint(1_000e18, address(this));
        gem.mint(buffer, 1_000e18);

        // Configure daily window: lock at 13:00-14:00, settle at 16:00
        handler.file("settleTime",  16 hours);
        handler.file("lockTimeEnd", 14 hours);
        handler.file("lockTimeBgn", 13 hours);
    }

    // Helper: deploy a handler wired to the same token and gem
    function _deployHandler() internal returns (VentureHandler) {
        return new VentureHandler(address(gem), address(token));
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

    // Helper: seed deposit queue with gem, joined by alice
    function _seedDepositQueue(uint256 amount) internal {
        gem.mint(alice, amount);
        vm.startPrank(alice);
        gem.approve(address(handler), amount);
        handler.claimVentureAndJoinGem(alice, amount);
        vm.stopPrank();
    }

    // Helper: seed withdraw queue with Venture shares, joined by alice
    function _seedWithdrawQueue(uint256 amount) internal {
        token.mint(amount, alice);
        gem.mint(buffer, amount * token.chi() / RAY);
        vm.startPrank(alice);
        token.approve(address(handler), amount);
        handler.claimGemAndJoinVenture(alice, amount);
        vm.stopPrank();
    }

    // Helpers: read single fields out of the queue getters
    function _depositGen() internal view returns (uint256 gen) {
        (gen, , ) = handler.deposits();
    }

    function _withdrawGen() internal view returns (uint256 gen) {
        (gen, , ) = handler.withdrawals();
    }

    function _depositUnderlying() internal view returns (uint256 totalUnderlying) {
        (, , totalUnderlying) = handler.deposits();
    }

    function _withdrawUnderlying() internal view returns (uint256 totalUnderlying) {
        (, , totalUnderlying) = handler.withdrawals();
    }

    // Helper: full lock -> plan -> settle cycle
    function _lockPlanSettle(
        int256 profit_,
        uint256 depositCap,
        uint256 withdrawCap
    ) internal {
        _warpToLockWindow();
        handler.lock();
        handler.plan(profit_, depositCap, withdrawCap);
        _warpToSettleTime();
        handler.settle();
    }

    // --- Auth Tests ---

    function testConstructor() public {
        vm.expectEmit();
        emit Rely(address(this));
        VentureHandler h = _deployHandler();

        assertEq(h.wards(address(this)), 1);
        assertEq(address(h.venture()), address(token));
        assertEq(address(h.gem()),   address(gem));

        // Both queues start empty at generation zero
        (uint256 depositGen, uint256 depositShares, uint256 depositUnderlying) = h.deposits();
        assertEq(depositGen, 0);
        assertEq(depositShares, 0);
        assertEq(depositUnderlying, 0);
        (uint256 withdrawGen, uint256 withdrawShares, uint256 withdrawUnderlying) = h.withdrawals();
        assertEq(withdrawGen, 0);
        assertEq(withdrawShares, 0);
        assertEq(withdrawUnderlying, 0);
    }

    function testAuth() public {
        checkAuth(address(handler), "VentureHandler");
    }

    function testModifiers() public {
        bytes4[] memory authedMethods = new bytes4[](2);
        authedMethods[0] = handler.lock.selector;
        authedMethods[1] = handler.plan.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(handler), "VentureHandler/not-authorized", authedMethods);
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
        checkFileUint(address(handler), "VentureHandler", ["lockTimeBgn", "lockTimeEnd", "settleTime"]);
    }

    function testFileLockTimeBgn() public {
        vm.expectEmit();
        emit File("lockTimeBgn", 12 hours);
        handler.file("lockTimeBgn", 12 hours);

        assertEq(handler.lockTimeBgn(), 12 hours);
    }

    function testFileLockTimeEnd() public {
        vm.expectEmit();
        emit File("lockTimeEnd", 13.5 hours);
        handler.file("lockTimeEnd", 13.5 hours);

        assertEq(handler.lockTimeEnd(), 13.5 hours);
    }

    function testFileSettleTime() public {
        vm.expectEmit();
        emit File("settleTime", 17 hours);
        handler.file("settleTime", 17 hours);

        assertEq(handler.settleTime(), 17 hours);
    }

    function testFileLockTimeBgnTooLargeReverts() public {
        vm.expectRevert("VentureHandler/incorrect-time-in-day");
        handler.file("lockTimeBgn", 24 hours);
    }

    function testFileLockTimeEndTooLargeReverts() public {
        vm.expectRevert("VentureHandler/incorrect-time-in-day");
        handler.file("lockTimeEnd", 24 hours);
    }

    function testFileSettleTimeTooLargeReverts() public {
        vm.expectRevert("VentureHandler/incorrect-time-in-day");
        handler.file("settleTime", 24 hours);
    }

    function testFileLockTimeBgnNotLessLockEndReverts() public {
        // lockTimeBgn = 15h >= lockTimeEnd = 14h
        vm.expectRevert("VentureHandler/not-less-lock-end");
        handler.file("lockTimeBgn", 15 hours);
    }

    function testFileLockTimeEndNotGreaterLockBgnReverts() public {
        // lockTimeEnd = 12h <= lockTimeBgn = 13h
        vm.expectRevert("VentureHandler/not-greater-lock-bgn");
        handler.file("lockTimeEnd", 12 hours);
    }

    function testFileSettleTimeNotGreaterLockEndReverts() public {
        // settleTime = 13.5h <= lockTimeEnd = 14h
        vm.expectRevert("VentureHandler/not-greater-lock-end");
        handler.file("settleTime", 13.5 hours);
    }

    function testFileLockTimeEndNotLessSettleReverts() public {
        // lockTimeEnd = 17h >= settleTime = 16h
        vm.expectRevert("VentureHandler/not-less-settle");
        handler.file("lockTimeEnd", 17 hours);
    }

    function testFileBootstrapOrder() public {
        // Deploy fresh handler with defaults (all 0)
        VentureHandler h = _deployHandler();

        // Must set settleTime first (> lockTimeBgn=0, > lockTimeEnd=0)
        h.file("settleTime", 20 hours);
        assertEq(h.settleTime(), 20 hours);

        // Then lockTimeEnd (> lockTimeBgn=0, < settleTime=20h)
        h.file("lockTimeEnd", 15 hours);
        assertEq(h.lockTimeEnd(), 15 hours);

        // Then lockTimeBgn (< lockTimeEnd=15h, < settleTime=20h)
        h.file("lockTimeBgn", 10 hours);
        assertEq(h.lockTimeBgn(), 10 hours);
    }

    // --- Lock Tests ---

    function testLock() public {
        _warpToLockWindow();

        vm.expectEmit();
        emit Lock();
        handler.lock();

        assertEq(handler.locked(), 1);
    }

    function testLockTooEarlyReverts() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 12 hours + 59 minutes);

        vm.expectRevert("VentureHandler/lock-too-early");
        handler.lock();
    }

    function testLockTooLateReverts() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 14 hours + 1);

        vm.expectRevert("VentureHandler/lock-too-late");
        handler.lock();
    }

    function testLockAtExactBgnAllowed() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 13 hours);

        handler.lock();
        assertEq(handler.locked(), 1);
    }

    function testLockAtExactLockTimeEndAllowed() public {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 14 hours);

        handler.lock();
        assertEq(handler.locked(), 1);
    }

    function testLockAlreadyLockedReverts() public {
        _warpToLockWindow();
        handler.lock();

        vm.expectRevert("VentureHandler/already-locked");
        handler.lock();
    }

    // --- Plan Tests ---

    function testPlan() public {
        _warpToLockWindow();
        handler.lock();

        vm.expectEmit();
        emit Plan(100, 200e18, 300e18);
        handler.plan(100, 200e18, 300e18);

        assertEq(handler.profit(), 100);
        assertEq(handler.depositCapacity(), 200e18);
        assertEq(handler.withdrawCapacity(), 300e18);
    }

    function testPlanNegativeSettleAmt() public {
        _warpToLockWindow();
        handler.lock();

        handler.plan(-50, 0, 0);
        assertEq(handler.profit(), -50);
    }

    function testPlanOverwritesPrevious() public {
        _warpToLockWindow();
        handler.lock();

        handler.plan(100, 200e18, 300e18);
        handler.plan(-50, 10e18, 20e18);

        assertEq(handler.profit(), -50);
        assertEq(handler.depositCapacity(), 10e18);
        assertEq(handler.withdrawCapacity(), 20e18);
    }

    function testPlanNotLockedReverts() public {
        vm.expectRevert("VentureHandler/not-locked");
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
        assertEq(handler.profit(), 0);
        assertEq(handler.depositCapacity(), 0);
        assertEq(handler.withdrawCapacity(), 0);
    }

    function testSettlePositiveAmt() public {
        uint256 chiBefore    = token.chi();
        uint256 assetsBefore = token.totalAssets();

        _lockPlanSettle(int256(100e18), 0, 0);

        // Revaluation only — a gain needs no gem on hand, it lives at the buffer
        assertEq(token.chi(), chiBefore * (assetsBefore + 100e18) / assetsBefore);
        assertEq(token.totalAssets(), assetsBefore + 100e18);
        assertEq(gem.balanceOf(address(handler)), 0);
    }

    function testSettleNegativeAmt() public {
        uint256 chiBefore    = token.chi();
        uint256 assetsBefore = token.totalAssets();

        _lockPlanSettle(-int256(100e18), 0, 0);

        assertEq(token.chi(), chiBefore * (assetsBefore - 100e18) / assetsBefore);
        assertEq(token.totalAssets(), assetsBefore - 100e18);
        assertEq(gem.balanceOf(address(handler)), 0);
    }

    function testSettleNotLockedReverts() public {
        vm.expectRevert("VentureHandler/not-locked");
        handler.settle();
    }

    // --- Buffer Tests ---

    function testFileBuffer() public {
        address newBuffer = address(0xBEEF5);

        vm.expectEmit();
        emit File(bytes32("buffer"), newBuffer);
        handler.file("buffer", newBuffer);

        assertEq(handler.buffer(), newBuffer);
    }

    function testFileUnrecognizedAddressReverts() public {
        vm.expectRevert("VentureHandler/file-unrecognized-param");
        handler.file("badWhat", address(0x123));
    }

    function testFileBufferZeroAddressReverts() public {
        vm.expectRevert("VentureHandler/buffer-zero-address");
        handler.file("buffer", address(0));
    }

    function testWithdrawConversionClampedByLiquidity() public {
        _seedWithdrawQueue(100e18);

        // The buffer only allows the handler 40 of the 100 planned
        vm.prank(buffer); gem.approve(address(handler), 40e18);

        _lockPlanSettle(0, 0, 100e18);

        // Converts what the venue can pay and leaves the generation open for the next cycle
        assertEq(_withdrawUnderlying(), 60e18);
        assertEq(_withdrawGen(), 0);
        assertEq(gem.balanceOf(address(handler)), 40e18);
    }

    function testWithdrawConversionClampedByBufferBalance() public {
        _seedWithdrawQueue(100e18);

        // Allowance is unlimited, but the buffer only holds 40 of the 100 planned
        uint256 excess = gem.balanceOf(buffer) - 40e18;
        vm.prank(buffer); gem.transfer(address(0xDEAD), excess);

        _lockPlanSettle(0, 0, 100e18);

        assertEq(_withdrawUnderlying(), 60e18);
        assertEq(_withdrawGen(), 0);
        assertEq(gem.balanceOf(address(handler)), 40e18);
    }

    function testWithdrawConversionWithNoLiquidityStillSettles() public {
        _seedWithdrawQueue(100e18);

        vm.prank(buffer); gem.approve(address(handler), 0);

        // settle() is permissionless and must not be blockable by the venue
        _lockPlanSettle(0, 0, 100e18);

        assertEq(_withdrawUnderlying(), 100e18);
        assertEq(_withdrawGen(), 0);
        assertEq(handler.locked(), 0);

        // Alice is not trapped meanwhile: she can take her position back
        vm.prank(alice);
        (, uint256 ventureAmt) = handler.claimGemAndExitVenture(alice, alice);
        assertEq(ventureAmt, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function testFullLifecycleWithGains() public {
        _seedDepositQueue(100e18);

        // Cycle 1: the venue earned 100 on the 1,000 outstanding, and alice's deposit converts
        _lockPlanSettle(int256(100e18), 100e18, 0);

        uint256 chiAfterGain = token.chi();
        assertEq(chiAfterGain, 1.1e27); // 1,000 shares at RAY, revalued by +100 assets

        // Her shares were minted at the post-gain chi, so she buys in at the current price
        uint256 expectedShares = 100e18 * RAY / chiAfterGain;
        vm.prank(alice); uint256 shares = handler.claimVenture(alice);
        assertLe(shares, expectedShares);
        assertApproxEqAbs(shares, expectedShares, 1e3);
        assertEq(token.balanceOf(alice), shares);

        // Her backing left for the buffer; the handler kept nothing
        assertEq(gem.balanceOf(address(handler)), 0);

        // Cycle 2: she queues the shares back out
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(alice);
        token.approve(address(handler), shares);
        handler.claimGemAndJoinVenture(alice, shares);
        vm.stopPrank();

        _lockPlanSettle(0, 0, shares);

        vm.prank(alice); uint256 gemBack = handler.claimGem(alice);

        // She gets her 100 back — never more, and short only by conversion rounding
        assertEq(gemBack, shares * chiAfterGain / RAY);
        assertLe(gemBack, 100e18);
        assertApproxEqAbs(gemBack, 100e18, 1e3);
        assertEq(gem.balanceOf(alice), gemBack);
        assertEq(gem.balanceOf(address(handler)), 0);
    }

    function testCustodyIsOnlyUserFunds() public {
        _seedDepositQueue(100e18);
        _seedWithdrawQueue(50e18);

        _lockPlanSettle(0, 60e18, 30e18);

        // Gem here == queued deposits (40) + withdraw rewards owed out (30)
        assertEq(_depositUnderlying(), 40e18);
        assertEq(gem.balanceOf(address(handler)), 40e18 + 30e18);

        // Venture here == queued withdrawals (20) + deposit rewards owed out (60)
        assertEq(_withdrawUnderlying(), 20e18);
        assertEq(token.balanceOf(address(handler)), 20e18 + 60e18);

        // The converted deposit backing is the only thing that left
        assertEq(gem.balanceOf(buffer), 1_000e18 + 50e18 + 60e18 - 30e18);
    }

    function testSettleTooEarlyReverts() public {
        _warpToLockWindow();
        handler.lock();
        handler.plan(0, 0, 0);

        // Still in lock window, before end
        vm.expectRevert("VentureHandler/settle-too-early");
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
        assertEq(_depositUnderlying(), 100e18);
        assertEq(_withdrawUnderlying(), 50e18);
    }

    function testSettleProcessesQueues() public {
        _seedDepositQueue(100e18);
        _seedWithdrawQueue(50e18);

        _lockPlanSettle(0, 100e18, 50e18);

        // Deposit queue fully drained
        assertEq(_depositGen(), 1);

        // Withdraw queue fully drained
        assertEq(_withdrawGen(), 1);
    }

    function testSettlePartialCapacity() public {
        _seedDepositQueue(100e18);
        _seedWithdrawQueue(100e18);

        _lockPlanSettle(0, 40e18, 30e18);

        assertEq(_depositUnderlying(), 60e18);
        assertEq(_withdrawUnderlying(), 70e18);
    }

    // --- Full Cycle Tests ---

    function testMultipleCyclesAcrossDays() public {
        _seedDepositQueue(200e18);

        // Day 1: partial settle
        _lockPlanSettle(0, 100e18, 0);
        assertEq(_depositUnderlying(), 100e18);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Day 2: settle the rest
        _lockPlanSettle(0, 100e18, 0);
        assertEq(_depositGen(), 1);
    }

    function testSettleResetsAllParams() public {
        _warpToLockWindow();
        handler.lock();
        handler.plan(int256(500e18), 200e18, 300e18);
        _warpToSettleTime();

        handler.settle();

        assertEq(handler.locked(), 0);
        assertEq(handler.profit(), 0);
        assertEq(handler.depositCapacity(), 0);
        assertEq(handler.withdrawCapacity(), 0);
    }
}
