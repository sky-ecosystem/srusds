// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import { MockERC20, MockERC4626 } from "test/mocks/MockERC4626.sol";
import { LCTSDepositQueue } from "src/lcts/LCTSDepositQueue.sol";
import { LCTSWithdrawQueue } from "src/lcts/LCTSWithdrawQueue.sol";

contract LCTSDepositQueueTest is Test {
    MockERC20 underlying;
    MockERC4626 vault;
    LCTSDepositQueue queue;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant WAD = 1e18;

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Deposit(address indexed user, uint256 indexed gen, uint256 assets, uint256 shares);
    event Claim(address indexed user, uint256 indexed gen, uint256 vaultShares, address indexed to);
    event Exit(address indexed user, uint256 indexed gen, uint256 assets, uint256 vaultShares, address indexed to);
    event Settle(uint256 indexed gen, uint256 capacity, uint256 converted, uint256 vaultSharesMinted, bool finalized);

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND");
        vault = new MockERC4626(address(underlying));
        queue = new LCTSDepositQueue(address(underlying), address(vault));

        // Test contract is the operator (already authed in constructor)
        // Approve queue to pull from test contract
        underlying.approve(address(queue), type(uint256).max);

        // Fund vault with underlying for redemptions
        underlying.mint(address(vault), 10000e18);
    }

    // Helper to deposit as operator on behalf of a user
    function _deposit(uint256 amount, address receiver) internal {
        underlying.mint(address(this), amount);
        queue.deposit(amount, receiver);
    }

    // --- Auth Tests ---

    function testAuth() public {
        assertEq(queue.wards(address(this)), 1);

        address newOperator = address(0x123);
        queue.rely(newOperator);
        assertEq(queue.wards(newOperator), 1);

        vm.expectEmit(true, true, true, true);
        emit Deny(newOperator);
        queue.deny(newOperator);
        assertEq(queue.wards(newOperator), 0);

        vm.expectRevert("LCTSDepositQueue/not-authorized");
        vm.prank(newOperator);
        queue.settle(100e18);
    }

    function testRelyDeny() public {
        address newUser = address(0x123);

        vm.expectEmit(true, true, true, true);
        emit Rely(newUser);
        queue.rely(newUser);
        assertEq(queue.wards(newUser), 1);

        vm.expectEmit(true, true, true, true);
        emit Deny(newUser);
        queue.deny(newUser);
        assertEq(queue.wards(newUser), 0);
    }

    function testUnauthorizedDepositReverts() public {
        address unauthorized = address(0x456);
        underlying.mint(unauthorized, 100e18);
        vm.prank(unauthorized);
        underlying.approve(address(queue), type(uint256).max);

        vm.expectRevert("LCTSDepositQueue/not-authorized");
        vm.prank(unauthorized);
        queue.deposit(100e18, unauthorized);
    }

    function testUnauthorizedClaimReverts() public {
        _deposit(100e18, alice);
        queue.settle(50e18);

        vm.expectRevert("LCTSDepositQueue/not-authorized");
        vm.prank(alice);
        queue.claim(alice, alice);
    }

    function testUnauthorizedClaimAndExitReverts() public {
        _deposit(100e18, alice);

        vm.expectRevert("LCTSDepositQueue/not-authorized");
        vm.prank(alice);
        queue.claimAndExit(alice, alice);
    }

    // --- Deposit Tests ---

    function testDeposit() public {
        underlying.mint(address(this), 100e18);

        vm.expectEmit(true, true, true, true);
        emit Deposit(alice, 0, 100e18, 100e18);
        queue.deposit(100e18, alice);

        (uint256 gen, uint256 shares, uint256 rewardDebt) = queue.getPosition(alice);
        assertEq(gen, 0);
        assertEq(shares, 100e18);
        assertEq(rewardDebt, 0);
        assertEq(queue.totalUnderlying(), 100e18);
        assertEq(queue.totalShares(), 100e18);
    }

    function testDepositToReceiver() public {
        _deposit(100e18, bob);

        (uint256 gen, uint256 shares, ) = queue.getPosition(bob);
        assertEq(gen, 0);
        assertEq(shares, 100e18);

        // Alice should have no position
        (,uint256 aliceShares,) = queue.getPosition(alice);
        assertEq(aliceShares, 0);
    }

    function testDepositZeroReverts() public {
        vm.expectRevert("LCTSDepositQueue/zero-amount");
        queue.deposit(0, alice);
    }

    function testDepositZeroAddressReverts() public {
        underlying.mint(address(this), 100e18);
        vm.expectRevert("LCTSDepositQueue/zero-address");
        queue.deposit(100e18, address(0));
    }

    function testMultipleDeposits() public {
        _deposit(100e18, alice);
        _deposit(200e18, bob);

        assertEq(queue.totalUnderlying(), 300e18);
        assertEq(queue.totalShares(), 300e18);

        (,uint256 aliceShares,) = queue.getPosition(alice);
        (,uint256 bobShares,) = queue.getPosition(bob);
        assertEq(aliceShares, 100e18);
        assertEq(bobShares, 200e18);
    }

    function testDepositAfterPartialSettle() public {
        _deposit(100e18, alice);

        // Settle 50% capacity
        queue.settle(50e18);

        // Bob deposits after partial settle
        _deposit(50e18, bob);

        // Bob should get proportional shares
        (,uint256 bobShares,) = queue.getPosition(bob);
        assertEq(bobShares, 100e18); // 50 assets * 100 shares / 50 underlying = 100 shares
    }

    // --- Settle Tests ---

    function testSettle() public {
        _deposit(100e18, alice);

        vm.expectEmit(true, true, true, true);
        emit Settle(0, 50e18, 50e18, 50e18, false);
        uint256 converted = queue.settle(50e18);

        assertEq(converted, 50e18);
        assertEq(queue.totalUnderlying(), 50e18);
        assertEq(queue.rewardPerToken(), 50e18 * WAD / 100e18); // 0.5 WAD
    }

    function testSettleFullCapacity() public {
        _deposit(100e18, alice);

        vm.expectEmit(true, true, true, true);
        emit Settle(0, 100e18, 100e18, 100e18, true);
        uint256 converted = queue.settle(100e18);

        assertEq(converted, 100e18);
        assertEq(queue.totalUnderlying(), 0);
        assertEq(queue.currentGen(), 1);
        assertEq(queue.totalShares(), 0);
        assertEq(queue.rewardPerToken(), 0); // Reset after finalization
    }

    function testSettleExcessCapacity() public {
        _deposit(100e18, alice);

        uint256 converted = queue.settle(200e18);

        assertEq(converted, 100e18); // Capped at underlying
        assertEq(queue.currentGen(), 1);
    }

    function testSettleZeroCapacity() public {
        _deposit(100e18, alice);

        uint256 converted = queue.settle(0);

        assertEq(converted, 0);
        assertEq(queue.totalUnderlying(), 100e18);
    }

    function testSettleEmptyQueue() public {
        uint256 converted = queue.settle(100e18);

        assertEq(converted, 0);
    }

    // --- Claim Tests ---

    function testClaimPartialRewards() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        uint256 pending = queue.pendingRewards(alice);
        assertEq(pending, 50e18);

        vm.expectEmit(true, true, true, true);
        emit Claim(alice, 0, 50e18, alice);
        uint256 claimed = queue.claim(alice, alice);

        assertEq(claimed, 50e18);
        assertEq(vault.balanceOf(alice), 50e18);
        assertEq(queue.pendingRewards(alice), 0);
    }

    function testClaimFromFinalizedGeneration() public {
        _deposit(100e18, alice);

        queue.settle(100e18); // Finalize gen 0

        assertTrue(queue.isFinalized(alice));

        uint256 claimed = queue.claim(alice, alice);

        assertEq(claimed, 100e18);
        assertEq(vault.balanceOf(alice), 100e18);

        // Position should be cleared
        (,uint256 shares,) = queue.getPosition(alice);
        assertEq(shares, 0);
    }

    function testClaimToAddress() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        queue.claim(alice, bob);

        assertEq(vault.balanceOf(bob), 50e18);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testClaimNoPositionReverts() public {
        vm.expectRevert("LCTSDepositQueue/no-position");
        queue.claim(alice, alice);
    }

    // --- ClaimAndExit Tests ---

    function testClaimAndExit() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        (uint256 assets, uint256 vaultShares) = queue.claimAndExit(alice, alice);

        assertEq(assets, 50e18); // Remaining underlying
        assertEq(vaultShares, 50e18); // Claimed vault shares
        assertEq(underlying.balanceOf(alice), 50e18);
        assertEq(vault.balanceOf(alice), 50e18);

        // Position should be cleared
        (,uint256 shares,) = queue.getPosition(alice);
        assertEq(shares, 0);
        assertEq(queue.totalShares(), 0);
        assertEq(queue.totalUnderlying(), 0);
    }

    function testClaimAndExitFinalizedReverts() public {
        _deposit(100e18, alice);

        queue.settle(100e18); // Finalize

        vm.expectRevert("LCTSDepositQueue/not-current-gen");
        queue.claimAndExit(alice, alice);
    }

    function testClaimAndExitToAddress() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        queue.claimAndExit(alice, bob);

        assertEq(underlying.balanceOf(bob), 50e18);
        assertEq(vault.balanceOf(bob), 50e18);
    }

    // --- Proportional Distribution Tests ---

    function testProportionalDistribution() public {
        _deposit(100e18, alice);
        _deposit(300e18, bob);

        queue.settle(200e18);

        // Alice: 100/400 = 25% -> 50 vault shares
        // Bob: 300/400 = 75% -> 150 vault shares
        assertEq(queue.pendingRewards(alice), 50e18);
        assertEq(queue.pendingRewards(bob), 150e18);
    }

    function testProportionalDistributionAcrossMultipleSettles() public {
        _deposit(100e18, alice);
        _deposit(100e18, bob);

        // First settle: 100 capacity, each gets 50
        queue.settle(100e18);

        assertEq(queue.pendingRewards(alice), 50e18);
        assertEq(queue.pendingRewards(bob), 50e18);

        // Second settle: 100 capacity, each gets 50 more
        queue.settle(100e18);

        assertEq(queue.pendingRewards(alice), 100e18);
        assertEq(queue.pendingRewards(bob), 100e18);
    }

    // --- Generation Tests ---

    function testNewGenerationAfterFinalization() public {
        _deposit(100e18, alice);

        queue.settle(100e18);

        assertEq(queue.currentGen(), 1);

        // New deposit goes to gen 1
        _deposit(100e18, bob);

        (uint256 gen,,) = queue.getPosition(bob);
        assertEq(gen, 1);
    }

    function testDepositAfterFinalizedPosition() public {
        _deposit(100e18, alice);

        queue.settle(100e18);

        // Alice deposits again, settling finalized position first
        _deposit(50e18, alice);

        assertEq(vault.balanceOf(alice), 100e18); // Claimed from finalized
        (uint256 gen, uint256 shares,) = queue.getPosition(alice);
        assertEq(gen, 1);
        assertEq(shares, 50e18);
    }

    // --- View Functions Tests ---

    function testPendingRewards() public {
        _deposit(100e18, alice);

        assertEq(queue.pendingRewards(alice), 0);

        queue.settle(50e18);

        assertEq(queue.pendingRewards(alice), 50e18);
    }

    function testUnderlyingBalance() public {
        _deposit(100e18, alice);

        assertEq(queue.underlyingBalance(alice), 100e18);

        queue.settle(50e18);

        assertEq(queue.underlyingBalance(alice), 50e18);

        queue.settle(50e18);

        assertEq(queue.underlyingBalance(alice), 0); // Finalized
    }

    function testIsFinalized() public {
        _deposit(100e18, alice);

        assertFalse(queue.isFinalized(alice));

        queue.settle(100e18);

        assertTrue(queue.isFinalized(alice));
    }

    // --- Fuzz Tests ---

    function testFuzzDeposit(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        _deposit(amount, alice);

        assertEq(queue.totalUnderlying(), amount);
        assertEq(queue.underlyingBalance(alice), amount);
    }

    function testFuzzSettle(uint256 depositAmt, uint256 capacity) public {
        depositAmt = bound(depositAmt, 1e18, 1000e18);
        capacity = bound(capacity, 0, 2000e18);

        _deposit(depositAmt, alice);

        uint256 converted = queue.settle(capacity);

        if (capacity == 0) {
            assertEq(converted, 0);
        } else if (capacity >= depositAmt) {
            assertEq(converted, depositAmt);
            assertEq(queue.currentGen(), 1);
        } else {
            assertEq(converted, capacity);
            assertEq(queue.totalUnderlying(), depositAmt - capacity);
        }
    }
}

contract LCTSWithdrawQueueTest is Test {
    MockERC20 underlying;
    MockERC4626 vault;
    LCTSWithdrawQueue queue;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant WAD = 1e18;

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Deposit(address indexed user, uint256 indexed gen, uint256 vaultShares, uint256 shares);
    event Claim(address indexed user, uint256 indexed gen, uint256 assets, address indexed to);
    event Exit(address indexed user, uint256 indexed gen, uint256 vaultShares, uint256 assets, address indexed to);
    event Settle(uint256 indexed gen, uint256 capacity, uint256 redeemed, uint256 assetsReceived, bool finalized);

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND");
        vault = new MockERC4626(address(underlying));
        queue = new LCTSWithdrawQueue(address(vault));

        // Test contract is the operator (already authed in constructor)
        // Approve queue to pull vault shares from test contract
        vault.approve(address(queue), type(uint256).max);

        // Fund vault with underlying for redemptions
        underlying.mint(address(vault), 10000e18);
    }

    // Helper to deposit vault shares as operator on behalf of a user
    function _deposit(uint256 vaultShares, address receiver) internal {
        vault.mint(address(this), vaultShares);
        queue.deposit(vaultShares, receiver);
    }

    // --- Auth Tests ---

    function testAuth() public {
        assertEq(queue.wards(address(this)), 1);

        address newOperator = address(0x123);
        queue.rely(newOperator);
        assertEq(queue.wards(newOperator), 1);

        queue.deny(newOperator);
        assertEq(queue.wards(newOperator), 0);

        vm.expectRevert("LCTSWithdrawQueue/not-authorized");
        vm.prank(newOperator);
        queue.settle(100e18);
    }

    function testUnauthorizedDepositReverts() public {
        address unauthorized = address(0x456);
        vault.mint(unauthorized, 100e18);
        vm.prank(unauthorized);
        vault.approve(address(queue), type(uint256).max);

        vm.expectRevert("LCTSWithdrawQueue/not-authorized");
        vm.prank(unauthorized);
        queue.deposit(100e18, unauthorized);
    }

    function testUnauthorizedClaimReverts() public {
        _deposit(100e18, alice);
        queue.settle(50e18);

        vm.expectRevert("LCTSWithdrawQueue/not-authorized");
        vm.prank(alice);
        queue.claim(alice, alice);
    }

    function testUnauthorizedClaimAndExitReverts() public {
        _deposit(100e18, alice);

        vm.expectRevert("LCTSWithdrawQueue/not-authorized");
        vm.prank(alice);
        queue.claimAndExit(alice, alice);
    }

    // --- Deposit Tests ---

    function testDeposit() public {
        vault.mint(address(this), 100e18);

        vm.expectEmit(true, true, true, true);
        emit Deposit(alice, 0, 100e18, 100e18);
        queue.deposit(100e18, alice);

        (uint256 gen, uint256 shares, uint256 rewardDebt) = queue.getPosition(alice);
        assertEq(gen, 0);
        assertEq(shares, 100e18);
        assertEq(rewardDebt, 0);
        assertEq(queue.totalUnderlying(), 100e18);
    }

    function testDepositZeroReverts() public {
        vm.expectRevert("LCTSWithdrawQueue/zero-amount");
        queue.deposit(0, alice);
    }

    function testDepositZeroAddressReverts() public {
        vault.mint(address(this), 100e18);
        vm.expectRevert("LCTSWithdrawQueue/zero-address");
        queue.deposit(100e18, address(0));
    }

    // --- Settle Tests ---

    function testSettle() public {
        _deposit(100e18, alice);

        vm.expectEmit(true, true, true, true);
        emit Settle(0, 50e18, 50e18, 50e18, false);
        uint256 redeemed = queue.settle(50e18);

        assertEq(redeemed, 50e18);
        assertEq(queue.totalUnderlying(), 50e18);
    }

    function testSettleFullCapacity() public {
        _deposit(100e18, alice);

        uint256 redeemed = queue.settle(100e18);

        assertEq(redeemed, 100e18);
        assertEq(queue.currentGen(), 1);
        assertTrue(queue.isFinalized(alice));
    }

    // --- Claim Tests ---

    function testClaim() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        uint256 pending = queue.pendingRewards(alice);
        assertEq(pending, 50e18);

        uint256 claimed = queue.claim(alice, alice);

        assertEq(claimed, 50e18);
        assertEq(underlying.balanceOf(alice), 50e18);
    }

    function testClaimFromFinalizedGeneration() public {
        _deposit(100e18, alice);

        queue.settle(100e18);

        uint256 claimed = queue.claim(alice, alice);

        assertEq(claimed, 100e18);
        assertEq(underlying.balanceOf(alice), 100e18);
    }

    function testClaimToAddress() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        queue.claim(alice, bob);

        assertEq(underlying.balanceOf(bob), 50e18);
        assertEq(underlying.balanceOf(alice), 0);
    }

    function testClaimNoPositionReverts() public {
        vm.expectRevert("LCTSWithdrawQueue/no-position");
        queue.claim(alice, alice);
    }

    // --- ClaimAndExit Tests ---

    function testClaimAndExit() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        (uint256 vaultShares, uint256 assets) = queue.claimAndExit(alice, alice);

        assertEq(vaultShares, 50e18); // Returned vault shares
        assertEq(assets, 50e18); // Claimed underlying
        assertEq(vault.balanceOf(alice), 50e18);
        assertEq(underlying.balanceOf(alice), 50e18);
    }

    function testClaimAndExitFinalizedReverts() public {
        _deposit(100e18, alice);

        queue.settle(100e18);

        vm.expectRevert("LCTSWithdrawQueue/not-current-gen");
        queue.claimAndExit(alice, alice);
    }

    function testClaimAndExitToAddress() public {
        _deposit(100e18, alice);

        queue.settle(50e18);

        queue.claimAndExit(alice, bob);

        assertEq(vault.balanceOf(bob), 50e18);
        assertEq(underlying.balanceOf(bob), 50e18);
    }

    // --- Proportional Distribution Tests ---

    function testProportionalDistribution() public {
        _deposit(100e18, alice);
        _deposit(300e18, bob);

        queue.settle(200e18);

        // Alice: 100/400 = 25% -> 50 underlying
        // Bob: 300/400 = 75% -> 150 underlying
        assertEq(queue.pendingRewards(alice), 50e18);
        assertEq(queue.pendingRewards(bob), 150e18);
    }

    // --- View Functions Tests ---

    function testUnderlyingBalance() public {
        _deposit(100e18, alice);

        assertEq(queue.underlyingBalance(alice), 100e18);

        queue.settle(50e18);

        assertEq(queue.underlyingBalance(alice), 50e18);
    }

    // --- Fuzz Tests ---

    function testFuzzDeposit(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        _deposit(amount, alice);

        assertEq(queue.totalUnderlying(), amount);
    }

    function testFuzzSettle(uint256 depositAmt, uint256 capacity) public {
        depositAmt = bound(depositAmt, 1e18, 1000e18);
        capacity = bound(capacity, 0, 2000e18);

        underlying.mint(address(vault), depositAmt); // Ensure vault has funds
        _deposit(depositAmt, alice);

        uint256 redeemed = queue.settle(capacity);

        if (capacity == 0) {
            assertEq(redeemed, 0);
        } else if (capacity >= depositAmt) {
            assertEq(redeemed, depositAmt);
            assertEq(queue.currentGen(), 1);
        } else {
            assertEq(redeemed, capacity);
            assertEq(queue.totalUnderlying(), depositAmt - capacity);
        }
    }
}
