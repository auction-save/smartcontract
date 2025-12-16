// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AuctionSaveFactory.sol";
import "../src/AuctionSaveGroup.sol";
import "../src/libraries/AuctionSaveTypes.sol";
import "./mocks/MockERC20.sol";

/// @title AuctionSaveGroupTest - Tests for AuctionSaveGroup
contract AuctionSaveGroupTest is Test {
    AuctionSaveFactory public factory;
    AuctionSaveGroup public group;
    MockERC20 public token;

    address public developer = makeAddr("developer");
    address public creator = makeAddr("creator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public dave = makeAddr("dave");
    address public eve = makeAddr("eve");

    address[] members;

    function setUp() public {
        token = new MockERC20("Test USDT", "TUSDT", 18);
        factory = new AuctionSaveFactory(developer);

        vm.prank(creator);
        address groupAddr = factory.createGroup(
            address(token),
            block.timestamp,
            1 weeks,
            true // demoMode
        );
        group = AuctionSaveGroup(groupAddr);

        members = [alice, bob, charlie, dave, eve];

        // Mint tokens and approve for all members
        // Per boss's design: need COMMITMENT + SECURITY_DEPOSIT = 100 ether to join
        // Plus extra for bid payments
        for (uint256 i = 0; i < members.length; i++) {
            token.mint(members[i], 10000 ether);
            vm.prank(members[i]);
            token.approve(address(group), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            JOIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Join_Success() public {
        vm.prank(alice);
        group.join();

        (bool joined,,,,,) = group.members(alice);
        assertTrue(joined);
        assertEq(group.getMemberCount(), 1);
    }

    function test_Join_TransfersCorrectAmount() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        group.join();

        // COMMITMENT + SECURITY_DEPOSIT = 100 ether
        uint256 expectedTransfer = AuctionSaveTypes.COMMITMENT + AuctionSaveTypes.SECURITY_DEPOSIT;
        assertEq(token.balanceOf(alice), balanceBefore - expectedTransfer);
    }

    function test_Join_AllMembers_ActivatesGroup() public {
        _joinAllMembers();

        assertEq(uint256(group.groupStatus()), uint256(AuctionSaveTypes.GroupStatus.ACTIVE));
        assertEq(group.currentCycle(), 1);
    }

    function test_Join_RevertWhen_AlreadyJoined() public {
        vm.prank(alice);
        group.join();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyJoined.selector);
        group.join();
    }

    function test_Join_RevertWhen_GroupFull() public {
        _joinAllMembers();

        address extraUser = makeAddr("extra");
        token.mint(extraUser, 1000 ether);
        vm.prank(extraUser);
        token.approve(address(group), type(uint256).max);

        // After group is full, status changes to ACTIVE, so error is GroupNotFilling
        vm.prank(extraUser);
        vm.expectRevert(AuctionSaveGroup.GroupNotFilling.selector);
        group.join();
    }

    /*//////////////////////////////////////////////////////////////
                        BIDDING TESTS (commit-reveal)
    //////////////////////////////////////////////////////////////*/

    function test_CommitBid_Success() public {
        _joinAllMembers();

        uint256 bps = 1000; // 10%
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bps, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        assertEq(group.bidCommitments(1, alice), commitment);
    }

    function test_RevealBid_Success() public {
        _joinAllMembers();

        uint256 bps = 1000; // 10%
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bps, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        vm.prank(alice);
        group.revealBid(bps, salt);

        assertEq(group.revealedBids(1, alice), bps);
        assertTrue(group.hasRevealedBid(1, alice));
    }

    function test_RevealBid_RevertWhen_BidTooHigh() public {
        _joinAllMembers();

        uint256 bps = 4000; // 40% > MAX_BID_BPS (30%)
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bps, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.BidTooHigh.selector);
        group.revealBid(bps, salt);
    }

    function test_RevealBid_RevertWhen_InvalidReveal() public {
        _joinAllMembers();

        uint256 bps = 1000;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bps, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        // Try to reveal with wrong bps
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.InvalidReveal.selector);
        group.revealBid(2000, salt);
    }

    /*//////////////////////////////////////////////////////////////
                        CYCLE RESOLUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ResolveCycle_HighestBidderWins() public {
        _joinAllMembers();

        // Alice bids 10%, Bob bids 20%, Charlie bids 30%
        _commitAndRevealBid(alice, 1000, keccak256("salt1"));
        _commitAndRevealBid(bob, 2000, keccak256("salt2"));
        _commitAndRevealBid(charlie, 3000, keccak256("salt3"));

        group.resolveCycle();

        // Charlie should win (highest bid)
        (, bool hasWon,,,,) = group.members(charlie);
        assertTrue(hasWon);
    }

    function test_ResolveCycle_AdvancesToNextCycle() public {
        _joinAllMembers();
        _commitAndRevealBid(alice, 1000, keccak256("salt"));

        group.resolveCycle();

        assertEq(group.currentCycle(), 2);
    }

    function test_ResolveCycle_CompletesAfterAllCycles() public {
        _joinAllMembers();

        // Run through all 5 cycles
        for (uint256 i = 0; i < 5; i++) {
            address member = members[i];
            _commitAndRevealBid(member, 1000, keccak256(abi.encodePacked("salt", i)));

            vm.warp(group.cycleStart());
            group.resolveCycle();
        }

        assertEq(uint256(group.groupStatus()), uint256(AuctionSaveTypes.GroupStatus.COMPLETED));
    }

    /*//////////////////////////////////////////////////////////////
                        PENALTY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Penalize_Success() public {
        _joinAllMembers();

        group.penalize(alice);

        (,, bool defaulted,,,) = group.members(alice);
        assertTrue(defaulted);
    }

    function test_Penalize_ForfeitsSecurity() public {
        _joinAllMembers();

        uint256 escrowBefore = group.penaltyEscrow();
        group.penalize(alice);

        // Should forfeit SECURITY_DEPOSIT
        assertEq(group.penaltyEscrow(), escrowBefore + AuctionSaveTypes.SECURITY_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                        SPEED UP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SpeedUpCycle_Success() public {
        _joinAllMembers();

        uint256 originalCycleStart = group.cycleStart();
        vm.warp(block.timestamp + 1 days);

        group.speedUpCycle();

        assertEq(group.cycleStart(), block.timestamp);
        assertTrue(group.cycleStart() != originalCycleStart);
    }

    function test_SpeedUpCycle_RevertWhen_NotDemoMode() public {
        // Create a non-demo group
        vm.prank(creator);
        address groupAddr = factory.createGroup(
            address(token),
            block.timestamp,
            1 weeks,
            false // demoMode = false
        );
        AuctionSaveGroup nonDemoGroup = AuctionSaveGroup(groupAddr);

        // Join all members
        for (uint256 i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            token.approve(address(nonDemoGroup), type(uint256).max);
            vm.prank(members[i]);
            nonDemoGroup.join();
        }

        vm.expectRevert(AuctionSaveGroup.NotDemoMode.selector);
        nonDemoGroup.speedUpCycle();
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawSecurity_Success() public {
        _joinAllMembers();

        // Complete all cycles
        for (uint256 i = 0; i < 5; i++) {
            address member = members[i];
            _commitAndRevealBid(member, 1000, keccak256(abi.encodePacked("salt", i)));
            vm.warp(group.cycleStart());
            group.resolveCycle();
        }

        // Alice (who won cycle 1) should be able to withdraw security
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        group.withdrawSecurity();

        assertEq(token.balanceOf(alice), balanceBefore + AuctionSaveTypes.SECURITY_DEPOSIT);
    }

    function test_WithdrawWithheld_Success() public {
        _joinAllMembers();

        // Complete all cycles
        for (uint256 i = 0; i < 5; i++) {
            address member = members[i];
            _commitAndRevealBid(member, 1000, keccak256(abi.encodePacked("salt", i)));
            vm.warp(group.cycleStart());
            group.resolveCycle();
        }

        // Alice (who won cycle 1) should have withheld balance
        (,,,,, uint256 withheld) = group.members(alice);
        assertTrue(withheld > 0);

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        group.withdrawWithheld();

        assertEq(token.balanceOf(alice), balanceBefore + withheld);
    }

    function test_WithdrawDevFee_Success() public {
        _joinAllMembers();

        // Complete all cycles
        for (uint256 i = 0; i < 5; i++) {
            address member = members[i];
            _commitAndRevealBid(member, 1000, keccak256(abi.encodePacked("salt", i)));
            vm.warp(group.cycleStart());
            group.resolveCycle();
        }

        uint256 devFee = group.devFeeBalance();
        assertTrue(devFee > 0);

        uint256 balanceBefore = token.balanceOf(developer);
        vm.prank(developer);
        group.withdrawDevFee();

        assertEq(token.balanceOf(developer), balanceBefore + devFee);
    }

    /*//////////////////////////////////////////////////////////////
                        ADDITIONAL COVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CommitBid_RevertWhen_NotMember() public {
        _joinAllMembers();

        address nonMember = makeAddr("nonMember");
        bytes32 commitment = keccak256("test");

        vm.prank(nonMember);
        vm.expectRevert(AuctionSaveGroup.NotMember.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_GroupNotActive() public {
        // Only 1 member joined, group not active
        vm.prank(alice);
        group.join();

        bytes32 commitment = keccak256("test");
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.GroupNotActive.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_MemberPenalized() public {
        _joinAllMembers();

        group.penalize(alice);

        bytes32 commitment = keccak256("test");
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.MemberPenalized.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_AlreadyWon() public {
        _joinAllMembers();

        // Alice wins cycle 1
        _commitAndRevealBid(alice, 1000, keccak256("salt"));
        group.resolveCycle();

        // Alice tries to bid again in cycle 2
        bytes32 commitment = _computeCommitment(1000, keccak256("salt2"), alice, 2);
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyWon.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_AlreadyCommitted() public {
        _joinAllMembers();

        bytes32 commitment = _computeCommitment(1000, keccak256("salt"), alice, 1);
        vm.prank(alice);
        group.commitBid(commitment);

        // Try to commit again
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyCommitted.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_InvalidCommitment() public {
        _joinAllMembers();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.InvalidCommitment.selector);
        group.commitBid(bytes32(0));
    }

    function test_RevealBid_RevertWhen_NotMember() public {
        _joinAllMembers();

        address nonMember = makeAddr("nonMember");
        vm.prank(nonMember);
        vm.expectRevert(AuctionSaveGroup.NotMember.selector);
        group.revealBid(1000, keccak256("salt"));
    }

    function test_RevealBid_RevertWhen_MemberPenalized() public {
        _joinAllMembers();

        bytes32 commitment = _computeCommitment(1000, keccak256("salt"), alice, 1);
        vm.prank(alice);
        group.commitBid(commitment);

        group.penalize(alice);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.MemberPenalized.selector);
        group.revealBid(1000, keccak256("salt"));
    }

    function test_RevealBid_RevertWhen_AlreadyWon() public {
        _joinAllMembers();

        // Alice wins cycle 1
        _commitAndRevealBid(alice, 1000, keccak256("salt"));
        group.resolveCycle();

        // Bob commits in cycle 2, then Alice tries to reveal (but she already won)
        // This is a bit contrived but tests the path
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyWon.selector);
        group.revealBid(1000, keccak256("salt"));
    }

    function test_RevealBid_RevertWhen_NotCommitted() public {
        _joinAllMembers();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NotCommitted.selector);
        group.revealBid(1000, keccak256("salt"));
    }

    function test_RevealBid_RevertWhen_AlreadyRevealed() public {
        _joinAllMembers();

        _commitAndRevealBid(alice, 1000, keccak256("salt"));

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyRevealed.selector);
        group.revealBid(1000, keccak256("salt"));
    }

    function test_ResolveCycle_RevertWhen_CycleNotStarted() public {
        // Create group with future start time
        vm.prank(creator);
        address groupAddr = factory.createGroup(
            address(token),
            block.timestamp + 1 days, // Future start
            1 weeks,
            true
        );
        AuctionSaveGroup futureGroup = AuctionSaveGroup(groupAddr);

        for (uint256 i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            token.approve(address(futureGroup), type(uint256).max);
            vm.prank(members[i]);
            futureGroup.join();
        }

        vm.expectRevert(AuctionSaveGroup.CycleNotStarted.selector);
        futureGroup.resolveCycle();
    }

    function test_ResolveCycle_FallbackWhenNoBids() public {
        _joinAllMembers();

        // No one bids, first eligible member wins
        group.resolveCycle();

        // Alice should win as first eligible
        (, bool hasWon,,,,) = group.members(alice);
        assertTrue(hasWon);
    }

    function test_ResolveCycle_EarlyCompleteWhenAllPenalized() public {
        _joinAllMembers();

        // Penalize all members
        for (uint256 i = 0; i < members.length; i++) {
            group.penalize(members[i]);
        }

        // Resolve should complete early
        group.resolveCycle();

        assertEq(uint256(group.groupStatus()), uint256(AuctionSaveTypes.GroupStatus.COMPLETED));
    }

    function test_Penalize_RevertWhen_AlreadyPenalized() public {
        _joinAllMembers();

        group.penalize(alice);

        vm.expectRevert(AuctionSaveGroup.AlreadyPenalized.selector);
        group.penalize(alice);
    }

    function test_Penalize_ForfeitsWithheld() public {
        _joinAllMembers();

        // Alice wins and gets withheld
        _commitAndRevealBid(alice, 1000, keccak256("salt"));
        group.resolveCycle();

        (,,,,, uint256 withheldBefore) = group.members(alice);
        assertTrue(withheldBefore > 0);

        uint256 escrowBefore = group.penaltyEscrow();
        group.penalize(alice);

        // Should forfeit security + withheld
        assertEq(group.penaltyEscrow(), escrowBefore + AuctionSaveTypes.SECURITY_DEPOSIT + withheldBefore);
    }

    function test_WithdrawSecurity_RevertWhen_GroupNotCompleted() public {
        _joinAllMembers();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.GroupNotCompleted.selector);
        group.withdrawSecurity();
    }

    function test_WithdrawSecurity_RevertWhen_NothingToRefund() public {
        _joinAllMembers();
        _completeAllCycles();

        // Withdraw once
        vm.prank(alice);
        group.withdrawSecurity();

        // Try again
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NothingToRefund.selector);
        group.withdrawSecurity();
    }

    function test_WithdrawWithheld_RevertWhen_GroupNotCompleted() public {
        _joinAllMembers();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.GroupNotCompleted.selector);
        group.withdrawWithheld();
    }

    function test_WithdrawWithheld_RevertWhen_NothingWithheld() public {
        _joinAllMembers();
        _completeAllCycles();

        // Withdraw once
        vm.prank(alice);
        group.withdrawWithheld();

        // Try again
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NothingWithheld.selector);
        group.withdrawWithheld();
    }

    function test_WithdrawDevFee_RevertWhen_NotDeveloper() public {
        _joinAllMembers();
        _completeAllCycles();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NotDeveloper.selector);
        group.withdrawDevFee();
    }

    function test_WithdrawDevFee_RevertWhen_NoFeesToWithdraw() public {
        _joinAllMembers();
        _completeAllCycles();

        // Withdraw once
        vm.prank(developer);
        group.withdrawDevFee();

        // Try again
        vm.prank(developer);
        vm.expectRevert(AuctionSaveGroup.NoFeesToWithdraw.selector);
        group.withdrawDevFee();
    }

    function test_GetMembers_ReturnsCorrectList() public {
        _joinAllMembers();

        address[] memory membersList = group.getMembers();
        assertEq(membersList.length, 5);
        assertEq(membersList[0], alice);
        assertEq(membersList[1], bob);
    }

    function test_MemberList_ReturnsCorrectAddress() public {
        _joinAllMembers();

        assertEq(group.memberList(0), alice);
        assertEq(group.memberList(4), eve);
    }

    function test_ResolveCycle_ZeroBidWinner() public {
        _joinAllMembers();

        // Alice commits and reveals 0 bid
        _commitAndRevealBid(alice, 0, keccak256("salt"));

        group.resolveCycle();

        // Alice should still win (only bidder, even with 0)
        (, bool hasWon,,,,) = group.members(alice);
        assertTrue(hasWon);
    }

    function test_ResolveCycle_SkipsPenalizedInFallback() public {
        _joinAllMembers();

        // Penalize Alice (first member)
        group.penalize(alice);

        // No bids, fallback should skip Alice and pick Bob
        group.resolveCycle();

        (, bool aliceWon,,,,) = group.members(alice);
        (, bool bobWon,,,,) = group.members(bob);
        assertFalse(aliceWon);
        assertTrue(bobWon);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _joinAllMembers() internal {
        for (uint256 i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            group.join();
        }
    }

    function _computeCommitment(uint256 bps, bytes32 salt, address bidder, uint256 cycle)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(bps, salt, bidder, cycle, address(group), block.chainid));
    }

    function _commitAndRevealBid(address bidder, uint256 bps, bytes32 salt) internal {
        bytes32 commitment = _computeCommitment(bps, salt, bidder, group.currentCycle());

        vm.prank(bidder);
        group.commitBid(commitment);

        vm.prank(bidder);
        group.revealBid(bps, salt);
    }

    function _completeAllCycles() internal {
        for (uint256 i = 0; i < 5; i++) {
            address member = members[i];
            _commitAndRevealBid(member, 1000, keccak256(abi.encodePacked("salt", i)));
            vm.warp(group.cycleStart());
            group.resolveCycle();
        }
    }
}
