// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { VatMock } from "test/mocks/VatMock.sol";
import { UsdsMock } from "test/mocks/UsdsMock.sol";
import { UsdsJoinMock } from "test/mocks/UsdsJoinMock.sol";
import { SUsdsMock } from "test/mocks/SUsdsMock.sol";

import { SrUsds } from "src/SrUsds.sol";
import { SrUsdsQueues, Initializable } from "src/SrUsdsQueues.sol";

contract SrUsdsQueuesTest is DssTest {
    VatMock      vat;
    UsdsMock     usds;
    UsdsJoinMock join;
    SUsdsMock    susds;
    SrUsds       srusds;
    SrUsdsQueues queues;

    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address carol    = address(0xCA201);
    address operator = address(0x0b);
    address constant VOW = address(0x5EE);

    event Settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity, uint256 depositsConverted, uint256 depositsReceived, uint256 redeemsConverted, uint256 redeemsReceived);
    event SetOperator(address indexed controller, address indexed operator, bool approved);
    event QueueDeposit(address indexed controller, address indexed owner, address sender, uint256 assets);
    event Referral(address indexed controller, uint256 assets, uint16 indexed referral);
    event QueueRedeem(address indexed controller, address indexed owner, address sender, uint256 shares);
    event CancelDeposit(address indexed controller, address indexed receiver, address sender, uint256 assets);
    event CancelRedeem(address indexed controller, address indexed receiver, address sender, uint256 shares);
    event ClaimDeposit(address indexed controller, address indexed receiver, address sender, uint256 shares);
    event ClaimRedeem(address indexed controller, address indexed receiver, address sender, uint256 assets);

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
        queues = SrUsdsQueues(address(new ERC1967Proxy(
            address(new SrUsdsQueues(address(srusds))),
            abi.encodeCall(SrUsdsQueues.initialize, ())
        )));
        srusds.rely(address(queues));

        // Daily settlement, window 13:00-16:00
        queues.file("period", 1);
        queues.file("lockTimeEnd", 16 hours);
        queues.file("lockTimeBgn", 13 hours);

        vm.warp(20_000 days + 10 hours); // Some morning, outside the window
    }

    // --- Helpers ---

    function _queueDeposit(address usr, uint256 assets) internal {
        susds.mint(usr, assets);
        vm.startPrank(usr);
        susds.approve(address(queues), assets);
        queues.queueDeposit(assets, usr, usr, 0);
        vm.stopPrank();
    }

    /// @dev Mint `usr` srUSDS for `assets` sUSDS at the current chi, returning the shares
    function _mintSrUsds(address usr, uint256 assets) internal returns (uint256 shares) {
        susds.mint(address(this), assets);
        susds.approve(address(srusds), assets);
        shares = srusds.deposit(assets, usr);
    }

    function _queueRedeem(address usr, uint256 shares) internal {
        vm.startPrank(usr);
        srusds.approve(address(queues), shares);
        queues.queueRedeem(shares, usr, usr);
        vm.stopPrank();
    }

    function _nextDay() internal view returns (uint256) {
        return (block.timestamp / 1 days + 1) * 1 days;
    }

    /// @dev Settle in tomorrow's window
    function _settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) internal {
        vm.warp(_nextDay() + 14 hours);
        queues.settle(profit, depositCapacity, redeemCapacity);
    }

    /// @dev Everything still to convert: unconverted in the pool and held for the next settlement
    function _depositPending() internal view returns (uint256) {
        (,, uint256 unconverted,, uint256 held) = queues.depositQueue();
        return unconverted + held;
    }

    /// @dev Settle the deposit queue with no profit, returning what converted
    function _settleDeposit(uint256 capacity) internal returns (uint256 converted) {
        uint256 before = _depositPending();
        _settle(0, capacity, 0);
        converted = before - _depositPending();
    }

    /// @dev Settle converting `bps` of what is queued in the deposit queue
    function _settleFraction(uint256 bps) internal returns (uint256 converted) {
        converted = _settleDeposit(_depositPending() * bps / 10_000);
    }

    /// @dev A stored position, read straight from storage. depositQueue is at slot 2 and redeemQueue at slot 8;
    ///      positions is the Queue struct's 6th member (after cycle, units, unconverted, converted and held), so
    ///      the mappings live at slots 7 and 13
    function _position(uint256 slot, address usr) internal view returns (uint256 units, uint256 cycle, uint256 claimable) {
        bytes32 base = keccak256(abi.encode(usr, slot));
        units     = uint256(vm.load(address(queues), base));
        cycle     = uint256(vm.load(address(queues), bytes32(uint256(base) + 1)));
        claimable = uint256(vm.load(address(queues), bytes32(uint256(base) + 2)));
    }

    function _depositPosition(address usr) internal view returns (uint256 units, uint256 cycle, uint256 claimable) {
        return _position(7, usr);
    }

    function _redeemPosition(address usr) internal view returns (uint256 units, uint256 cycle, uint256 claimable) {
        return _position(13, usr);
    }

    // --- Administration ---

    function testConstructorAndInitialize() public {
        assertEq(address(queues.share()), address(srusds));
        assertEq(address(queues.asset()), address(susds));
        assertEq(queues.wards(address(this)), 1);
        assertEq(susds.allowance(address(queues), address(srusds)), type(uint256).max);
        assertEq(queues.lockTimeBgn(), 13 hours);
        assertEq(queues.lockTimeEnd(), 16 hours);
        assertEq(queues.period(), 1);
        assertEq(queues.startDay(), 0);
        assertEq(queues.lastSettleDay(), 0);
    }

    function testInitializeAgain() public {
        SrUsdsQueues implementation = SrUsdsQueues(queues.getImplementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        queues.initialize();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize();
    }

    function testAuth() public {
        checkAuth(address(queues), "SrUsdsQueues");
    }

    function testModifiers() public {
        bytes4[] memory authedMethods = new bytes4[](1);
        authedMethods[0] = queues.settle.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(queues), "SrUsdsQueues/not-authorized", authedMethods);
        vm.stopPrank();
    }

    function testFile() public {
        checkFileUint(address(queues), "SrUsdsQueues", ["lockTimeBgn", "lockTimeEnd", "period", "startDay"]);
    }

    function testFileReverts() public {
        vm.expectRevert("SrUsdsQueues/incorrect-time-in-day");
        queues.file("lockTimeBgn", 1 days);
        vm.expectRevert("SrUsdsQueues/not-less-lock-end");
        queues.file("lockTimeBgn", 16 hours);
        vm.expectRevert("SrUsdsQueues/incorrect-time-in-day");
        queues.file("lockTimeEnd", 1 days + 1);
        vm.expectRevert("SrUsdsQueues/not-greater-lock-bgn");
        queues.file("lockTimeEnd", 13 hours);
        vm.expectRevert("SrUsdsQueues/zero-period");
        queues.file("period", 0);
        vm.expectRevert("SrUsdsQueues/period-overflow");
        queues.file("period", uint256(type(uint32).max) + 1);
        vm.expectRevert("SrUsdsQueues/startDay-overflow");
        queues.file("startDay", uint256(type(uint32).max) + 1);

        queues.file("lockTimeEnd", 1 days); // The window may close at midnight
        assertEq(queues.lockTimeEnd(), 1 days);
    }

    function testUpgrade() public {
        address oldImpl = queues.getImplementation();
        address newImpl = address(new SrUsdsQueues(address(srusds)));

        vm.expectRevert("SrUsdsQueues/not-authorized");
        vm.prank(alice); queues.upgradeToAndCall(newImpl, "");

        queues.upgradeToAndCall(newImpl, "");
        assertEq(queues.getImplementation(), newImpl);
        assertTrue(newImpl != oldImpl);
        assertEq(queues.wards(address(this)), 1);
    }

    // --- Settlement window ---

    /// Locked on a settlement day from lockTimeBgn until lockTimeEnd or the settlement, whichever is first
    function testLocked() public {
        uint256 day = _nextDay();
        vm.warp(day + 13 hours - 1); assertFalse(queues.locked());
        vm.warp(day + 13 hours);     assertTrue(queues.locked());
        vm.warp(day + 16 hours - 1); assertTrue(queues.locked());
        vm.warp(day + 16 hours);     assertFalse(queues.locked());

        vm.warp(day + 14 hours);
        queues.settle(0, 0, 0);
        assertEq(queues.lastSettleDay(), day / 1 days);
        assertFalse(queues.locked());
        vm.warp(day + 15 hours);     assertFalse(queues.locked());

        vm.warp(day + 1 days + 14 hours); assertTrue(queues.locked()); // Next day is a new settlement day
    }

    /// Only every `period` days from `startDay`
    function testLockedOnSettlementDaysOnly() public {
        uint256 day = _nextDay();
        queues.file("period", 7);
        queues.file("startDay", day / 1 days + 7);

        vm.warp(day + 14 hours);           assertFalse(queues.locked()); // Before the schedule starts
        vm.warp(day + 7 days + 14 hours);  assertTrue(queues.locked());  // startDay
        vm.warp(day + 8 days + 14 hours);  assertFalse(queues.locked());
        vm.warp(day + 14 days + 14 hours); assertTrue(queues.locked());
    }

    function testSettleNotLockedReverts() public {
        vm.expectRevert("SrUsdsQueues/not-locked");
        queues.settle(0, 0, 0);

        _settle(0, 0, 0);
        vm.expectRevert("SrUsdsQueues/not-locked"); // Once per settlement day
        queues.settle(0, 0, 0);
    }

    /// Requests and cancellations are closed while locked; claims are not
    function testRequestsClosedWhileLocked() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(50e18);
        uint256 shares = _mintSrUsds(bob, 100e18);
        _queueRedeem(bob, shares);
        susds.mint(alice, 1e18);
        vm.prank(alice); susds.approve(address(queues), 1e18);

        vm.warp(_nextDay() + 14 hours);
        assertTrue(queues.locked());

        vm.startPrank(alice);
        vm.expectRevert("SrUsdsQueues/queue-locked");
        queues.queueDeposit(1e18, alice, alice, 0);
        vm.expectRevert("SrUsdsQueues/queue-locked");
        queues.cancelDeposit(alice, alice);
        assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 50e18);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("SrUsdsQueues/queue-locked");
        queues.queueRedeem(1, bob, bob);
        vm.expectRevert("SrUsdsQueues/queue-locked");
        queues.cancelRedeem(bob, bob);
        vm.stopPrank();
    }

    // --- Requests ---

    function testQueueDeposit() public {
        susds.mint(alice, 100e18);
        vm.startPrank(alice);
        susds.approve(address(queues), 100e18);
        vm.expectEmit();
        emit QueueDeposit(alice, alice, alice, 100e18);
        vm.expectEmit();
        emit Referral(alice, 100e18, 7);
        queues.queueDeposit(100e18, alice, alice, 7);
        vm.stopPrank();

        (uint256 cycle, uint256 units, uint256 unconverted, uint256 converted, uint256 held) = queues.depositQueue();
        assertEq(cycle, 0);
        assertEq(units, 0);     // Held until the next settlement, not in the pool yet
        assertEq(unconverted, 0);
        assertEq(converted, 0);
        assertEq(held, 100e18);
        (uint256 posUnits, uint256 posCycle, uint256 claimable) = _depositPosition(alice);
        assertEq(posUnits, 100e18);
        assertEq(posCycle, 0);
        assertEq(claimable, 0);
        assertEq(susds.balanceOf(address(queues)), 100e18);
        assertEq(susds.balanceOf(alice), 0);
        assertEq(queues.pendingDeposit(alice), 100e18);
        assertEq(queues.claimableDeposit(alice), 0);
    }

    function testQueueRedeem() public {
        uint256 shares = _mintSrUsds(alice, 100e18);
        vm.startPrank(alice);
        srusds.approve(address(queues), shares);
        vm.expectEmit();
        emit QueueRedeem(alice, alice, alice, shares);
        queues.queueRedeem(shares, alice, alice);
        vm.stopPrank();

        (uint256 cycle, uint256 units, uint256 unconverted,, uint256 held) = queues.redeemQueue();
        assertEq(cycle, 0);
        assertEq(units, 0);
        assertEq(unconverted, 0);
        assertEq(held, shares);
        assertEq(srusds.balanceOf(address(queues)), shares);
        assertEq(srusds.balanceOf(alice), 0);
        assertEq(queues.pendingRedeem(alice), shares);
    }

    function testQueueReverts() public {
        susds.mint(alice, 100e18);
        vm.prank(alice); susds.approve(address(queues), 100e18);

        vm.prank(alice); vm.expectRevert("SrUsdsQueues/zero-amount");
        queues.queueDeposit(0, alice, alice, 0);
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/controller-zero-address");
        queues.queueDeposit(100e18, address(0), alice, 0);
        vm.prank(bob); vm.expectRevert("SrUsdsQueues/not-operator"); // Not alice's operator
        queues.queueDeposit(100e18, bob, alice, 0);
        vm.prank(bob); vm.expectRevert("SrUsdsQueues/not-operator");
        queues.queueRedeem(1, bob, alice);
    }

    /// A controller may be given someone else's tokens; `owner` and `controller` are distinct roles
    function testQueueForAnotherController() public {
        susds.mint(alice, 100e18);
        vm.startPrank(alice);
        susds.approve(address(queues), 100e18);
        queues.queueDeposit(100e18, bob, alice, 0);
        vm.stopPrank();

        assertEq(queues.pendingDeposit(bob), 100e18);
        assertEq(queues.pendingDeposit(alice), 0);
        vm.prank(bob); assertEq(queues.cancelDeposit(bob, bob), 100e18);
        assertEq(susds.balanceOf(bob), 100e18);
    }

    /// An operator can request with the owner's tokens and cancel or claim as the controller, to any receiver
    function testOperator() public {
        susds.mint(alice, 100e18);
        vm.prank(alice); susds.approve(address(queues), 100e18);

        vm.prank(alice);
        vm.expectEmit();
        emit SetOperator(alice, operator, true);
        assertTrue(queues.setOperator(operator, true));
        assertTrue(queues.isOperator(alice, operator));

        vm.startPrank(operator);
        vm.expectEmit();
        emit QueueDeposit(alice, alice, operator, 100e18);
        queues.queueDeposit(100e18, alice, alice, 0);
        vm.stopPrank();
        _settleDeposit(50e18);
        vm.startPrank(operator);
        vm.expectEmit();
        emit ClaimDeposit(alice, carol, operator, 50e18);
        assertEq(queues.claimDeposit(type(uint256).max, carol, alice), 50e18);
        vm.expectEmit();
        emit CancelDeposit(alice, carol, operator, 50e18);
        assertEq(queues.cancelDeposit(carol, alice), 50e18);
        vm.stopPrank();
        assertEq(srusds.balanceOf(carol), 50e18);
        assertEq(susds.balanceOf(carol), 50e18);

        vm.prank(alice); queues.setOperator(operator, false);
        assertFalse(queues.isOperator(alice, operator));
        vm.prank(operator); vm.expectRevert("SrUsdsQueues/not-operator");
        queues.claimDeposit(0, alice, alice);
    }

    function testQueueTwiceAddsUnits() public {
        _queueDeposit(alice, 100e18);
        _queueDeposit(alice, 50e18);
        (uint256 units,,) = _depositPosition(alice);
        assertEq(units, 150e18);
        assertEq(queues.pendingDeposit(alice), 150e18);
    }

    /// A request made after a settlement is held: it joins the pool at the next one and takes no part in what
    /// was converted before, as long as the others have set their converted part aside (see the next test)
    function testHeldRequestJoinsAtNextSettlement() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(50e18);
        vm.prank(alice); queues.claimDeposit(0, alice, alice); // Sets alice's 50 aside, queues her other 50 again
        _queueDeposit(bob, 50e18);

        (, uint256 units,,, uint256 held) = queues.depositQueue();
        assertEq(units, 0);
        assertEq(held, 100e18);
        assertEq(queues.pendingDeposit(alice), 50e18);
        assertEq(queues.pendingDeposit(bob), 50e18);
        assertEq(queues.claimableDeposit(bob), 0);

        _settleDeposit(50e18);
        assertEq(queues.claimableDeposit(alice), 75e18);
        assertEq(queues.claimableDeposit(bob), 25e18);
    }

    // --- Fairness at claim time ---

    /// what Alice leaves in the pool over a settlement is shared with Bob, who joins then, and
    /// she gets a larger share of the pending side instead. Values are kept, converted amounts are not
    function testUnclaimedIsSharedAtNextSettlement() public {
        uint256 shares = _mintSrUsds(alice, 100e18);
        _queueRedeem(alice, shares);
        _settle(0, 0, 90e18);
        assertEq(queues.claimableRedeem(alice), 90e18);
        assertEq(queues.pendingRedeem(alice), 10e18);

        _queueRedeem(bob, _mintSrUsds(bob, 100e18));
        _settle(0, 0, 10e18);
        assertEq(queues.claimableRedeem(alice), 50e18);
        assertEq(queues.pendingRedeem(alice), 50e18);
        assertEq(queues.claimableRedeem(bob), 50e18);
        assertEq(queues.pendingRedeem(bob), 50e18);

        vm.prank(alice); assertEq(queues.claimRedeem(type(uint256).max, alice, alice), 50e18);
        vm.prank(bob);   assertEq(queues.claimRedeem(type(uint256).max, bob, bob), 50e18);
        _settle(0, 0, type(uint256).max);
        vm.prank(alice); assertEq(queues.claimRedeem(type(uint256).max, alice, alice), 50e18);
        vm.prank(bob);   assertEq(queues.claimRedeem(type(uint256).max, bob, bob), 50e18);
        assertEq(susds.balanceOf(alice), 100e18);
        assertEq(susds.balanceOf(bob), 100e18);
    }

    /// The same, with Alice claiming within the cycle: her 90 are hers and Bob only shares the next conversion
    function testClaimedIsNotShared() public {
        uint256 shares = _mintSrUsds(alice, 100e18);
        _queueRedeem(alice, shares);
        _settle(0, 0, 90e18);
        vm.prank(alice); assertEq(queues.claimRedeem(type(uint256).max, alice, alice), 90e18);

        _queueRedeem(bob, _mintSrUsds(bob, 100e18));
        _settle(0, 0, 10e18);
        assertEq(queues.claimableRedeem(alice), uint256(10e18) * 10 / 110);
        assertEq(queues.pendingRedeem(alice), uint256(100e18) * 10 / 110); // Both shares round down
        assertEq(queues.claimableRedeem(bob), uint256(10e18) * 100 / 110);
    }

    /// Any action of the controller sets the converted part aside, not only a claim
    function testAnyActionSetsConvertedAside() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(40e18);
        _queueDeposit(alice, 1); // Touches the position
        (,, uint256 stored) = _depositPosition(alice);
        assertEq(stored, 40e18);

        _queueDeposit(bob, 1_000_000e18);
        _settleDeposit(0);
        assertEq(queues.claimableDeposit(alice), 40e18); // Bob's join did not dilute what was set aside
        assertEq(queues.pendingDeposit(alice), 60e18 + 1);
    }

    /// The converted part of a redeem left in the pool over a settlement is exposed again to the share's losses
    function testUnclaimedRedeemIsExposedToLoss() public {
        uint256 shares = _mintSrUsds(alice, 100e18);
        _queueRedeem(alice, shares);
        _settle(0, 0, 90e18);
        _queueRedeem(bob, _mintSrUsds(bob, 100e18));

        _settle(-55e18, 0, 0); // Half of the 110 srUSDS outstanding (all of it queued): chi 0.5
        assertEq(srusds.chi(), 0.5e27);
        assertEq(queues.claimableRedeem(alice), 45e18);
        assertEq(queues.pendingRedeem(alice), 55e18);                    // 55 srUSDS, now worth 27.5 sUSDS
        assertEq(srusds.convertToAssets(queues.pendingRedeem(alice)), 27.5e18);
        // Had she claimed in time: 90 sUSDS plus 10 srUSDS worth 5
    }

    // --- Settle ---

    function testSettleConvertsBothQueues() public {
        _queueDeposit(alice, 100e18);
        uint256 shares = _mintSrUsds(bob, 100e18);
        _queueRedeem(bob, shares);

        vm.warp(_nextDay() + 14 hours);
        vm.expectEmit();
        emit Settle(0, 60e18, 30e18, 60e18, 60e18, 30e18, 30e18);
        queues.settle(0, 60e18, 30e18);

        (uint256 cycle, uint256 units, uint256 unconverted, uint256 converted, uint256 held) = queues.depositQueue();
        assertEq(cycle, 1);
        assertEq(units, 100e18);
        assertEq(unconverted, 40e18);
        assertEq(converted, 60e18);
        assertEq(held, 0);
        (cycle, units, unconverted, converted, held) = queues.redeemQueue();
        assertEq(cycle, 1);
        assertEq(units, 100e18);
        assertEq(unconverted, 70e18);
        assertEq(converted, 30e18);
        assertEq(held, 0);
        assertEq(queues.claimableDeposit(alice), 60e18);
        assertEq(queues.claimableRedeem(bob), 30e18);
        assertEq(srusds.balanceOf(address(queues)), 60e18 + 70e18); // Converted deposits and pending redeems
        assertEq(susds.balanceOf(address(queues)), 40e18 + 30e18);  // Pending deposits and converted redeems
    }

    function testSettleFullCapacity() public {
        _queueDeposit(alice, 100e18);
        assertEq(_settleDeposit(type(uint256).max), 100e18);

        (uint256 cycle, uint256 units, uint256 unconverted, uint256 converted,) = queues.depositQueue();
        assertEq(cycle, 1);
        assertEq(units, 100e18);
        assertEq(unconverted, 0);
        assertEq(converted, 100e18);
        assertEq(queues.pendingDeposit(alice), 0);
        assertEq(queues.claimableDeposit(alice), 100e18);
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/nothing-pending");
        queues.cancelDeposit(alice, alice);
    }

    function testSettleZeroCapacityAndEmptyQueue() public {
        _queueDeposit(alice, 100e18);
        assertEq(_settleDeposit(0), 0);
        assertEq(queues.pendingDeposit(alice), 100e18);
        (uint256 cycle, uint256 units,,,) = queues.depositQueue();
        assertEq(cycle, 1); // Every settlement is a cycle, converting or not
        assertEq(units, 100e18);

        vm.prank(alice); queues.cancelDeposit(alice, alice);
        assertEq(_settleDeposit(100e18), 0); // Nothing queued: converts nothing
        (cycle, units,,,) = queues.depositQueue();
        assertEq(cycle, 2);
        assertEq(units, 0);
    }

    /// The share is revalued before converting: deposits enter at the new price, redeems leave at it
    function testSettleRevaluesBeforeConverting() public {
        _mintSrUsds(carol, 100e18);         // Outstanding supply to revalue
        _queueDeposit(alice, 100e18);
        uint256 shares = _mintSrUsds(bob, 100e18);
        _queueRedeem(bob, shares);

        _settle(100e18, type(uint256).max, type(uint256).max); // +100 on 200 outstanding: chi 1.5
        assertEq(srusds.chi(), 1.5e27);
        assertEq(queues.claimableDeposit(alice), uint256(100e18) * 2 / 3);
        assertEq(queues.claimableRedeem(bob), 150e18);
    }

    /// Every position in the pool gets the same fraction of each conversion, whenever it joined (the README example)
    function testProportionalDistribution() public {
        _queueDeposit(alice, 100e18);
        _queueDeposit(bob, 300e18);
        _settleDeposit(200e18);
        assertEq(queues.claimableDeposit(alice), 50e18);
        assertEq(queues.claimableDeposit(bob), 150e18);
        assertEq(queues.pendingDeposit(alice), 50e18);
        assertEq(queues.pendingDeposit(bob), 150e18);

        vm.prank(alice); queues.claimDeposit(type(uint256).max, alice, alice);
        vm.prank(bob);   queues.claimDeposit(type(uint256).max, bob, bob);
        _queueDeposit(carol, 100e18);
        _settleDeposit(150e18);
        assertEq(queues.claimableDeposit(alice), 25e18);
        assertEq(queues.claimableDeposit(bob), 75e18);
        assertEq(queues.claimableDeposit(carol), 50e18);
    }

    // --- Cancel and claim ---

    function testCancelReturnsPendingKeepsClaimable() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(40e18);

        vm.prank(alice);
        vm.expectEmit();
        emit CancelDeposit(alice, bob, alice, 60e18);
        assertEq(queues.cancelDeposit(bob, alice), 60e18);

        assertEq(susds.balanceOf(bob), 60e18);
        assertEq(queues.pendingDeposit(alice), 0);
        assertEq(queues.claimableDeposit(alice), 40e18);
        (uint256 posUnits, uint256 posCycle, uint256 claimable) = _depositPosition(alice);
        assertEq(posUnits, 0);
        assertEq(posCycle, 0);
        assertEq(claimable, 40e18);
        (, uint256 units, uint256 unconverted, uint256 converted, uint256 held) = queues.depositQueue();
        assertEq(units, 0);
        assertEq(unconverted, 0);
        assertEq(converted, 0);
        assertEq(held, 0);

        vm.prank(alice); vm.expectRevert("SrUsdsQueues/nothing-pending");
        queues.cancelDeposit(alice, alice);
    }

    function testCancelHeld() public {
        _queueDeposit(alice, 100e18);
        vm.prank(alice); assertEq(queues.cancelDeposit(alice, alice), 100e18);
        (,,,, uint256 held) = queues.depositQueue();
        assertEq(held, 0);
        assertEq(susds.balanceOf(alice), 100e18);
    }

    function testCancelRedeem() public {
        uint256 shares = _mintSrUsds(alice, 100e18);
        _queueRedeem(alice, shares);
        _settle(0, 0, 25e18);

        vm.prank(alice);
        vm.expectEmit();
        emit CancelRedeem(alice, alice, alice, 75e18);
        assertEq(queues.cancelRedeem(alice, alice), 75e18);
        assertEq(srusds.balanceOf(alice), 75e18);
        assertEq(queues.claimableRedeem(alice), 25e18);
    }

    function testCancelReverts() public {
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/nothing-pending");
        queues.cancelDeposit(alice, alice);

        _queueDeposit(alice, 100e18);
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/receiver-zero-address");
        queues.cancelDeposit(address(0), alice);
        vm.prank(bob); vm.expectRevert("SrUsdsQueues/not-operator");
        queues.cancelDeposit(bob, alice);
    }

    function testClaim() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(40e18);
        assertEq(queues.claimableDeposit(alice), 40e18);

        vm.startPrank(alice);
        vm.expectEmit();
        emit ClaimDeposit(alice, bob, alice, 10e18);
        assertEq(queues.claimDeposit(10e18, bob, alice), 10e18);
        assertEq(srusds.balanceOf(bob), 10e18);
        assertEq(queues.claimableDeposit(alice), 30e18);
        assertEq(queues.pendingDeposit(alice), 60e18);

        vm.expectRevert("SrUsdsQueues/insufficient-claimable");
        queues.claimDeposit(30e18 + 1, alice, alice);
        assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 30e18);
        assertEq(srusds.balanceOf(alice), 30e18);
        assertEq(queues.claimableDeposit(alice), 0);
        assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 0); // Nothing to claim is fine
        vm.stopPrank();

        (uint256 units, uint256 cycle, uint256 claimable) = _depositPosition(alice);
        assertEq(units, 60e18); // Pending, held again for the next settlement
        assertEq(cycle, 1);
        assertEq(claimable, 0);
    }

    /// A claim takes the position out of the pool and queues its pending part again: it is converted at the
    /// next settlement just the same, and the position no longer shares what it had converted with anyone
    function testClaimRequeuesPending() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(40e18);
        vm.prank(alice); queues.claimDeposit(type(uint256).max, alice, alice);

        (, uint256 units, uint256 unconverted, uint256 converted, uint256 held) = queues.depositQueue();
        assertEq(units, 0);
        assertEq(unconverted, 0);
        assertEq(converted, 0);
        assertEq(held, 60e18);

        assertEq(_settleDeposit(type(uint256).max), 60e18);
        assertEq(queues.claimableDeposit(alice), 60e18);
        assertEq(queues.pendingDeposit(alice), 0);
    }

    /// Claims are open while locked: they move pending from the pool to the held balance, so what is still
    /// to convert does not change under the facilitator's plan
    function testClaimWhileLockedKeepsTotals() public {
        _queueDeposit(alice, 100e18);
        _queueDeposit(bob, 100e18);
        _settleDeposit(50e18);
        vm.warp(_nextDay() + 14 hours);
        assertTrue(queues.locked());

        uint256 before = _depositPending();
        vm.prank(alice); assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 25e18);
        assertEq(_depositPending(), before);
        (, uint256 units, uint256 unconverted, uint256 converted, uint256 held) = queues.depositQueue();
        assertEq(units, 100e18);
        assertEq(unconverted, 75e18);
        assertEq(converted, 25e18);
        assertEq(held, 75e18);

        queues.settle(0, 150e18, 0);
        assertEq(queues.claimableDeposit(alice), 75e18);
        assertEq(queues.claimableDeposit(bob), 100e18);
    }

    function testClaimRedeem() public {
        uint256 shares = _mintSrUsds(alice, 100e18);
        _queueRedeem(alice, shares);
        _settle(0, 0, 25e18);

        vm.prank(alice);
        vm.expectEmit();
        emit ClaimRedeem(alice, alice, alice, 25e18);
        assertEq(queues.claimRedeem(type(uint256).max, alice, alice), 25e18);
        assertEq(susds.balanceOf(alice), 25e18);
        (uint256 units, uint256 cycle, uint256 claimable) = _redeemPosition(alice);
        assertEq(units, 75e18);
        assertEq(cycle, 1);
        assertEq(claimable, 0);
    }

    function testClaimReverts() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(40e18);
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/receiver-zero-address");
        queues.claimDeposit(1, address(0), alice);
        vm.prank(bob); vm.expectRevert("SrUsdsQueues/not-operator");
        queues.claimDeposit(1, bob, alice);
    }

    /// Converted amounts accrue in the pool across settlements and a claim collects all of them
    function testClaimAccruesAcrossSettlements() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(25e18);
        _settleDeposit(25e18);
        assertEq(queues.claimableDeposit(alice), 50e18);
        (,, uint256 stored) = _depositPosition(alice);
        assertEq(stored, 0); // Nothing set aside until the position is touched

        _queueDeposit(alice, 10e18);
        (,, stored) = _depositPosition(alice);
        assertEq(stored, 50e18);
        _settleDeposit(30e18);
        assertEq(queues.claimableDeposit(alice), 80e18);
        vm.prank(alice); assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 80e18);
    }

    // --- Precision ---

    /// Partial fills never degrade the accounting: the pool keeps what it converts, so units never outgrow
    /// what they are worth and a request can be filled in as many steps as it takes
    function testManyPartialFillsStayExact() public {
        _queueDeposit(alice, 1_000_000e18);
        _queueDeposit(bob, 1);
        for (uint256 i; i < 90; i++) _settleFraction(50_00); // Down to the last wei, which a half fill leaves
        assertEq(_depositPending(), 1);
        assertEq(queues.claimableDeposit(alice), 1_000_000e18 - 1); // Both round down against the last wei
        assertEq(queues.claimableDeposit(bob), 0);

        assertEq(_settleDeposit(type(uint256).max), 1);
        assertEq(queues.claimableDeposit(alice), 1_000_000e18);
        assertEq(queues.claimableDeposit(bob), 1);
        assertEq(queues.pendingDeposit(alice), 0);
    }

    function testFuzzSettle(uint256 depositAmt, uint256 capacity) public {
        depositAmt = bound(depositAmt, 1e18, 1_000_000e18);
        capacity   = bound(capacity, 0, 2_000_000e18);
        _queueDeposit(alice, depositAmt);

        uint256 converted = _settleDeposit(capacity);
        assertEq(converted, capacity < depositAmt ? capacity : depositAmt);
        assertEq(queues.pendingDeposit(alice), depositAmt - converted);
        assertEq(queues.claimableDeposit(alice), converted);
    }

    /// However joins, fills, drains, cancels and claims interleave, every user ends up with what they put in
    /// (as srUSDS at 1:1 plus returned sUSDS) up to rounding dust, which stays in the pool for whoever is next
    function testFuzzEveryoneIsMadeWhole(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256[3] memory put;
        uint256[3] memory got;

        for (uint256 i; i < 120; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 u = r % 3;
            if (r >> 8 & 3 == 0) {
                uint256 amt = bound(r >> 16, 1, 1_000e18);
                _queueDeposit(users[u], amt);
                put[u] += amt;
            }
            if (r >> 64 & 7 == 0 && queues.pendingDeposit(users[u]) > 0) {
                vm.prank(users[u]); got[u] += queues.cancelDeposit(users[u], users[u]);
            }
            if (r >> 96 & 7 == 0) {
                vm.prank(users[u]); got[u] += queues.claimDeposit(type(uint256).max, users[u], users[u]);
            }
            _settleFraction(r >> 104 & 15 == 0 ? 10_000 : bound(r >> 128, 0, 99_99));
        }

        _settleFraction(10_000);
        for (uint256 u; u < 3; u++) {
            assertEq(queues.pendingDeposit(users[u]), 0);
            vm.prank(users[u]); got[u] += queues.claimDeposit(type(uint256).max, users[u], users[u]);
            // Each exit rounds its share of both balances down by under a wei, and the dust goes to the pool
            assertApproxEqAbs(got[u], put[u], 2 * 120);
        }
        assertLe(susds.balanceOf(address(queues)), 2 * 120);
        assertLe(srusds.balanceOf(address(queues)), 2 * 120);
    }
}
