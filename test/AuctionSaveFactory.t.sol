// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AuctionSaveFactory.sol";
import "../src/AuctionSaveGroup.sol";
import "./mocks/MockERC20.sol";

/// @title AuctionSaveFactoryTest - Comprehensive tests for Factory contract
contract AuctionSaveFactoryTest is Test {
    AuctionSaveFactory public factory;
    MockERC20 public token;

    address public developer = makeAddr("developer");
    address public creator = makeAddr("creator");

    function setUp() public {
        token = new MockERC20("Test USDT", "TUSDT", 18);
        factory = new AuctionSaveFactory(developer);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsDeveloper() public view {
        assertEq(factory.developer(), developer);
    }

    /*//////////////////////////////////////////////////////////////
                        CREATE GROUP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateGroup_Success() public {
        vm.prank(creator);
        address groupAddr = factory.createGroup(
            address(token),
            5, // groupSize
            100 ether, // contribution
            50 ether, // security deposit
            5, // totalCycles
            1 weeks, // cycleDuration
            2 days, // payWindow
            1 days, // commitWindow
            1 days // revealWindow
        );

        assertTrue(groupAddr != address(0));
        assertEq(factory.getGroupCount(), 1);
        assertEq(factory.groups(0), groupAddr);
    }

    function test_CreateGroup_EmitsEvent() public {
        // Check that event is emitted with correct indexed params (creator, token)
        vm.expectEmit(false, true, false, false);
        emit AuctionSaveFactory.GroupCreated(
            address(0), // group address - we don't check this
            creator,
            address(token),
            5,
            100 ether,
            5
        );

        vm.prank(creator);
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 1 days, 1 days);
    }

    function test_CreateGroup_RevertWhen_InvalidToken() public {
        vm.prank(creator);
        vm.expectRevert("Invalid token");
        factory.createGroup(address(0), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 1 days, 1 days);
    }

    function test_CreateGroup_RevertWhen_GroupTooSmall() public {
        vm.prank(creator);
        vm.expectRevert("Group too small");
        factory.createGroup(address(token), 1, 100 ether, 50 ether, 1, 1 weeks, 2 days, 1 days, 1 days);
    }

    function test_CreateGroup_RevertWhen_InvalidContribution() public {
        vm.prank(creator);
        vm.expectRevert("Invalid contribution");
        factory.createGroup(address(token), 5, 0, 50 ether, 5, 1 weeks, 2 days, 1 days, 1 days);
    }

    function test_CreateGroup_RevertWhen_InvalidCycles() public {
        vm.prank(creator);
        vm.expectRevert("Invalid cycles");
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 0, 1 weeks, 2 days, 1 days, 1 days);
    }

    function test_CreateGroup_RevertWhen_InvalidDuration() public {
        vm.prank(creator);
        vm.expectRevert("Invalid duration");
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 0, 2 days, 1 days, 1 days);
    }

    function test_CreateGroup_RevertWhen_InvalidPayWindow() public {
        vm.prank(creator);
        vm.expectRevert("Invalid pay window");
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 0, 1 days, 1 days);
    }

    function test_CreateGroup_RevertWhen_InvalidCommitWindow() public {
        vm.prank(creator);
        vm.expectRevert("Invalid commit window");
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 0, 1 days);
    }

    function test_CreateGroup_RevertWhen_InvalidRevealWindow() public {
        vm.prank(creator);
        vm.expectRevert("Invalid reveal window");
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 1 days, 0);
    }

    function test_CreateGroup_MultipleGroups() public {
        vm.startPrank(creator);

        address group1 = factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 1 days, 1 days);
        address group2 = factory.createGroup(address(token), 3, 50 ether, 25 ether, 3, 2 weeks, 3 days, 2 days, 2 days);
        address group3 =
            factory.createGroup(address(token), 10, 200 ether, 100 ether, 10, 4 weeks, 1 weeks, 3 days, 3 days);

        vm.stopPrank();

        assertEq(factory.getGroupCount(), 3);
        assertEq(factory.groups(0), group1);
        assertEq(factory.groups(1), group2);
        assertEq(factory.groups(2), group3);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetAllGroups_Empty() public view {
        address[] memory allGroups = factory.getAllGroups();
        assertEq(allGroups.length, 0);
    }

    function test_GetAllGroups_WithGroups() public {
        vm.startPrank(creator);
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 1 days, 1 days);
        factory.createGroup(address(token), 3, 50 ether, 25 ether, 3, 2 weeks, 3 days, 2 days, 2 days);
        vm.stopPrank();

        address[] memory allGroups = factory.getAllGroups();
        assertEq(allGroups.length, 2);
    }

    function test_GetGroupCount_Empty() public view {
        assertEq(factory.getGroupCount(), 0);
    }

    function test_GetGroupCount_WithGroups() public {
        vm.prank(creator);
        factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 1 days, 1 days);

        assertEq(factory.getGroupCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreatedGroup_HasCorrectParameters() public {
        vm.prank(creator);
        address groupAddr =
            factory.createGroup(address(token), 5, 100 ether, 50 ether, 5, 1 weeks, 2 days, 1 days, 1 days);

        AuctionSaveGroup group = AuctionSaveGroup(groupAddr);

        assertEq(group.creator(), creator);
        assertEq(group.developer(), developer);
        assertEq(address(group.token()), address(token));
        assertEq(group.groupSize(), 5);
        assertEq(group.contributionAmount(), 100 ether);
        assertEq(group.securityDeposit(), 50 ether);
        assertEq(group.totalCycles(), 5);
        assertEq(group.cycleDuration(), 1 weeks);
        assertEq(group.payWindow(), 2 days);
        assertEq(group.commitWindow(), 1 days);
        assertEq(group.revealWindow(), 1 days);
    }
}
