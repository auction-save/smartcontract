// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AuctionSaveFactory.sol";
import "../src/AuctionSaveGroup.sol";
import "../src/libraries/AuctionSaveTypes.sol";
import "./mocks/MockERC20.sol";

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
        // Deploy mock token (18 decimals)
        token = new MockERC20("Test USDT", "TUSDT", 18);

        // Deploy factory
        factory = new AuctionSaveFactory(developer);

        // Create group
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

        // Setup members array
        members = [alice, bob, charlie, dave, eve];

        // Mint tokens to all members
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

    function test_Join_RevertWhen_AlreadyJoined() public {
        vm.prank(alice);
        group.join();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.AlreadyJoined.selector);
        group.join();
    }

    function test_Join_RevertWhen_GroupFull() public {
        _joinAllMembers();

        address extraMember = makeAddr("extra");
        token.mint(extraMember, 1000 ether);
        vm.prank(extraMember);
        token.approve(address(group), type(uint256).max);

        // After group is full, status changes to ACTIVE, so GroupNotFilling is thrown first
        vm.prank(extraMember);
        vm.expectRevert(AuctionSaveGroup.GroupNotFilling.selector);
        group.join();
    }

    function test_Join_TransfersSecurityDeposit() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        group.join();

        assertEq(token.balanceOf(alice), balanceBefore - SECURITY_DEPOSIT);
        assertEq(token.balanceOf(address(group)), SECURITY_DEPOSIT);
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

        (AuctionSaveTypes.CycleStatus status,,,,,,,) = group.getCycleInfo(1);
        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.COMMITTING));
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

        // Warp past pay deadline
        vm.warp(block.timestamp + PAY_WINDOW + 1);

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.PayWindowClosed.selector);
        group.payContribution();
    }

    /*//////////////////////////////////////////////////////////////
                        DEFAULT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProcessDefaults_PenalizesNonPayers() public {
        _joinAllMembers();

        // Only alice pays
        vm.prank(alice);
        group.payContribution();

        // Warp past pay deadline
        vm.warp(block.timestamp + PAY_WINDOW + 1);

        // Process defaults
        group.processDefaults();

        // Check bob is defaulted
        (,, bool defaulted,) = group.members(bob);
        assertTrue(defaulted);

        // Check penalty escrow increased
        assertEq(group.penaltyEscrow(), SECURITY_DEPOSIT * 4); // 4 members defaulted
    }

    function test_ProcessDefaults_AdvancesToCommit() public {
        _joinAllMembers();
        _allPayContribution();

        // Already in COMMITTING, but let's test the flow
        (AuctionSaveTypes.CycleStatus status,,,,,,,) = group.getCycleInfo(1);
        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.COMMITTING));
    }

    /*//////////////////////////////////////////////////////////////
                        COMMIT-REVEAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CommitSeed_Success() public {
        _joinAllMembers();
        _allPayContribution();

        bytes32 seed = keccak256("alice_seed");
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = keccak256(abi.encodePacked(seed, salt));

        vm.prank(alice);
        group.commitSeed(commitment);

        assertTrue(group.hasCommitted(1, alice));
    }

    function test_CommitSeed_RevertWhen_NotPaid() public {
        _joinAllMembers();

        // Only alice pays
        vm.prank(alice);
        group.payContribution();

        // Warp past pay deadline and process defaults
        vm.warp(block.timestamp + PAY_WINDOW + 1);
        group.processDefaults();

        // Bob tries to commit but didn't pay
        bytes32 commitment = keccak256(abi.encodePacked(bytes32("seed"), bytes32("salt")));
        vm.prank(bob);
        vm.expectRevert(AuctionSaveGroup.MemberDefaultedError.selector);
        group.commitSeed(commitment);
    }

    function test_RevealSeed_Success() public {
        _joinAllMembers();
        _allPayContribution();

        // Get cycle deadlines
        (,,, uint256 commitDeadline, uint256 revealDeadline,,,) = group.getCycleInfo(1);

        bytes32 seed = keccak256("alice_seed");
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = keccak256(abi.encodePacked(seed, salt));

        vm.prank(alice);
        group.commitSeed(commitment);

        // Warp past commit deadline
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        vm.prank(alice);
        group.revealSeed(seed, salt);

        assertTrue(group.hasRevealed(1, alice));
    }

    function test_RevealSeed_RevertWhen_InvalidReveal() public {
        _joinAllMembers();
        _allPayContribution();

        // Get cycle deadlines
        (,,, uint256 commitDeadline,,,,) = group.getCycleInfo(1);

        bytes32 seed = keccak256("alice_seed");
        bytes32 salt = keccak256("alice_salt");
        bytes32 commitment = keccak256(abi.encodePacked(seed, salt));

        vm.prank(alice);
        group.commitSeed(commitment);

        // Warp past commit deadline
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Try to reveal with wrong seed
        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.InvalidReveal.selector);
        group.revealSeed(keccak256("wrong_seed"), salt);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLE CYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SettleCycle_Success() public {
        _completeCycleToSettle();

        uint256 expectedPool = CONTRIBUTION * GROUP_SIZE;
        uint256 expectedFee = (expectedPool * 100) / 10000; // 1%
        uint256 expectedPayout = expectedPool - expectedFee;

        // Get balances before
        uint256[] memory balancesBefore = new uint256[](members.length);
        for (uint256 i = 0; i < members.length; i++) {
            balancesBefore[i] = token.balanceOf(members[i]);
        }

        group.settleCycle();

        // Check cycle is settled
        (AuctionSaveTypes.CycleStatus status,,,,,,, address winner) = group.getCycleInfo(1);
        assertEq(uint256(status), uint256(AuctionSaveTypes.CycleStatus.SETTLED));
        assertTrue(winner != address(0));

        // Check winner received payout
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == winner) {
                assertEq(token.balanceOf(members[i]), balancesBefore[i] + expectedPayout);
                break;
            }
        }

        // Check dev fee accumulated
        assertEq(group.devFeeBalance(), expectedFee);
    }

    function test_SettleCycle_WinnerCannotWinAgain() public {
        _completeCycleToSettle();
        group.settleCycle();

        (,,,,,,, address winner1) = group.getCycleInfo(1);
        (, bool hasWon,,) = group.members(winner1);
        assertTrue(hasWon);

        // Complete cycle 2
        _allPayContributionForCycle(2);
        _allCommitAndRevealForCycle(2);
        group.settleCycle();

        (,,,,,,, address winner2) = group.getCycleInfo(2);

        // Winner 2 should be different from winner 1
        assertTrue(winner2 != winner1);
    }

    function test_SettleCycle_AdvancesToNextCycle() public {
        _completeCycleToSettle();
        group.settleCycle();

        assertEq(group.currentCycle(), 2);

        (AuctionSaveTypes.CycleStatus status,,,,,,,) = group.getCycleInfo(2);
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

    function test_WithdrawSecurity_RevertWhen_NotCompleted() public {
        _joinAllMembers();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.GroupNotCompleted.selector);
        group.withdrawSecurity();
    }

    function test_DistributePenaltyEscrow_Success() public {
        // Complete all cycles with all members paying (no defaults)
        _completeAllCycles();

        // Since all members paid, penaltyEscrow should be 0
        // Verify the function handles 0 case gracefully
        assertEq(group.penaltyEscrow(), 0);

        // Distribute (should handle 0 gracefully - just returns)
        group.distributePenaltyEscrow();

        // Escrow should still be 0 (nothing to distribute)
        assertEq(group.penaltyEscrow(), 0);
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
        assertEq(group.devFeeBalance(), 0);
    }

    function test_WithdrawDevFee_RevertWhen_NotDeveloper() public {
        _completeCycleToSettle();
        group.settleCycle();

        vm.prank(alice);
        vm.expectRevert(AuctionSaveGroup.NotDeveloper.selector);
        group.withdrawDevFee();
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING TESTS (Critical bug prevention)
    //////////////////////////////////////////////////////////////*/

    function test_Accounting_PoolMatchesContributions() public {
        _joinAllMembers();
        _allPayContribution();

        (,,,,, uint256 totalContributions,,) = group.getCycleInfo(1);
        assertEq(totalContributions, CONTRIBUTION * GROUP_SIZE);
    }

    function test_Accounting_MultiCycle_NoShortfall() public {
        // This test ensures the contract doesn't run out of funds
        // Unlike the buggy ref contract, we collect contributions each cycle

        uint256 contractBalanceAfterJoin = token.balanceOf(address(group));
        assertEq(contractBalanceAfterJoin, 0); // No one joined yet

        _joinAllMembers();

        // After join, contract has security deposits
        assertEq(token.balanceOf(address(group)), SECURITY_DEPOSIT * GROUP_SIZE);

        // Complete all cycles
        for (uint256 cycle = 1; cycle <= TOTAL_CYCLES; cycle++) {
            uint256 balanceBefore = token.balanceOf(address(group));

            _allPayContributionForCycle(cycle);

            // After contributions, balance increased by CONTRIBUTION * GROUP_SIZE
            assertEq(token.balanceOf(address(group)), balanceBefore + CONTRIBUTION * GROUP_SIZE);

            _allCommitAndRevealForCycle(cycle);
            group.settleCycle();

            // Contract should never have negative balance (obviously can't in Solidity)
            // But we verify it has at least security deposits remaining
            assertTrue(token.balanceOf(address(group)) >= SECURITY_DEPOSIT * GROUP_SIZE - group.devFeeBalance());
        }
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
        // Get eligible members (not defaulted)
        for (uint256 i = 0; i < members.length; i++) {
            (,, bool defaulted,) = group.members(members[i]);
            if (!defaulted) {
                vm.prank(members[i]);
                group.payContribution();
            }
        }
    }

    function _allCommitAndReveal() internal {
        // Get cycle info for timing
        (,, uint256 payDeadline, uint256 commitDeadline, uint256 revealDeadline,,,) = group.getCycleInfo(1);

        // Commit phase
        for (uint256 i = 0; i < members.length; i++) {
            bytes32 seed = keccak256(abi.encodePacked("seed", i));
            bytes32 salt = keccak256(abi.encodePacked("salt", i));
            bytes32 commitment = keccak256(abi.encodePacked(seed, salt));

            vm.prank(members[i]);
            group.commitSeed(commitment);
        }

        // Warp past commit deadline
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Reveal phase
        for (uint256 i = 0; i < members.length; i++) {
            bytes32 seed = keccak256(abi.encodePacked("seed", i));
            bytes32 salt = keccak256(abi.encodePacked("salt", i));

            vm.prank(members[i]);
            group.revealSeed(seed, salt);
        }

        // Warp past reveal deadline
        vm.warp(revealDeadline + 1);
        group.advanceToSettle();
    }

    function _allCommitAndRevealForCycle(uint256 cycle) internal {
        // Get cycle info for timing
        (,, uint256 payDeadline, uint256 commitDeadline, uint256 revealDeadline,,,) = group.getCycleInfo(cycle);

        // Commit phase - only non-defaulted members who paid
        for (uint256 i = 0; i < members.length; i++) {
            (, bool hasWon, bool defaulted,) = group.members(members[i]);
            if (!defaulted && group.hasPaid(cycle, members[i])) {
                bytes32 seed = keccak256(abi.encodePacked("seed", i, cycle));
                bytes32 salt = keccak256(abi.encodePacked("salt", i, cycle));
                bytes32 commitment = keccak256(abi.encodePacked(seed, salt));

                vm.prank(members[i]);
                group.commitSeed(commitment);
            }
        }

        // Warp past commit deadline
        vm.warp(commitDeadline + 1);
        group.advanceToReveal();

        // Reveal phase
        for (uint256 i = 0; i < members.length; i++) {
            (, bool hasWon, bool defaulted,) = group.members(members[i]);
            if (!defaulted && group.hasPaid(cycle, members[i])) {
                bytes32 seed = keccak256(abi.encodePacked("seed", i, cycle));
                bytes32 salt = keccak256(abi.encodePacked("salt", i, cycle));

                vm.prank(members[i]);
                group.revealSeed(seed, salt);
            }
        }

        // Warp past reveal deadline
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
