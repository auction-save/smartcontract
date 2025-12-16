// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AuctionSaveFactory.sol";
import "../src/AuctionSaveGroup.sol";
import "../src/libraries/AuctionSaveTypes.sol";
import "./mocks/MockERC20.sol";

/// @title AuctionSaveGroupTest - Tests for AuctionSaveGroup (per boss's design)
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
                            JOIN TESTS (per boss's design)
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

        // Per boss's design: COMMITMENT + SECURITY_DEPOSIT = 100 ether
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
                        PENALTY TESTS (per boss's design)
    //////////////////////////////////////////////////////////////*/

    function test_Penalize_Success() public {
        _joinAllMembers();

        group.penalize(alice);

        (, , bool defaulted,,,) = group.members(alice);
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
                        SPEED UP TESTS (per boss's design)
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
        (, , , , , uint256 withheld) = group.members(alice);
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
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _joinAllMembers() internal {
        for (uint256 i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            group.join();
        }
    }

    function _computeCommitment(uint256 bps, bytes32 salt, address bidder, uint256 cycle) internal view returns (bytes32) {
        return keccak256(abi.encode(bps, salt, bidder, cycle, address(group), block.chainid));
    }

    function _commitAndRevealBid(address bidder, uint256 bps, bytes32 salt) internal {
        bytes32 commitment = _computeCommitment(bps, salt, bidder, group.currentCycle());
        
        vm.prank(bidder);
        group.commitBid(commitment);

        vm.prank(bidder);
        group.revealBid(bps, salt);
    }
}
