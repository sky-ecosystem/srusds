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

    uint256 constant MAX_SHARE_RATIO = 10 ** 9;

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

    /// @dev Settle the deposit queue with no profit, returning what converted
    function _settleDeposit(uint256 capacity) internal returns (uint256 converted) {
        (,, uint256 before) = queues.depositQueue();
        _settle(0, capacity, 0);
        (,, uint256 after_) = queues.depositQueue();
        converted = before - after_;
    }

    /// @dev Settle converting `bps` of the deposit queue
    function _settleFraction(uint256 bps) internal returns (uint256 converted) {
        (,, uint256 before) = queues.depositQueue();
        converted = _settleDeposit(before * bps / 10_000);
    }

    function _depositGen() internal view returns (uint256 gen) {
        (gen,,) = queues.depositQueue();
    }

    function _depositRatio() internal view returns (uint256) {
        (, uint256 shares, uint256 underlying) = queues.depositQueue();
        return underlying == 0 ? 0 : shares / underlying; // Drained: nothing to measure
    }

    /// @dev A stored position, read straight from storage. depositQueue is at slot 2 and redeemQueue at slot 7;
    ///      positions is the Queue struct's 5th member (after currentGen, totalShares, totalUnderlying and
    ///      rewardPerToken), so the mappings live at slots 6 and 11
    function _position(uint256 slot, address usr) internal view returns (uint256 gen, uint256 shares, uint256 rewardDebt, uint256 claimable) {
        bytes32 base = keccak256(abi.encode(usr, slot));
        gen        = uint256(vm.load(address(queues), base));
        shares     = uint256(vm.load(address(queues), bytes32(uint256(base) + 1)));
        rewardDebt = uint256(vm.load(address(queues), bytes32(uint256(base) + 2)));
        claimable  = uint256(vm.load(address(queues), bytes32(uint256(base) + 3)));
    }

    function _depositPosition(address usr) internal view returns (uint256 gen, uint256 shares, uint256 rewardDebt, uint256 claimable) {
        return _position(6, usr);
    }

    function _redeemPosition(address usr) internal view returns (uint256 gen, uint256 shares, uint256 rewardDebt, uint256 claimable) {
        return _position(11, usr);
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

        (uint256 gen, uint256 shares, uint256 underlying) = queues.depositQueue();
        assertEq(gen, 0);
        assertEq(shares, 100e18);
        assertEq(underlying, 100e18);
        (uint256 posGen, uint256 posShares, uint256 rewardDebt, uint256 claimable) = _depositPosition(alice);
        assertEq(posGen, 0);
        assertEq(posShares, 100e18);
        assertEq(rewardDebt, 0);
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

        (uint256 gen, uint256 queueShares, uint256 underlying) = queues.redeemQueue();
        assertEq(gen, 0);
        assertEq(queueShares, shares);
        assertEq(underlying, shares);
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

    function testQueueTwiceAddsShares() public {
        _queueDeposit(alice, 100e18);
        _queueDeposit(alice, 50e18);
        (, uint256 shares,,) = _depositPosition(alice);
        assertEq(shares, 150e18);
        assertEq(queues.pendingDeposit(alice), 150e18);
    }

    /// Shares are minted at the generation's current ratio, so a later join gets the same claim per unit
    function testJoinAfterPartialFillIsProRata() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(50e18);
        _queueDeposit(bob, 50e18);

        (, uint256 bobShares,,) = _depositPosition(bob);
        assertEq(bobShares, 100e18); // 50 assets * 100 shares / 50 underlying
        assertEq(queues.pendingDeposit(alice), 50e18);
        assertEq(queues.pendingDeposit(bob), 50e18);

        _settleDeposit(50e18);
        assertEq(queues.claimableDeposit(alice), 75e18);
        assertEq(queues.claimableDeposit(bob), 25e18);
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

        (,, uint256 depositUnderlying) = queues.depositQueue();
        (,, uint256 redeemUnderlying) = queues.redeemQueue();
        assertEq(depositUnderlying, 40e18);
        assertEq(redeemUnderlying, 70e18);
        assertEq(queues.claimableDeposit(alice), 60e18);
        assertEq(queues.claimableRedeem(bob), 30e18);
        assertEq(srusds.balanceOf(address(queues)), 60e18 + 70e18); // Converted deposits and pending redeems
        assertEq(susds.balanceOf(address(queues)), 40e18 + 30e18);  // Pending deposits and converted redeems
    }

    function testSettleFullCapacityEndsGeneration() public {
        _queueDeposit(alice, 100e18);
        assertEq(_settleDeposit(type(uint256).max), 100e18);

        (uint256 gen, uint256 shares, uint256 underlying) = queues.depositQueue();
        assertEq(gen, 1);
        assertEq(shares, 0);
        assertEq(underlying, 0);
        assertEq(queues.pendingDeposit(alice), 0);
        assertEq(queues.claimableDeposit(alice), 100e18);
    }

    function testSettleZeroCapacityAndEmptyQueue() public {
        _queueDeposit(alice, 100e18);
        assertEq(_settleDeposit(0), 0);
        assertEq(queues.pendingDeposit(alice), 100e18);
        assertEq(_depositGen(), 0);

        vm.prank(alice); queues.cancelDeposit(alice, alice);
        assertEq(_settleDeposit(100e18), 0); // Nothing queued: converts nothing, ends nothing
        assertEq(_depositGen(), 0);
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

    /// Every position in a generation gets the same fraction of each conversion, whenever it joined
    function testProportionalDistribution() public {
        _queueDeposit(alice, 100e18);
        _queueDeposit(bob, 300e18);
        _settleDeposit(200e18);
        assertEq(queues.claimableDeposit(alice), 50e18);
        assertEq(queues.claimableDeposit(bob), 150e18);
        assertEq(queues.pendingDeposit(alice), 50e18);
        assertEq(queues.pendingDeposit(bob), 150e18);

        _queueDeposit(carol, 100e18);
        _settleDeposit(150e18);
        assertEq(queues.claimableDeposit(alice), 75e18);
        assertEq(queues.claimableDeposit(bob), 225e18);
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
        (uint256 gen, uint256 shares, uint256 underlying) = queues.depositQueue();
        assertEq(gen, 0);     // Cancelling does not end the generation
        assertEq(shares, 0);
        assertEq(underlying, 0);

        vm.prank(alice); vm.expectRevert("SrUsdsQueues/zero-shares");
        queues.cancelDeposit(alice, alice);
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
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/zero-shares");
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

        vm.expectRevert("SrUsdsQueues/insufficient-claimable");
        queues.claimDeposit(30e18 + 1, alice, alice);
        assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 30e18);
        assertEq(srusds.balanceOf(alice), 30e18);
        assertEq(queues.claimableDeposit(alice), 0);
        assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 0); // Nothing to claim is fine
        vm.stopPrank();

        (,, uint256 rewardDebt, uint256 claimable) = _depositPosition(alice);
        assertEq(claimable, 0);
        assertEq(rewardDebt, 0.4e27);
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
    }

    function testClaimReverts() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(40e18);
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/receiver-zero-address");
        queues.claimDeposit(1, address(0), alice);
        vm.prank(bob); vm.expectRevert("SrUsdsQueues/not-operator");
        queues.claimDeposit(1, bob, alice);
    }

    /// Converted amounts are credited lazily: they accrue across settlements and a claim collects all of them
    function testClaimAccruesAcrossSettlements() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(25e18);
        _settleDeposit(25e18);
        assertEq(queues.claimableDeposit(alice), 50e18);
        (,,, uint256 stored) = _depositPosition(alice);
        assertEq(stored, 0); // Nothing banked until the position is touched

        _queueDeposit(alice, 10e18);
        (,,, stored) = _depositPosition(alice);
        assertEq(stored, 50e18);
        _settleDeposit(30e18);
        assertEq(queues.claimableDeposit(alice), 80e18);
        vm.prank(alice); assertEq(queues.claimDeposit(type(uint256).max, alice, alice), 80e18);
    }

    // --- Share ratio limit ---
    // Within a generation the shares:underlying ratio only grows: a conversion removes underlying but keeps
    // every share, and joins keep the ratio as it is. To keep the accounting precise, a partial conversion must
    // leave at least totalShares / MAX_SHARE_RATIO of underlying behind, so a generation ends only when drained.

    /// A conversion that would leave less than the minimum remainder is reduced to leave exactly that, or to
    /// nothing once the queue is at the limit; a drain is always allowed and ends the generation
    function testPartialConversionLeavesMinRemainder() public {
        _queueDeposit(alice, 1_000_000e18);
        uint256 minRemainder = 1_000_000e18 / MAX_SHARE_RATIO; // 1e15

        assertEq(_settleDeposit(1_000_000e18 - 1), 1_000_000e18 - minRemainder);
        (uint256 gen,, uint256 underlying) = queues.depositQueue();
        assertEq(gen, 0);
        assertEq(underlying, minRemainder);
        assertEq(_depositRatio(), MAX_SHARE_RATIO);
        assertEq(queues.pendingDeposit(alice), minRemainder);
        assertEq(queues.claimableDeposit(alice), 1_000_000e18 - minRemainder);

        assertEq(_settleDeposit(minRemainder - 1), 0);                // At the limit a partial conversion converts nothing
        assertEq(_settleDeposit(type(uint256).max), minRemainder);   // Only a drain makes progress
        assertEq(_depositGen(), 1);
        assertEq(queues.pendingDeposit(alice), 0);
        assertEq(queues.claimableDeposit(alice), 1_000_000e18);
    }

    /// Each 50% fill doubles the ratio, so the 30th reaches the limit; from then on half fills convert nothing
    /// and the generation can only be converted in full
    function testHalfFillsFreezeAfterThirty() public {
        _queueDeposit(alice, 1_000_000e18);

        for (uint256 i; i < 30; i++) {
            assertGt(_settleFraction(50_00), 0);
            assertLe(_depositRatio(), MAX_SHARE_RATIO);
        }
        assertEq(_depositRatio(), MAX_SHARE_RATIO);
        assertEq(_depositGen(), 0);

        assertEq(_settleFraction(50_00), 0);
        assertEq(_settleFraction(99_99), 0);
        assertEq(_settleDeposit(type(uint256).max), 1_000_000e18 / MAX_SHARE_RATIO);
        assertEq(_depositGen(), 1);
        assertEq(queues.claimableDeposit(alice), 1_000_000e18);
    }

    /// A wei queued next to a large request cannot poison the generation: the fill that would leave only that
    /// wei is reduced to leave the minimum remainder, so a later joiner gets a sane number of shares and every
    /// later conversion is still credited to the wei
    function testSliverCannotPoisonGeneration() public {
        _queueDeposit(alice, 1_000_000e18);
        _queueDeposit(carol, 1);
        uint256 minRemainder = (1_000_000e18 + 1) / MAX_SHARE_RATIO;
        assertEq(_settleDeposit(1_000_000e18), 1_000_000e18 + 1 - minRemainder);

        _queueDeposit(bob, 100e18);
        (, uint256 bobShares,,) = _depositPosition(bob);
        assertEq(bobShares, 100e18 * (1_000_000e18 + 1) / minRemainder); // About 1e9 shares per wei
        _settleDeposit(type(uint256).max);
        assertEq(_depositGen(), 1);
        // Rewards are credited rounded down by under totalShares / RAY per conversion: 100 wei here
        assertApproxEqAbs(queues.claimableDeposit(bob), 100e18, 100);
        assertApproxEqAbs(queues.claimableDeposit(alice), 1_000_000e18, 100);
        assertLe(srusds.balanceOf(address(queues)) - queues.claimableDeposit(alice) - queues.claimableDeposit(bob) - queues.claimableDeposit(carol), 200);
    }

    /// Once its generation is drained a request has nothing pending: cancel reverts and pending shows 0, while
    /// what converted stays claimable. A new request starts a position in the current generation, keeping it
    function testDrainedGeneration() public {
        _queueDeposit(alice, 100e18);
        _settleDeposit(type(uint256).max);
        assertEq(_depositGen(), 1);
        assertEq(queues.pendingDeposit(alice), 0);
        assertEq(queues.claimableDeposit(alice), 100e18);
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/not-current-gen");
        queues.cancelDeposit(alice, alice);

        _queueDeposit(bob, 100e18); // The new generation starts at 1:1
        _queueDeposit(alice, 50e18);
        (uint256 gen, uint256 shares, uint256 rewardDebt, uint256 claimable) = _depositPosition(alice);
        assertEq(gen, 1);
        assertEq(shares, 50e18);
        assertEq(rewardDebt, 0);
        assertEq(claimable, 100e18);
        assertEq(queues.pendingDeposit(alice), 50e18);
        assertEq(queues.claimableDeposit(alice), 100e18);

        _settleDeposit(75e18);
        assertEq(queues.claimableDeposit(alice), 125e18);
        assertEq(queues.claimableDeposit(bob), 50e18);
        vm.prank(alice); assertEq(queues.cancelDeposit(alice, alice), 25e18);
    }

    /// The redeem queue follows the same rules
    function testRedeemQueueMinRemainder() public {
        uint256 shares = _mintSrUsds(alice, 1_000_000e18);
        _queueRedeem(alice, shares);
        uint256 minRemainder = shares / MAX_SHARE_RATIO;

        _settle(0, 0, shares - 1);
        assertEq(queues.pendingRedeem(alice), minRemainder);
        assertEq(queues.claimableRedeem(alice), shares - minRemainder);

        _settle(0, 0, type(uint256).max);
        (uint256 gen,,) = queues.redeemQueue();
        assertEq(gen, 1);
        assertEq(queues.pendingRedeem(alice), 0);
        assertEq(queues.claimableRedeem(alice), 1_000_000e18);
        vm.prank(alice); vm.expectRevert("SrUsdsQueues/not-current-gen");
        queues.cancelRedeem(alice, alice);
    }

    function testFuzzSettle(uint256 depositAmt, uint256 capacity) public {
        depositAmt = bound(depositAmt, 1e18, 1_000_000e18);
        capacity   = bound(capacity, 0, 2_000_000e18);
        _queueDeposit(alice, depositAmt);

        uint256 converted = _settleDeposit(capacity);

        if (capacity >= depositAmt) {
            assertEq(converted, depositAmt);
            assertEq(_depositGen(), 1);
            assertEq(queues.pendingDeposit(alice), 0);
            assertEq(queues.claimableDeposit(alice), depositAmt);
        } else {
            // The remainder is floored at totalShares / MAX_SHARE_RATIO (shares == depositAmt here)
            uint256 minRemainder = depositAmt / MAX_SHARE_RATIO;
            uint256 expected = depositAmt - capacity < minRemainder ? depositAmt - minRemainder : capacity;
            assertEq(converted, expected);
            assertEq(_depositGen(), 0);
            assertEq(queues.pendingDeposit(alice), depositAmt - expected);
            assertApproxEqAbs(queues.claimableDeposit(alice), expected, 1); // Reward per share and its credit both round down
        }
    }

    /// However joins, fills, drains, cancels and claims interleave, every user ends up with what they put in
    /// (as srUSDS at 1:1 plus returned sUSDS), and the contract keeps only rounding dust
    function testFuzzEveryoneIsMadeWhole(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256[3] memory put;
        uint256[3] memory got;

        for (uint256 i; i < 120; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 u = r % 3;
            if (r >> 8 & 3 == 0) {
                uint256 amt = bound(r >> 16, 1e18, 1_000e18);
                _queueDeposit(users[u], amt);
                put[u] += amt;
            }
            if (r >> 64 & 7 == 0 && queues.pendingDeposit(users[u]) > 0) { // Pending is 0 in a drained generation
                vm.prank(users[u]); got[u] += queues.cancelDeposit(users[u], users[u]);
            }
            if (r >> 96 & 7 == 0) {
                vm.prank(users[u]); got[u] += queues.claimDeposit(type(uint256).max, users[u], users[u]);
            }
            // Fills of any size, clipped by the contract when they would leave too little; now and then a drain
            _settleFraction(r >> 104 & 15 == 0 ? 10_000 : bound(r >> 128, 0, 99_99));
        }

        _settleFraction(10_000);
        for (uint256 u; u < 3; u++) {
            assertEq(queues.pendingDeposit(users[u]), 0);
            vm.prank(users[u]); got[u] += queues.claimDeposit(type(uint256).max, users[u], users[u]);
            // Shares are minted rounded down, so a join shifts up to a wei to existing holders; every other
            // rounding is in the contract's favour, the largest being up to totalShares / RAY per conversion
            // (shares minted at a ratio up to 1e9 make that up to 1e-18 of what was joined)
            assertApproxEqAbs(got[u], put[u], 1e6);
        }
        assertLe(susds.balanceOf(address(queues)), 1e6);
        assertLe(srusds.balanceOf(address(queues)), 1e6);
    }
}
