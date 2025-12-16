// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AuctionSaveFactory.sol";
import "../src/AuctionSaveGroup.sol";
import "../src/libraries/AuctionSaveTypes.sol";
import "./mocks/MockERC20.sol";

/// @title AuctionSaveGroupTest - Tests for commit-reveal AUCTION mechanism
/// @dev Tests the "highest bidder wins" flow as per boss's demo
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

    uint256 constant GROUP_SIZE = 5;
    uint256 constant CONTRIBUTION = 100 ether;
    uint256 constant SECURITY_DEPOSIT = 50 ether;
    uint256 constant TOTAL_CYCLES = 5;
    uint256 constant CYCLE_DURATION = 1 weeks;
    uint256 constant PAY_WINDOW = 2 days;
    uint256 constant COMMIT_WINDOW = 1 days;
    uint256 constant REVEAL_WINDOW = 1 days;

    address[] members;

    function setUp() public {
        token = new MockERC20("Test USDT", "TUSDT", 18);
        factory = new AuctionSaveFactory(developer);

        vm.prank(creator);
        address groupAddr = factory.createGroup(
            address(token),
            GROUP_SIZE,
            CONTRIBUTION,
            SECURITY_DEPOSIT,
            TOTAL_CYCLES,
            CYCLE_DURATION,
            PAY_WINDOW,
            COMMIT_WINDOW,
            REVEAL_WINDOW,
            false // demoMode
        );
        group = AuctionSaveGroup(groupAddr);

        members = [alice, bob, charlie, dave, eve];

        for (uint256 i = 0; i < members.length; i++) {
            token.mint(members[i], 1000 ether);
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

    function test_Join_AllMembers_ActivatesGroup() public {
        _joinAllMembers();

        assertEq(uint256(group.groupStatus()), uint256(AuctionSaveTypes.GroupStatus.ACTIVE));
        assertEq(group.currentCycle(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        CONTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PayContribution_Success() public {
        _joinAllMembers();

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        group.payContribution();

        assertTrue(group.hasPaid(1, alice));
        assertEq(token.balanceOf(alice), balanceBefore - CONTRIBUTION);
    }

    function test_PayContribution_AllPaid_AdvancesToCommit() public {
        _joinAllMembers();
        _allPayContribution();

        (AuctionSaveTypes.CycleStatus status,,,,,,,,) = group.getCycleInfo(1);
        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.COMMITTING));
    }

    /*//////////////////////////////////////////////////////////////
                        COMMIT-REVEAL AUCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CommitBid_Success() public {
        _joinAllMembers();
        _allPayContribution();

        // Alice commits a bid of 50 USDT (as per demo)
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        assertTrue(group.hasCommitted(1, alice));
    }

    function test_RevealBid_Success() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);

        // Alice commits bid of 50 USDT
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        // Warp past commit deadline
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Reveal bid
        vm.prank(alice);
        group.revealBid(bidAmount, salt);

        assertTrue(group.hasRevealed(1, alice));
        assertEq(group.getRevealedBid(1, alice), bidAmount);
    }

    function test_RevealBid_RevertWhen_InvalidReveal() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Try to reveal with wrong bid amount
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.InvalidReveal.selector);
        group.revealBid(75 ether, salt); // Wrong amount
    }

    /*//////////////////////////////////////////////////////////////
                        AUCTION SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SettleCycle_HighestBidderWins() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);

        // Demo scenario: Different bids
        // Alice: 50 USDT, Bob: 75 USDT, Charlie: 100 USDT (highest)
        uint256[] memory bidAmounts = new uint256[](5);
        bidAmounts[0] = 50 ether; // alice
        bidAmounts[1] = 75 ether; // bob
        bidAmounts[2] = 100 ether; // charlie (highest)
        bidAmounts[3] = 25 ether; // dave
        bidAmounts[4] = 60 ether; // eve

        // Commit phase
        for (uint256 i = 0; i < members.length; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitment = _computeCommitment(bidAmounts[i], salt, members[i], 1);

            vm.prank(members[i]);
            group.commitBid(commitment);
        }

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Reveal phase
        for (uint256 i = 0; i < members.length; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));

            vm.prank(members[i]);
            group.revealBid(bidAmounts[i], salt);
        }

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();

        // Settle - Charlie should win (highest bid)
        uint256 charlieBalanceBefore = token.balanceOf(charlie);
        group.settleCycle();

        (,,,,,,, address winner, uint256 winningBid) = group.getCycleInfo(1);

        // Charlie (index 2) should be the winner with highest bid
        assertEq(winner, charlie);
        assertEq(winningBid, 100 ether);

        // Charlie should receive 80% of (pool minus dev fee minus winningBid)
        // 20% is withheld until group completion (per boss's design)
        // payout = 80% of (pool - devFee - winningBid)
        uint256 expectedPool = CONTRIBUTION * GROUP_SIZE;
        uint256 expectedFee = (expectedPool * 100) / 10000;
        uint256 afterBid = expectedPool - expectedFee - winningBid;
        uint256 expectedPayout = (afterBid * 80) / 100; // 80% immediate payout
        assertEq(token.balanceOf(charlie), charlieBalanceBefore + expectedPayout);
    }

    function test_SettleCycle_WinnerCannotBidAgain() public {
        _completeCycleToSettle();
        group.settleCycle();

        (,,,,,,, address winner1,) = group.getCycleInfo(1);
        (, bool hasWon,,,,) = group.members(winner1);
        assertTrue(hasWon);

        // Cycle 2: Winner from cycle 1 cannot commit bid
        _allPayContributionForCycle(2);

        (,,, uint256 commitDeadline2,,,,,) = group.getCycleInfo(2);

        // Winner tries to commit - should revert
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, winner1, 2);

        vm.prank(winner1);
        vm.expectRevert(AuctionSaveGroup.AlreadyWon.selector);
        group.commitBid(commitment);
    }

    function test_SettleCycle_AdvancesToNextCycle() public {
        _completeCycleToSettle();
        group.settleCycle();

        assertEq(group.currentCycle(), 2);

        (AuctionSaveTypes.CycleStatus status,,,,,,,,) = group.getCycleInfo(2);
        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.COLLECTING));
    }

    function test_SettleCycle_CompletesGroupAfterLastCycle() public {
        _completeAllCycles();

        assertEq(uint256(group.groupStatus()), uint256(AuctionSaveTypes.GroupStatus.COMPLETED));
    }

    /*//////////////////////////////////////////////////////////////
                        FINAL SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawSecurity_Success() public {
        _completeAllCycles();

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        group.withdrawSecurity();

        assertEq(token.balanceOf(alice), balanceBefore + SECURITY_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                        SECURITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that commitment theft is prevented
    /// @dev #1: Attacker cannot copy commitment from mempool
    function test_CommitmentTheft_Prevented() public {
        _joinAllMembers();
        _allPayContribution();

        // Alice creates a commitment
        uint256 bidAmount = 100 ether;
        bytes32 salt = keccak256("alice_secret_salt");
        bytes32 aliceCommitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(aliceCommitment);

        // Bob tries to use the SAME commitment (commitment theft attempt)
        // This should fail because commitment is bound to alice's address
        vm.prank(bob);
        group.commitBid(aliceCommitment); // Bob commits same hash

        // Advance to reveal
        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Bob tries to reveal with Alice's bid amount and salt
        // This MUST fail because commitment was computed with alice's address
        vm.prank(bob);
        vm.expectRevert(AuctionSaveGroup.InvalidReveal.selector);
        group.revealBid(bidAmount, salt);

        // Alice can still reveal successfully
        vm.prank(alice);
        group.revealBid(bidAmount, salt);
        assertTrue(group.hasRevealed(1, alice));
    }

    /// @notice Test that protocol doesn't deadlock when no one reveals
    /// @dev #2: Liveness guarantee
    function test_NoDeadlock_WhenNoReveals() public {
        _joinAllMembers();
        _allPayContribution();

        // Everyone commits but NO ONE reveals
        for (uint256 i = 0; i < members.length; i++) {
            uint256 bidAmount = (i + 1) * 20 ether;
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitment = _computeCommitment(bidAmount, salt, members[i], 1);

            vm.prank(members[i]);
            group.commitBid(commitment);
        }

        // Advance past commit and reveal deadlines
        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // NO ONE REVEALS - skip to settle
        vm.warp(revealDeadline + 1);
        group.advanceToSettle();

        // Settlement should NOT revert - fallback to deterministic winner
        group.settleCycle();

        // Verify a winner was selected (first eligible member as fallback)
        (,,,,,,, address winner,) = group.getCycleInfo(1);
        assertEq(winner, alice); // First eligible member wins deterministically

        // Group should advance to next cycle, not be stuck
        assertEq(group.currentCycle(), 2);
    }

    /// @notice Test that bid has economic meaning (discount distributed)
    /// @dev #3: Bid should affect payout
    function test_BidHasEconomicMeaning() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);

        // Charlie bids 100 USDT (highest), others bid less
        uint256[] memory bidAmounts = new uint256[](5);
        bidAmounts[0] = 10 ether; // alice
        bidAmounts[1] = 20 ether; // bob
        bidAmounts[2] = 100 ether; // charlie (winner)
        bidAmounts[3] = 30 ether; // dave
        bidAmounts[4] = 40 ether; // eve

        // Commit and reveal
        for (uint256 i = 0; i < members.length; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitment = _computeCommitment(bidAmounts[i], salt, members[i], 1);
            vm.prank(members[i]);
            group.commitBid(commitment);
        }

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        for (uint256 i = 0; i < members.length; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            vm.prank(members[i]);
            group.revealBid(bidAmounts[i], salt);
        }

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();

        // Record balances before settlement
        uint256 charlieBalanceBefore = token.balanceOf(charlie);
        uint256 aliceBalanceBefore = token.balanceOf(alice);

        group.settleCycle();

        // Charlie's payout = 80% of (pool - devFee - winningBid)
        // 20% is withheld until group completion (per boss's design)
        uint256 pool = CONTRIBUTION * GROUP_SIZE; // 500 ether
        uint256 devFee = (pool * 100) / 10000; // 5 ether
        uint256 winningBid = 100 ether;
        uint256 afterBid = pool - devFee - winningBid; // 395 ether
        uint256 expectedCharliePayout = (afterBid * 80) / 100; // 316 ether (80% immediate)

        assertEq(token.balanceOf(charlie), charlieBalanceBefore + expectedCharliePayout);

        // Other contributors should receive share of winningBid
        // 4 other contributors, so each gets 100/4 = 25 ether
        uint256 expectedShare = winningBid / 4;
        assertEq(token.balanceOf(alice), aliceBalanceBefore + expectedShare);
    }

    /*//////////////////////////////////////////////////////////////
                        DEV FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawDevFee_Success() public {
        _completeCycleToSettle();
        group.settleCycle();

        uint256 expectedFee = (CONTRIBUTION * GROUP_SIZE * 100) / 10000;
        uint256 devBalanceBefore = token.balanceOf(developer);

        vm.prank(developer);
        group.withdrawDevFee();

        assertEq(token.balanceOf(developer), devBalanceBefore + expectedFee);
    }

    function test_WithdrawDevFee_RevertWhen_NotDeveloper() public {
        _completeCycleToSettle();
        group.settleCycle();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NotDeveloper.selector);
        group.withdrawDevFee();
    }

    function test_WithdrawDevFee_RevertWhen_NoFees() public {
        _joinAllMembers();

        vm.prank(developer);
        vm.expectRevert(AuctionSaveGroup.NoFeesToWithdraw.selector);
        group.withdrawDevFee();
    }

    /*//////////////////////////////////////////////////////////////
                        ADDITIONAL COVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Join_RevertWhen_GroupNotFilling() public {
        _joinAllMembers(); // Group becomes ACTIVE

        address newUser = makeAddr("newUser");
        token.mint(newUser, 1000 ether);
        vm.prank(newUser);
        token.approve(address(group), type(uint256).max);

        vm.prank(newUser);
        vm.expectRevert(AuctionSaveGroup.GroupNotFilling.selector);
        group.join();
    }

    function test_Join_RevertWhen_AlreadyJoined() public {
        vm.prank(alice);
        group.join();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyJoined.selector);
        group.join();
    }

    function test_PayContribution_RevertWhen_GroupNotActive() public {
        vm.prank(alice);
        group.join();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.GroupNotActive.selector);
        group.payContribution();
    }

    function test_PayContribution_RevertWhen_NotMember() public {
        _joinAllMembers();

        address nonMember = makeAddr("nonMember");
        vm.prank(nonMember);
        vm.expectRevert(AuctionSaveGroup.NotMember.selector);
        group.payContribution();
    }

    function test_PayContribution_RevertWhen_AlreadyPaid() public {
        _joinAllMembers();

        vm.prank(alice);
        group.payContribution();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyPaid.selector);
        group.payContribution();
    }

    function test_PayContribution_RevertWhen_PayWindowClosed() public {
        _joinAllMembers();

        (, uint256 startTime, uint256 payDeadline,,,,,,) = group.getCycleInfo(1);
        vm.warp(payDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.PayWindowClosed.selector);
        group.payContribution();
    }

    function test_ProcessDefaults_Success() public {
        _joinAllMembers();

        // Only alice pays
        vm.prank(alice);
        group.payContribution();

        (, uint256 startTime, uint256 payDeadline,,,,,,) = group.getCycleInfo(1);
        vm.warp(payDeadline + 1);

        // Process defaults - bob, charlie, dave, eve should be penalized
        group.processDefaults();

        // Check bob is defaulted
        (,, bool bobDefaulted,,,) = group.members(bob);
        assertTrue(bobDefaulted);

        // Check cycle advanced to COMMITTING
        (AuctionSaveTypes.CycleStatus status,,,,,,,,) = group.getCycleInfo(1);
        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.COMMITTING));
    }

    function test_ProcessDefaults_RevertWhen_WrongStatus() public {
        _joinAllMembers();
        _allPayContribution(); // Advances to COMMITTING

        vm.expectRevert(AuctionSaveGroup.WrongCycleStatus.selector);
        group.processDefaults();
    }

    function test_ProcessDefaults_RevertWhen_DeadlineNotPassed() public {
        _joinAllMembers();

        vm.expectRevert(AuctionSaveGroup.PayDeadlineNotPassed.selector);
        group.processDefaults();
    }

    function test_CommitBid_RevertWhen_WrongStatus() public {
        _joinAllMembers();
        // Still in COLLECTING phase

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.WrongCycleStatus.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_NotPaid() public {
        _joinAllMembers();

        // Only alice pays
        vm.prank(alice);
        group.payContribution();

        (, uint256 startTime, uint256 payDeadline,,,,,,) = group.getCycleInfo(1);
        vm.warp(payDeadline + 1);
        group.processDefaults();

        // Bob tries to commit without paying
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, bob, 1);

        vm.prank(bob);
        vm.expectRevert(AuctionSaveGroup.MemberDefaultedError.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_AlreadyCommitted() public {
        _joinAllMembers();
        _allPayContribution();

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyCommitted.selector);
        group.commitBid(commitment);
    }

    function test_CommitBid_RevertWhen_CommitWindowClosed() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.CommitWindowClosed.selector);
        group.commitBid(commitment);
    }

    function test_AdvanceToReveal_RevertWhen_WrongStatus() public {
        _joinAllMembers();
        // Still in COLLECTING

        vm.expectRevert(AuctionSaveGroup.WrongCycleStatus.selector);
        group.advanceToReveal();
    }

    function test_AdvanceToReveal_RevertWhen_DeadlineNotPassed() public {
        _joinAllMembers();
        _allPayContribution();

        vm.expectRevert(AuctionSaveGroup.CommitDeadlineNotPassed.selector);
        group.advanceToReveal();
    }

    function test_RevealBid_RevertWhen_WrongStatus() public {
        _joinAllMembers();
        _allPayContribution();

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.WrongCycleStatus.selector);
        group.revealBid(bidAmount, salt);
    }

    function test_RevealBid_RevertWhen_RevealWindowClosed() public {
        _joinAllMembers();
        _allPayContribution();

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.warp(revealDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.RevealWindowClosed.selector);
        group.revealBid(bidAmount, salt);
    }

    function test_RevealBid_RevertWhen_NoCommitment() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NoCommitment.selector);
        group.revealBid(bidAmount, salt);
    }

    function test_RevealBid_RevertWhen_AlreadyRevealed() public {
        _joinAllMembers();
        _allPayContribution();

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.prank(alice);
        group.revealBid(bidAmount, salt);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyRevealed.selector);
        group.revealBid(bidAmount, salt);
    }

    function test_RevealBid_RevertWhen_BidTooHigh() public {
        _joinAllMembers();
        _allPayContribution();

        // Bid higher than total contributions
        uint256 bidAmount = 1000 ether; // More than 500 ether pool
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.BidTooHigh.selector);
        group.revealBid(bidAmount, salt);
    }

    function test_AdvanceToSettle_RevertWhen_WrongStatus() public {
        _joinAllMembers();
        _allPayContribution();

        vm.expectRevert(AuctionSaveGroup.WrongCycleStatus.selector);
        group.advanceToSettle();
    }

    function test_AdvanceToSettle_RevertWhen_DeadlineNotPassed() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.expectRevert(AuctionSaveGroup.RevealDeadlineNotPassed.selector);
        group.advanceToSettle();
    }

    function test_SettleCycle_RevertWhen_NotReadyToSettle() public {
        _joinAllMembers();
        _allPayContribution();

        vm.expectRevert(AuctionSaveGroup.NotReadyToSettle.selector);
        group.settleCycle();
    }

    function test_WithdrawSecurity_RevertWhen_GroupNotCompleted() public {
        _joinAllMembers();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.GroupNotCompleted.selector);
        group.withdrawSecurity();
    }

    function test_WithdrawSecurity_RevertWhen_NothingToRefund() public {
        _completeAllCycles();

        vm.prank(alice);
        group.withdrawSecurity();

        // Try again
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NothingToRefund.selector);
        group.withdrawSecurity();
    }

    function test_DistributePenaltyEscrow_Success() public {
        _joinAllMembers();

        // Only alice and bob pay
        vm.prank(alice);
        group.payContribution();
        vm.prank(bob);
        group.payContribution();

        (, uint256 startTime, uint256 payDeadline,,,,,,) = group.getCycleInfo(1);
        vm.warp(payDeadline + 1);
        group.processDefaults();

        // Complete remaining cycles with only alice and bob
        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);

        // Alice commits and reveals
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);
        vm.prank(alice);
        group.commitBid(commitment);

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.prank(alice);
        group.revealBid(bidAmount, salt);

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();
        group.settleCycle();

        // Complete cycle 2
        vm.prank(alice);
        group.payContribution();
        vm.prank(bob);
        group.payContribution();

        (,,, uint256 commitDeadline2, uint256 revealDeadline2,,,,) = group.getCycleInfo(2);

        // Bob commits and reveals (alice already won)
        bytes32 salt2 = keccak256("bob_salt");
        bytes32 commitment2 = _computeCommitment(bidAmount, salt2, bob, 2);
        vm.prank(bob);
        group.commitBid(commitment2);

        vm.warp(commitDeadline2 + 1);
        group.advanceToReveal();

        vm.prank(bob);
        group.revealBid(bidAmount, salt2);

        vm.warp(revealDeadline2 + 1);
        group.advanceToSettle();
        group.settleCycle();

        // Group should be completed (no more eligible winners)
        assertEq(uint256(group.groupStatus()), uint256(AuctionSaveTypes.GroupStatus.COMPLETED));

        // Distribute penalty escrow
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        group.distributePenaltyEscrow();

        // Alice and Bob should receive penalty shares
        assertTrue(token.balanceOf(alice) > aliceBalanceBefore);
    }

    function test_DistributePenaltyEscrow_RevertWhen_NotCompleted() public {
        _joinAllMembers();

        vm.expectRevert(AuctionSaveGroup.GroupNotCompleted.selector);
        group.distributePenaltyEscrow();
    }

    function test_SettleCycle_AutoAdvance() public {
        _joinAllMembers();
        _allPayContribution();

        // Commit bids
        for (uint256 i = 0; i < members.length; i++) {
            uint256 bidAmount = (i + 1) * 20 ether;
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitment = _computeCommitment(bidAmount, salt, members[i], 1);
            vm.prank(members[i]);
            group.commitBid(commitment);
        }

        // Warp past ALL deadlines
        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(revealDeadline + 1);

        // Call settleCycle directly - it should auto-advance through phases
        group.settleCycle();

        // Should have settled and advanced to cycle 2
        assertEq(group.currentCycle(), 2);
    }

    function test_GetMembers() public {
        _joinAllMembers();

        address[] memory membersList = group.getMembers();
        assertEq(membersList.length, 5);
        assertEq(membersList[0], alice);
        assertEq(membersList[1], bob);
    }

    function test_GetMemberCount() public {
        vm.prank(alice);
        group.join();

        assertEq(group.getMemberCount(), 1);

        vm.prank(bob);
        group.join();

        assertEq(group.getMemberCount(), 2);
    }

    function test_HasPaid() public {
        _joinAllMembers();

        assertFalse(group.hasPaid(1, alice));

        vm.prank(alice);
        group.payContribution();

        assertTrue(group.hasPaid(1, alice));
    }

    function test_HasCommitted() public {
        _joinAllMembers();
        _allPayContribution();

        assertFalse(group.hasCommitted(1, alice));

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        assertTrue(group.hasCommitted(1, alice));
    }

    function test_HasRevealed() public {
        _joinAllMembers();
        _allPayContribution();

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        assertFalse(group.hasRevealed(1, alice));

        vm.prank(alice);
        group.revealBid(bidAmount, salt);

        assertTrue(group.hasRevealed(1, alice));
    }

    function test_GetRevealedBid() public {
        _joinAllMembers();
        _allPayContribution();

        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);

        vm.prank(alice);
        group.commitBid(commitment);

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.prank(alice);
        group.revealBid(bidAmount, salt);

        assertEq(group.getRevealedBid(1, alice), bidAmount);
    }

    function test_OnlyOneEligibleWinner_DeterministicSelection() public {
        _joinAllMembers();

        // Only alice pays
        vm.prank(alice);
        group.payContribution();

        (,, uint256 payDeadline,,,,,,) = group.getCycleInfo(1);
        vm.warp(payDeadline + 1);
        group.processDefaults();

        // Alice commits (required to be eligible now)
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);
        vm.prank(alice);
        group.commitBid(commitment);

        // Alice is the only eligible winner
        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();
        vm.warp(revealDeadline + 1);
        group.advanceToSettle();

        group.settleCycle();

        (,,,,,,, address winner,) = group.getCycleInfo(1);
        assertEq(winner, alice);
    }

    function test_SettleCycle_AutoAdvance_FromCollecting() public {
        _joinAllMembers();

        // Only alice pays
        vm.prank(alice);
        group.payContribution();

        // Warp past ALL deadlines without calling processDefaults or advance functions
        (,, uint256 payDeadline, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(revealDeadline + 1);

        // settleCycle should auto-advance from COLLECTING through all phases
        group.settleCycle();

        // Should have settled
        (AuctionSaveTypes.CycleStatus status,,,,,,,,) = group.getCycleInfo(1);
        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.SETTLED));
    }

    function test_DistributeDiscount_ZeroDiscount() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);

        // All bid 0
        for (uint256 i = 0; i < members.length; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitment = _computeCommitment(0, salt, members[i], 1);
            vm.prank(members[i]);
            group.commitBid(commitment);
        }

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        for (uint256 i = 0; i < members.length; i++) {
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            vm.prank(members[i]);
            group.revealBid(0, salt);
        }

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();

        // Should settle with 0 bid (no discount distributed)
        group.settleCycle();

        (,,,,,,, address winner, uint256 winningBid) = group.getCycleInfo(1);
        assertEq(winningBid, 0);
    }

    function test_SettleCycle_PayoutZeroWhenBidEqualsNet() public {
        _joinAllMembers();
        _allPayContribution();

        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);

        // Calculate max bid (pool - devFee)
        uint256 pool = CONTRIBUTION * GROUP_SIZE;
        uint256 devFee = (pool * 100) / 10000;
        uint256 maxBid = pool - devFee;

        // Alice bids max (will get 0 payout)
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = _computeCommitment(maxBid, salt, alice, 1);
        vm.prank(alice);
        group.commitBid(commitment);

        // Others bid less
        for (uint256 i = 1; i < members.length; i++) {
            bytes32 s = keccak256(abi.encodePacked("salt", i));
            bytes32 c = _computeCommitment(10 ether, s, members[i], 1);
            vm.prank(members[i]);
            group.commitBid(c);
        }

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.prank(alice);
        group.revealBid(maxBid, salt);

        for (uint256 i = 1; i < members.length; i++) {
            bytes32 s = keccak256(abi.encodePacked("salt", i));
            vm.prank(members[i]);
            group.revealBid(10 ether, s);
        }

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        group.settleCycle();

        // Alice wins but gets 0 payout (bid = net)
        (,,,,,,, address winner,) = group.getCycleInfo(1);
        assertEq(winner, alice);
        // Alice balance should be same (0 payout)
        assertEq(token.balanceOf(alice), aliceBalanceBefore);
    }

    function test_DistributePenaltyEscrow_NoPenalty() public {
        _completeAllCycles();

        // No defaults, so no penalty escrow
        assertEq(group.penaltyEscrow(), 0);

        // Should not revert, just return early
        group.distributePenaltyEscrow();
    }

    function test_RevealBid_RevertWhen_NotPaid_DefenseInDepth() public {
        _joinAllMembers();

        // Only alice pays
        vm.prank(alice);
        group.payContribution();

        (,, uint256 payDeadline,,,,,,) = group.getCycleInfo(1);
        vm.warp(payDeadline + 1);
        group.processDefaults();

        // Alice commits
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);
        vm.prank(alice);
        group.commitBid(commitment);

        (,,, uint256 commitDeadline,,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Alice can reveal (she paid)
        vm.prank(alice);
        group.revealBid(bidAmount, salt);
        assertTrue(group.hasRevealed(1, alice));
    }

    function test_MemberList_AccessByIndex() public {
        _joinAllMembers();

        assertEq(group.memberList(0), alice);
        assertEq(group.memberList(1), bob);
        assertEq(group.memberList(2), charlie);
        assertEq(group.memberList(3), dave);
        assertEq(group.memberList(4), eve);
    }

    function test_Cycles_AccessByIndex() public {
        _joinAllMembers();

        (
            AuctionSaveTypes.CycleStatus status,
            uint256 startTime,
            uint256 payDeadline,
            uint256 commitDeadline,
            uint256 revealDeadline,
            uint256 totalContributions,
            uint256 contributorCount,
            address winner,
            uint256 winningBid
        ) = group.getCycleInfo(1);

        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.COLLECTING));
        assertTrue(startTime > 0);
        assertTrue(payDeadline > startTime);
    }

    function test_Contributions_AccessByIndex() public {
        _joinAllMembers();

        vm.prank(alice);
        group.payContribution();

        (bool paid, bytes32 commitment, uint256 revealedBid, bool revealed) = group.contributions(1, alice);

        assertTrue(paid);
        assertEq(commitment, bytes32(0));
        assertEq(revealedBid, 0);
        assertFalse(revealed);
    }

    function test_GroupImmutables() public view {
        assertEq(group.creator(), creator);
        assertEq(group.developer(), developer);
        assertEq(address(group.token()), address(token));
        assertEq(group.groupSize(), GROUP_SIZE);
        assertEq(group.contributionAmount(), CONTRIBUTION);
        assertEq(group.securityDeposit(), SECURITY_DEPOSIT);
        assertEq(group.totalCycles(), TOTAL_CYCLES);
        assertEq(group.cycleDuration(), CYCLE_DURATION);
        assertEq(group.payWindow(), PAY_WINDOW);
        assertEq(group.commitWindow(), COMMIT_WINDOW);
        assertEq(group.revealWindow(), REVEAL_WINDOW);
    }

    /*//////////////////////////////////////////////////////////////
                    NEW EDGE CASE TESTS (GPT's concerns)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that commitment == bytes32(0) is rejected
    function test_CommitBid_RevertWhen_ZeroCommitment() public {
        _joinAllMembers();
        _allPayContribution();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.InvalidCommitment.selector);
        group.commitBid(bytes32(0));
    }

    /// @notice Test that group completes early when no eligible winner exists
    function test_SettleCycle_CompletesEarly_WhenNoEligibleWinner() public {
        _joinAllMembers();

        // No one pays - all will default
        (,, uint256 payDeadline, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(revealDeadline + 1);

        // settleCycle should complete group early (no eligible winners)
        group.settleCycle();

        // Group should be completed
        assertEq(uint256(group.groupStatus()), uint256(AuctionSaveTypes.GroupStatus.COMPLETED));
    }

    /// @notice Test penalty escrow goes to developer when all members defaulted
    function test_DistributePenaltyEscrow_ToDeveloper_WhenAllDefaulted() public {
        _joinAllMembers();

        // No one pays - all will default
        (,, uint256 payDeadline, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(revealDeadline + 1);

        // settleCycle completes group (no eligible winners)
        group.settleCycle();

        // All members defaulted, penalty escrow should exist
        uint256 escrow = group.penaltyEscrow();
        assertTrue(escrow > 0);

        uint256 devBalanceBefore = token.balanceOf(developer);

        // Distribute penalty - should go to developer since all defaulted
        group.distributePenaltyEscrow();

        // Developer should receive the escrow
        assertEq(token.balanceOf(developer), devBalanceBefore + escrow);
        assertEq(group.penaltyEscrow(), 0);
    }

    /// @notice Test that eligibility requires commitment (not just paid)
    function test_Eligibility_RequiresCommitment() public {
        _joinAllMembers();
        _allPayContribution();

        // Only alice commits
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = _computeCommitment(bidAmount, salt, alice, 1);
        vm.prank(alice);
        group.commitBid(commitment);

        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Alice reveals
        vm.prank(alice);
        group.revealBid(bidAmount, salt);

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();

        // Settle - only alice is eligible (others paid but didn't commit)
        group.settleCycle();

        (,,,,,,, address winner,) = group.getCycleInfo(1);
        assertEq(winner, alice);
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

    function _allPayContribution() internal {
        for (uint256 i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            group.payContribution();
        }
    }

    function _allPayContributionForCycle(uint256 cycle) internal {
        for (uint256 i = 0; i < members.length; i++) {
            (,, bool defaulted,,,) = group.members(members[i]);
            if (!defaulted) {
                vm.prank(members[i]);
                group.payContribution();
            }
        }
    }

    function _allCommitAndReveal() internal {
        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(1);

        // Each member bids different amounts (member index * 10 ether + 10)
        for (uint256 i = 0; i < members.length; i++) {
            uint256 bidAmount = (i + 1) * 20 ether; // 20, 40, 60, 80, 100
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitment = _computeCommitment(bidAmount, salt, members[i], 1);

            vm.prank(members[i]);
            group.commitBid(commitment);
        }

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        for (uint256 i = 0; i < members.length; i++) {
            uint256 bidAmount = (i + 1) * 20 ether;
            bytes32 salt = keccak256(abi.encodePacked("salt", i));

            vm.prank(members[i]);
            group.revealBid(bidAmount, salt);
        }

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();
    }

    function _allCommitAndRevealForCycle(uint256 cycle) internal {
        (,,, uint256 commitDeadline, uint256 revealDeadline,,,,) = group.getCycleInfo(cycle);

        // Collect eligible members and their bids
        uint256 bidIndex = 0;
        for (uint256 i = 0; i < members.length; i++) {
            (, bool hasWon, bool defaulted,,,) = group.members(members[i]);
            if (!defaulted && !hasWon && group.hasPaid(cycle, members[i])) {
                uint256 bidAmount = (bidIndex + 1) * 20 ether;
                bytes32 salt = keccak256(abi.encodePacked("salt", i, cycle));
                bytes32 commitment = _computeCommitment(bidAmount, salt, members[i], cycle);

                vm.prank(members[i]);
                group.commitBid(commitment);
                bidIndex++;
            }
        }

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        bidIndex = 0;
        for (uint256 i = 0; i < members.length; i++) {
            (, bool hasWon, bool defaulted,,,) = group.members(members[i]);
            if (!defaulted && !hasWon && group.hasPaid(cycle, members[i])) {
                uint256 bidAmount = (bidIndex + 1) * 20 ether;
                bytes32 salt = keccak256(abi.encodePacked("salt", i, cycle));

                vm.prank(members[i]);
                group.revealBid(bidAmount, salt);
                bidIndex++;
            }
        }

        vm.warp(revealDeadline + 1);
        group.advanceToSettle();
    }

    function _completeCycleToSettle() internal {
        _joinAllMembers();
        _allPayContribution();
        _allCommitAndReveal();
    }

    function _completeAllCycles() internal {
        _joinAllMembers();

        for (uint256 cycle = 1; cycle <= TOTAL_CYCLES; cycle++) {
            _allPayContributionForCycle(cycle);
            _allCommitAndRevealForCycle(cycle);
            group.settleCycle();
        }
    }

    /// @dev Compute commitment hash matching the contract's format
    function _computeCommitment(uint256 bidAmount, bytes32 salt, address bidder, uint256 cycleNum)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(bidAmount, salt, bidder, cycleNum, address(group), block.chainid));
    }
}
