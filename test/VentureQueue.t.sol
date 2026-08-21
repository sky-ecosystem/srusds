// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { Venture } from "src/Venture.sol";
import { VentureHandler } from "src/VentureHandler.sol";

/// @dev Both queues share one implementation in VentureHandler, so every case below runs against
///      both sides. `isDeposit` flips which token is underlying and which is the reward:
///      deposit queue takes gem and pays Venture, withdraw queue takes Venture and pays gem.
abstract contract VentureQueueTestBase is DssTest {
    MockERC20    gem;
    Venture        token;
    VentureHandler handler;

    address buffer = address(0xBFFE8);

    bool internal isDeposit;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    // --- Events ---

    event Join(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, uint256 underlying, uint256 shares);
    event Exit(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards, address underlyingTo, uint256 underlying);
    event Claim(bool indexed isDeposit, address indexed owner, uint256 indexed gen, address rewardsTo, uint256 rewards);
    event Convert(bool indexed isDeposit, uint256 indexed gen, uint256 capacity, uint256 converted, uint256 received, bool finalized);

    function setUp() public {
        gem = new MockERC20("Gem", "GEM");

        token = Venture(address(new ERC1967Proxy(
            address(new Venture()),
            abi.encodeCall(Venture.initialize, ())
        )));

        handler = new VentureHandler(address(gem), address(token));

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

    // --- Side bindings ---

    // Give usr `amount` of the queue's underlying and approve the handler to pull it
    function _fund(address usr, uint256 amount) internal {
        if (isDeposit) {
            gem.mint(usr, amount);
        } else {
            // Shares are minted against backing that already sits at the buffer
            token.mint(amount, usr);
            gem.mint(buffer, amount * token.chi() / RAY);
        }

        vm.prank(usr);
        if (isDeposit) gem.approve(address(handler), amount);
        else           token.approve(address(handler), amount);
    }

    function _joinAs(address usr, uint256 amount) internal returns (uint256 rewards) {
        vm.prank(usr);
        rewards = isDeposit ? handler.claimVentureAndJoinGem(usr, amount)
                            : handler.claimGemAndJoinVenture(usr, amount);
    }

    function _join(address usr, uint256 amount) internal returns (uint256 rewards) {
        _fund(usr, amount);
        rewards = _joinAs(usr, amount);
    }

    function _claimAs(address usr, address rewardsTo) internal returns (uint256 rewards) {
        vm.prank(usr);
        rewards = isDeposit ? handler.claimVenture(rewardsTo) : handler.claimGem(rewardsTo);
    }

    function _exitAs(address usr, address rewardsTo, address underlyingTo) internal returns (uint256 rewards, uint256 underlying) {
        vm.prank(usr);
        (rewards, underlying) = isDeposit ? handler.claimVentureAndExitGem(rewardsTo, underlyingTo)
                                          : handler.claimGemAndExitVenture(rewardsTo, underlyingTo);
    }

    function _queue() internal view returns (uint256 gen, uint256 shares, uint256 underlying) {
        if (isDeposit) (gen, shares, underlying) = handler.deposits();
        else           (gen, shares, underlying) = handler.withdrawals();
    }

    function _queueGen() internal view returns (uint256 gen) {
        (gen, , ) = _queue();
    }

    function _queueShares() internal view returns (uint256 shares) {
        (, shares, ) = _queue();
    }

    function _queueUnderlying() internal view returns (uint256 underlying) {
        (, , underlying) = _queue();
    }

    function _position(address usr) internal view returns (uint256 gen, uint256 shares, uint256 rewardDebt) {
        if (isDeposit) (gen, shares, rewardDebt) = handler.depositPositions(usr);
        else           (gen, shares, rewardDebt) = handler.withdrawPositions(usr);
    }

    function _pending(address usr) internal view returns (uint256) {
        return isDeposit ? handler.pendingDepositRewards(usr) : handler.pendingWithdrawRewards(usr);
    }

    function _balance(address usr) internal view returns (uint256) {
        return isDeposit ? handler.depositBalance(usr) : handler.withdrawBalance(usr);
    }

    function _finalized(address usr) internal view returns (bool) {
        return isDeposit ? handler.depositFinalized(usr) : handler.withdrawFinalized(usr);
    }

    function _rewardPerToken(uint256 gen) internal view returns (uint256) {
        return isDeposit ? handler.depositRewardPerToken(gen) : handler.withdrawRewardPerToken(gen);
    }

    // Balance of the token users hand over when joining
    function _underlyingBalanceOf(address usr) internal view returns (uint256) {
        return isDeposit ? gem.balanceOf(usr) : token.balanceOf(usr);
    }

    // Balance of the token the queue pays out
    function _rewardBalanceOf(address usr) internal view returns (uint256) {
        return isDeposit ? token.balanceOf(usr) : gem.balanceOf(usr);
    }

    // Reward a queue receives for converting `underlyingAmt` at the current chi
    function _expectedReward(uint256 underlyingAmt) internal view returns (uint256) {
        uint256 chi = token.chi();
        return isDeposit ? underlyingAmt * RAY / chi : underlyingAmt * chi / RAY;
    }

    // --- Cycle helpers ---

    function _warpToLockWindow() internal {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 13 hours);
    }

    function _warpToSettleTime() internal {
        uint256 day = (block.timestamp / 1 days) * 1 days;
        vm.warp(day + 16 hours);
    }

    function _lock() internal {
        _warpToLockWindow();
        handler.lock();
    }

    function _plan(uint256 capacity) internal {
        if (isDeposit) handler.plan(0, capacity, 0);
        else           handler.plan(0, 0, capacity);
    }

    // Run a full cycle, giving the queue under test `capacity` and the other side none
    function _settle(uint256 capacity) internal returns (uint256 converted) {
        uint256 underlyingBefore = _queueUnderlying();

        _lock();
        _plan(capacity);
        _warpToSettleTime();
        handler.settle();

        converted = underlyingBefore - _queueUnderlying();
    }

    // Move chi, topping the buffer up so the backing matches the new rate
    function _setChi(uint256 newChi) internal {
        uint256 supply = token.totalSupply();
        uint256 chiBefore = token.chi();
        require(newChi > chiBefore, "test/chi-must-grow");

        vm.store(address(token), bytes32(uint256(5)), bytes32((block.timestamp << 192) + newChi));
        assertEq(uint256(token.chi()), newChi);

        gem.mint(buffer, supply * (newChi - chiBefore) / RAY);
    }

    // --- Caller Scoping Tests ---

    function testJoinCreditsOnlyCaller() public {
        _join(alice, 100e18);

        (, uint256 aliceShares, ) = _position(alice);
        (, uint256 bobShares, )   = _position(bob);
        assertEq(aliceShares, 100e18);
        assertEq(bobShares, 0);
    }

    function testClaimOtherPositionReverts() public {
        _join(alice, 100e18);
        _settle(50e18);

        // Bob cannot reach alice's rewards: the owner is always the caller
        vm.expectRevert("VentureHandler/no-position");
        _claimAs(bob, bob);

        assertEq(_pending(alice), 50e18);
    }

    function testExitOtherPositionReverts() public {
        _join(alice, 100e18);

        vm.expectRevert("VentureHandler/zero-shares");
        _exitAs(bob, bob, bob);

        assertEq(_queueUnderlying(), 100e18);
    }

    // --- Join Tests ---

    function testJoin() public {
        _fund(alice, 100e18);

        vm.expectEmit(true, true, true, true);
        emit Join(isDeposit, alice, 0, alice, 0, 100e18, 100e18);
        _joinAs(alice, 100e18);

        (uint256 gen, uint256 shares, uint256 rewardDebt) = _position(alice);
        assertEq(gen, 0);
        assertEq(shares, 100e18);
        assertEq(rewardDebt, 0);
        assertEq(_queueUnderlying(), 100e18);
        assertEq(_queueShares(), 100e18);
    }

    function testJoinZeroReverts() public {
        vm.expectRevert("VentureHandler/zero-underlyingAmt");
        _joinAs(alice, 0);
    }

    function testJoinRewardsToZeroAddressReverts() public {
        _fund(alice, 100e18);

        vm.expectRevert("VentureHandler/rewards-zero-address");
        vm.prank(alice);
        if (isDeposit) handler.claimVentureAndJoinGem(address(0), 100e18);
        else           handler.claimGemAndJoinVenture(address(0), 100e18);
    }

    function testMultipleJoins() public {
        _join(alice, 100e18);
        _join(bob, 200e18);

        assertEq(_queueUnderlying(), 300e18);
        assertEq(_queueShares(), 300e18);

        (, uint256 aliceShares, ) = _position(alice);
        (, uint256 bobShares, )   = _position(bob);
        assertEq(aliceShares, 100e18);
        assertEq(bobShares, 200e18);
    }

    function testJoinAfterPartialSettle() public {
        _join(alice, 100e18);

        // Settle 50% capacity
        _settle(50e18);

        // Bob joins after partial settle
        _join(bob, 50e18);

        // Bob should get proportional shares
        (, uint256 bobShares, ) = _position(bob);
        assertEq(bobShares, 100e18); // 50 underlying * 100 shares / 50 underlying = 100 shares
    }

    function testJoinWhileLockedReverts() public {
        _fund(alice, 100e18);
        _lock();

        vm.expectRevert("VentureHandler/queue-locked");
        _joinAs(alice, 100e18);
    }

    function testReJoinSameGenClaimsRewards() public {
        _join(alice, 100e18);

        _settle(50e18);

        assertEq(_pending(alice), 50e18);

        // Re-join in the same gen auto-claims pending rewards
        _join(alice, 50e18);

        assertEq(_rewardBalanceOf(alice), 50e18);
        assertEq(_pending(alice), 0);

        (uint256 gen, uint256 shares, ) = _position(alice);
        assertEq(gen, 0);
        assertEq(shares, 200e18); // 100 original + 100 new (50 underlying * 100 shares / 50 underlying)
    }

    function testJoinAfterFinalizedPosition() public {
        _join(alice, 100e18);

        _settle(100e18);

        // Alice joins again, claiming the finalized position first
        _join(alice, 50e18);

        assertEq(_rewardBalanceOf(alice), 100e18); // Claimed from finalized
        (uint256 gen, uint256 shares, ) = _position(alice);
        assertEq(gen, 1);
        assertEq(shares, 50e18);
    }

    // --- Convert Tests ---

    function testConvert() public {
        _join(alice, 100e18);

        _lock();
        _plan(50e18);
        _warpToSettleTime();

        vm.expectEmit(true, true, true, true);
        emit Convert(isDeposit, 0, 50e18, 50e18, 50e18, false);
        handler.settle();

        assertEq(_queueUnderlying(), 50e18);
        assertEq(_rewardPerToken(0), 50e18 * WAD / 100e18); // 0.5 WAD
    }

    function testConvertFullCapacity() public {
        _join(alice, 100e18);

        _lock();
        _plan(100e18);
        _warpToSettleTime();

        vm.expectEmit(true, true, true, true);
        emit Convert(isDeposit, 0, 100e18, 100e18, 100e18, true);
        handler.settle();

        assertEq(_queueUnderlying(), 0);
        assertEq(_queueGen(), 1);
        assertEq(_queueShares(), 0);
        assertEq(_rewardPerToken(0), WAD); // Retained in finalized gen (100e18 received / 100e18 shares)
    }

    function testConvertExcessCapacity() public {
        _join(alice, 100e18);

        uint256 converted = _settle(200e18);

        assertEq(converted, 100e18); // Capped at underlying
        assertEq(_queueGen(), 1);
    }

    function testConvertZeroCapacity() public {
        _join(alice, 100e18);

        uint256 converted = _settle(0);

        assertEq(converted, 0);
        assertEq(_queueUnderlying(), 100e18);
    }

    function testConvertEmptyQueue() public {
        uint256 converted = _settle(100e18);

        assertEq(converted, 0);
        assertEq(_queueGen(), 0);
    }

    // --- Claim Tests ---

    function testClaimPartialRewards() public {
        _join(alice, 100e18);

        _settle(50e18);

        assertEq(_pending(alice), 50e18);

        vm.expectEmit(true, true, true, true);
        emit Claim(isDeposit, alice, 0, alice, 50e18);
        uint256 claimed = _claimAs(alice, alice);

        assertEq(claimed, 50e18);
        assertEq(_rewardBalanceOf(alice), 50e18);
        assertEq(_pending(alice), 0);
    }

    function testClaimFromFinalizedGeneration() public {
        _join(alice, 100e18);

        _settle(100e18); // Finalize gen 0

        assertTrue(_finalized(alice));

        uint256 claimed = _claimAs(alice, alice);

        assertEq(claimed, 100e18);
        assertEq(_rewardBalanceOf(alice), 100e18);

        // Position shares remain (claim no longer clears finalized positions)
        (, uint256 shares, ) = _position(alice);
        assertEq(shares, 100e18);
    }

    function testClaimToAddress() public {
        _join(alice, 100e18);

        _settle(50e18);

        _claimAs(alice, bob);

        assertEq(_rewardBalanceOf(bob), 50e18);
        assertEq(_rewardBalanceOf(alice), 0);
    }

    function testClaimNoPositionReverts() public {
        vm.expectRevert("VentureHandler/no-position");
        _claimAs(alice, alice);
    }

    function testClaimWithZeroPendingRewards() public {
        _join(alice, 100e18);

        // No settle yet — zero rewards
        uint256 claimed = _claimAs(alice, alice);
        assertEq(claimed, 0);
        assertEq(_rewardBalanceOf(alice), 0);
    }

    function testClaimCurrentGenWhileLockedReverts() public {
        _join(alice, 100e18);
        _settle(50e18);

        _lock();

        vm.expectRevert("VentureHandler/queue-locked");
        _claimAs(alice, alice);
    }

    function testClaimFinalizedGenWhileLockedAllowed() public {
        _join(alice, 100e18);
        _settle(100e18);

        _lock();

        // Claiming from a finalized generation should always work
        uint256 claimed = _claimAs(alice, alice);
        assertEq(claimed, 100e18);
    }

    function testClaimToZeroAddressReverts() public {
        _join(alice, 100e18);
        _settle(50e18);

        vm.expectRevert("VentureHandler/rewardsTo-zero-address");
        _claimAs(alice, address(0));
    }

    // --- Exit Tests ---

    function testExit() public {
        _join(alice, 100e18);

        _settle(50e18);

        (uint256 rewardsAmt, uint256 underlyingAmt) = _exitAs(alice, alice, alice);

        assertEq(rewardsAmt, 50e18);    // Claimed rewards
        assertEq(underlyingAmt, 50e18); // Remaining underlying
        assertEq(_underlyingBalanceOf(alice), 50e18);
        assertEq(_rewardBalanceOf(alice), 50e18);

        // Position should be cleared
        (, uint256 shares, ) = _position(alice);
        assertEq(shares, 0);
        assertEq(_queueShares(), 0);
        assertEq(_queueUnderlying(), 0);
    }

    function testExitFinalizedReverts() public {
        _join(alice, 100e18);

        _settle(100e18); // Finalize

        vm.expectRevert("VentureHandler/not-current-gen");
        _exitAs(alice, alice, alice);
    }

    function testExitToAddress() public {
        _join(alice, 100e18);

        _settle(50e18);

        _exitAs(alice, bob, bob);

        assertEq(_underlyingBalanceOf(bob), 50e18);
        assertEq(_rewardBalanceOf(bob), 50e18);
    }

    function testExitWhileLockedReverts() public {
        _join(alice, 100e18);
        _settle(50e18);

        _lock();

        vm.expectRevert("VentureHandler/queue-locked");
        _exitAs(alice, alice, alice);
    }

    function testExitRewardsToZeroAddressReverts() public {
        _join(alice, 100e18);

        vm.expectRevert("VentureHandler/rewards-zero-address");
        _exitAs(alice, address(0), alice);
    }

    function testExitUnderlyingToZeroAddressReverts() public {
        _join(alice, 100e18);

        vm.expectRevert("VentureHandler/underlying-zero-address");
        _exitAs(alice, alice, address(0));
    }

    function testExitNoPositionReverts() public {
        vm.expectRevert("VentureHandler/zero-shares");
        _exitAs(alice, alice, alice);
    }

    function testLastUserExitAdvancesGeneration() public {
        _join(alice, 100e18);
        _join(bob, 100e18);

        _settle(50e18);

        // Alice exits — not last, gen should stay
        _exitAs(alice, alice, alice);
        assertEq(_queueGen(), 0);

        // Bob exits — last user, gen should advance
        _exitAs(bob, bob, bob);
        assertEq(_queueGen(), 1);
        assertEq(_queueShares(), 0);
        assertEq(_queueUnderlying(), 0);
    }

    // --- Proportional Distribution Tests ---

    function testProportionalDistribution() public {
        _join(alice, 100e18);
        _join(bob, 300e18);

        _settle(200e18);

        // Alice: 100/400 = 25% -> 50 rewards
        // Bob: 300/400 = 75% -> 150 rewards
        assertEq(_pending(alice), 50e18);
        assertEq(_pending(bob), 150e18);
    }

    function testProportionalDistributionAcrossMultipleSettles() public {
        _join(alice, 100e18);
        _join(bob, 100e18);

        // First settle: 100 capacity, each gets 50
        _settle(100e18);

        assertEq(_pending(alice), 50e18);
        assertEq(_pending(bob), 50e18);

        // Second settle: 100 capacity, each gets 50 more
        _settle(100e18);

        assertEq(_pending(alice), 100e18);
        assertEq(_pending(bob), 100e18);
    }

    // --- Generation Tests ---

    function testNewGenerationAfterFinalization() public {
        _join(alice, 100e18);

        _settle(100e18);

        assertEq(_queueGen(), 1);

        // New join goes to gen 1
        _join(bob, 100e18);

        (uint256 gen, , ) = _position(bob);
        assertEq(gen, 1);
    }

    // --- View Functions Tests ---

    function testPendingRewards() public {
        _join(alice, 100e18);

        assertEq(_pending(alice), 0);

        _settle(50e18);

        assertEq(_pending(alice), 50e18);
    }

    function testUnderlyingBalance() public {
        _join(alice, 100e18);

        assertEq(_balance(alice), 100e18);

        _settle(50e18);

        assertEq(_balance(alice), 50e18);

        _settle(50e18);

        assertEq(_balance(alice), 0); // Finalized
    }

    function testIsFinalized() public {
        _join(alice, 100e18);

        assertFalse(_finalized(alice));

        _settle(100e18);

        assertTrue(_finalized(alice));
    }

    // --- Non-1:1 Chi Tests ---

    function testConvertWithNonOneToOneChi() public {
        _join(alice, 100e18);

        // 1 Venture share = 2 gem
        _setChi(2 * RAY);

        _settle(100e18);

        uint256 expected = _expectedReward(100e18);
        assertEq(expected, isDeposit ? 50e18 : 200e18);

        uint256 claimed = _claimAs(alice, alice);
        assertEq(claimed, expected);
        assertEq(_rewardBalanceOf(alice), expected);
    }

    function testProportionalDistributionWithNonOneToOneChi() public {
        _join(alice, 100e18);
        _join(bob, 300e18);

        _setChi(2 * RAY);

        _settle(200e18);

        // Alice takes 100/400 = 25% of the converted rewards, bob the remaining 75%
        uint256 received = _expectedReward(200e18);
        assertEq(_pending(alice), received / 4);
        assertEq(_pending(bob), received * 3 / 4);
    }

    // --- Buffer Tests ---

    function testConvertRoutesBackingThroughBuffer() public {
        _join(alice, 100e18);

        uint256 bufferBefore  = gem.balanceOf(buffer);
        uint256 handlerBefore = gem.balanceOf(address(handler));

        _settle(100e18);

        if (isDeposit) {
            // Converted deposits leave for the buffer: nothing investable stays here
            assertEq(gem.balanceOf(buffer), bufferBefore + 100e18);
            assertEq(gem.balanceOf(address(handler)), handlerBefore - 100e18);
        } else {
            // Converted withdrawals pull the backing back, now owed out as rewards
            assertEq(gem.balanceOf(buffer), bufferBefore - 100e18);
            assertEq(gem.balanceOf(address(handler)), handlerBefore + 100e18);
        }
    }

    // --- Custody Tests ---

    function testCustodyCoversQueuedFunds() public {
        _join(alice, 100e18);
        _join(bob, 300e18);

        _settle(200e18);

        // Everything the queue holds is still owed out: rewards for the converted half,
        // underlying for the rest. Both users must be able to take all of it.
        (uint256 aliceRewards, uint256 aliceUnderlying) = _exitAs(alice, alice, alice);
        (uint256 bobRewards, uint256 bobUnderlying) = _exitAs(bob, bob, bob);

        assertEq(aliceRewards + bobRewards, _expectedReward(200e18));
        assertEq(aliceUnderlying + bobUnderlying, 200e18);

        assertEq(_queueUnderlying(), 0);
        assertEq(_queueShares(), 0);
    }

    // --- Fuzz Tests ---

    function testFuzzJoin(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        _join(alice, amount);

        assertEq(_queueUnderlying(), amount);
        assertEq(_balance(alice), amount);
    }

    function testFuzzConvert(uint256 joinAmt, uint256 capacity) public {
        joinAmt = bound(joinAmt, 1e18, 1000e18);
        capacity = bound(capacity, 0, 2000e18);

        _join(alice, joinAmt);

        uint256 converted = _settle(capacity);

        if (capacity == 0) {
            assertEq(converted, 0);
        } else if (capacity >= joinAmt) {
            assertEq(converted, joinAmt);
            assertEq(_queueGen(), 1);
        } else {
            assertEq(converted, capacity);
            assertEq(_queueUnderlying(), joinAmt - capacity);
        }
    }
}

contract VentureDepositQueueTest is VentureQueueTestBase {
    constructor() {
        isDeposit = true;
    }
}

contract VentureWithdrawQueueTest is VentureQueueTestBase {
    constructor() {
        isDeposit = false;
    }
}
