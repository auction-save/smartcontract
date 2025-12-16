// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AuctionSaveGroup.sol";

/// @title AuctionSaveFactory - Factory for deploying AuctionSave pools
/// @notice Factory contract for creating and managing AuctionSave group instances
contract AuctionSaveFactory {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable developer;
    address[] public groups;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event GroupCreated(address indexed group, address indexed creator);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _developer) {
        developer = _developer;
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE GROUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new AuctionSave pool
    /// @param token ERC20 token address for contributions
    /// @param startTime When the first cycle starts
    /// @param cycleDuration Duration of each cycle in seconds
    /// @param demoMode Enable demo mode for speedUpCycle function
    /// @return group Address of the newly created group contract
    function createGroup(address token, uint256 startTime, uint256 cycleDuration, bool demoMode)
        external
        returns (address)
    {
        AuctionSaveGroup group = new AuctionSaveGroup(msg.sender, token, developer, startTime, cycleDuration, demoMode);

        groups.push(address(group));
        emit GroupCreated(address(group), msg.sender);
        return address(group);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all created groups
    function allGroups() external view returns (address[] memory) {
        return groups;
    }

    /// @notice Get total number of groups
    function getGroupCount() external view returns (uint256) {
        return groups.length;
    }
}
