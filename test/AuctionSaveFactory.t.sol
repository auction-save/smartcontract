// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AuctionSaveFactory.sol";
import "../src/AuctionSaveGroup.sol";
import "./mocks/MockERC20.sol";

/// @title AuctionSaveFactoryTest - Tests for Factory contract (per boss's design)
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
                        CREATE GROUP TESTS (per boss's design)
    //////////////////////////////////////////////////////////////*/

    function test_CreateGroup_Success() public {
        vm.prank(creator);
        address groupAddr = factory.createGroup(
            address(token),
            block.timestamp,
            1 weeks,
            false
        );

        assertTrue(groupAddr != address(0));
        assertEq(factory.getGroupCount(), 1);
        assertEq(factory.groups(0), groupAddr);
    }

    function test_CreateGroup_EmitsEvent() public {
        vm.expectEmit(false, true, false, false);
        emit AuctionSaveFactory.GroupCreated(address(0), creator);

        vm.prank(creator);
        factory.createGroup(address(token), block.timestamp, 1 weeks, false);
    }

    function test_CreateGroup_MultipleGroups() public {
        vm.startPrank(creator);

        address group1 = factory.createGroup(address(token), block.timestamp, 1 weeks, false);
        address group2 = factory.createGroup(address(token), block.timestamp, 2 weeks, true);

        vm.stopPrank();

        assertEq(factory.getGroupCount(), 2);
        assertEq(factory.groups(0), group1);
        assertEq(factory.groups(1), group2);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AllGroups_Empty() public view {
        address[] memory groups = factory.allGroups();
        assertEq(groups.length, 0);
    }

    function test_AllGroups_WithGroups() public {
        vm.startPrank(creator);
        factory.createGroup(address(token), block.timestamp, 1 weeks, false);
        factory.createGroup(address(token), block.timestamp, 2 weeks, true);
        vm.stopPrank();

        address[] memory groups = factory.allGroups();
        assertEq(groups.length, 2);
    }

    function test_GetGroupCount_Empty() public view {
        assertEq(factory.getGroupCount(), 0);
    }

    function test_GetGroupCount_WithGroups() public {
        vm.prank(creator);
        factory.createGroup(address(token), block.timestamp, 1 weeks, false);

        assertEq(factory.getGroupCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreatedGroup_HasCorrectParameters() public {
        vm.prank(creator);
        address groupAddr = factory.createGroup(address(token), block.timestamp + 1 hours, 1 weeks, true);

        AuctionSaveGroup group = AuctionSaveGroup(groupAddr);

        assertEq(group.creator(), creator);
        assertEq(group.developer(), developer);
        assertEq(address(group.token()), address(token));
        assertEq(group.startTime(), block.timestamp + 1 hours);
        assertEq(group.cycleDuration(), 1 weeks);
        assertTrue(group.demoMode());
    }
}
