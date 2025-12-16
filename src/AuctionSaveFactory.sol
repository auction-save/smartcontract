// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AuctionSaveGroup.sol";

/// @title AuctionSaveFactory - Factory for deploying AuctionSave pools
/// @notice Creates and indexes AuctionSave pool instances
/// @dev Does NOT hold user funds - only deploys and tracks pools
contract AuctionSaveFactory {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable developer;
    address[] public groups;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event GroupCreated(
        address indexed group,
        address indexed creator,
        address token,
        uint256 groupSize,
        uint256 contributionAmount,
        uint256 totalCycles
    );

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
    /// @param groupSize Number of members in the group
    /// @param contributionAmount Amount each member pays per cycle
    /// @param securityDeposit Security deposit required to join
    /// @param totalCycles Total number of cycles (usually = groupSize)
    /// @param cycleDuration Duration of each cycle in seconds
    /// @param payWindow Time window to pay contribution (seconds)
    /// @param commitWindow Time window to commit seed (seconds)
    /// @param revealWindow Time window to reveal seed (seconds)
    /// @param demoMode Enable demo mode for speedUpCycle function
    /// @return group Address of the newly created group contract
    function createGroup(
        address token,
        uint256 groupSize,
        uint256 contributionAmount,
        uint256 securityDeposit,
        uint256 totalCycles,
        uint256 cycleDuration,
        uint256 payWindow,
        uint256 commitWindow,
        uint256 revealWindow,
        bool demoMode
    ) external returns (address group) {
        require(token != address(0), "Invalid token");
        require(groupSize >= 2, "Group too small");
        require(contributionAmount > 0, "Invalid contribution");
        require(totalCycles > 0, "Invalid cycles");
        require(cycleDuration > 0, "Invalid duration");
        require(payWindow > 0, "Invalid pay window");
        require(commitWindow > 0, "Invalid commit window");
        require(revealWindow > 0, "Invalid reveal window");

        AuctionSaveGroup newGroup = new AuctionSaveGroup(
            msg.sender, // creator
            token,
            developer,
            groupSize,
            contributionAmount,
            securityDeposit,
            totalCycles,
            cycleDuration,
            payWindow,
            commitWindow,
            revealWindow,
            demoMode
        );

        group = address(newGroup);
        groups.push(group);

        emit GroupCreated(group, msg.sender, token, groupSize, contributionAmount, totalCycles);

        return group;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all created groups
    function getAllGroups() external view returns (address[] memory) {
        return groups;
    }

    /// @notice Get total number of groups
    function getGroupCount() external view returns (uint256) {
        return groups.length;
    }
}
