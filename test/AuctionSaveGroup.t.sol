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
            REVEAL_WINDOW
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

        (bool joined,,,) = group.members(alice);
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
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, salt));

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
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, salt));

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
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, salt));

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
            bytes32 commitment = keccak256(abi.encodePacked(bidAmounts[i], salt));

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

        // Charlie should receive pool minus dev fee
        uint256 expectedPool = CONTRIBUTION * GROUP_SIZE;
        uint256 expectedFee = (expectedPool * 100) / 10000;
        uint256 expectedPayout = expectedPool - expectedFee;
        assertEq(token.balanceOf(charlie), charlieBalanceBefore + expectedPayout);
    }

    function test_SettleCycle_WinnerCannotBidAgain() public {
        _completeCycleToSettle();
        group.settleCycle();

        (,,,,,,, address winner1,) = group.getCycleInfo(1);
        (, bool hasWon,,) = group.members(winner1);
        assertTrue(hasWon);

        // Cycle 2: Winner from cycle 1 cannot commit bid
        _allPayContributionForCycle(2);

        (,,, uint256 commitDeadline2,,,,,) = group.getCycleInfo(2);

        // Winner tries to commit - should revert
        uint256 bidAmount = 50 ether;
        bytes32 salt = keccak256("salt");
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, salt));

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
            (,, bool defaulted,) = group.members(members[i]);
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
            bytes32 commitment = keccak256(abi.encodePacked(bidAmount, salt));

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
            (, bool hasWon, bool defaulted,) = group.members(members[i]);
            if (!defaulted && !hasWon && group.hasPaid(cycle, members[i])) {
                uint256 bidAmount = (bidIndex + 1) * 20 ether;
                bytes32 salt = keccak256(abi.encodePacked("salt", i, cycle));
                bytes32 commitment = keccak256(abi.encodePacked(bidAmount, salt));

                vm.prank(members[i]);
                group.commitBid(commitment);
                bidIndex++;
            }
        }

        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        bidIndex = 0;
        for (uint256 i = 0; i < members.length; i++) {
            (, bool hasWon, bool defaulted,) = group.members(members[i]);
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
}
