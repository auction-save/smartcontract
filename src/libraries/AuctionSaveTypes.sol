// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AuctionSaveTypes - Data structures for AuctionSave protocol
/// @notice Contains all structs, enums, and constants used across the protocol
library AuctionSaveTypes {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant GROUP_SIZE = 5;
    uint256 constant COMMITMENT = 50 ether; // Contribution amount per cycle
    uint256 constant SECURITY_DEPOSIT = 50 ether;
    uint256 constant MAX_BID_BPS = 3000; // 30% max bid
    uint256 constant DEV_FEE_BPS = 100; // 1% developer fee
    uint256 constant BPS = 10_000; // Basis points denominator

    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Status of the entire group
    enum GroupStatus {
        FILLING, // Waiting for members to join
        ACTIVE, // Group is running cycles
        COMPLETED // All cycles finished
    }

    /// @notice Status of each cycle
    enum CycleStatus {
        NOT_STARTED, // Cycle hasn't begun
        COLLECTING, // Collecting contributions
        COMMITTING, // Members committing sealed bids
        REVEALING, // Members revealing bids
        READY_TO_SETTLE, // Ready to pick winner and distribute
        SETTLED // Cycle complete, winner paid
    }

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Member information
    struct Member {
        bool joined;
        bool hasWon; // Has won in any cycle (can't win again)
        bool defaulted; // Has defaulted (kicked from future cycles)
        bool hasOffset; // Has commitment offset (one-cycle relief after winning)
        uint256 securityDeposit; // Amount locked as security
        uint256 withheld; // 20% winning portion withheld until completion
    }

    /// @notice Per-cycle state
    struct Cycle {
        CycleStatus status;
        uint256 startTime;
        uint256 payDeadline;
        uint256 commitDeadline;
        uint256 revealDeadline;
        uint256 totalContributions;
        uint256 contributorCount;
        address winner;
        uint256 winningBid; // The highest bid amount
        uint256 revealCount;
    }

    /// @notice Contribution and bid tracking per cycle per member
    struct Contribution {
        bool paid;
        bytes32 commitment; // keccak256(bidAmount, salt)
        uint256 revealedBid; // The revealed bid amount
        bool revealed;
    }

    /// @notice Group configuration (immutable after creation)
    struct GroupConfig {
        uint256 groupSize;
        uint256 contributionAmount;
        uint256 securityDeposit;
        uint256 totalCycles;
        uint256 cycleDuration;
        uint256 payWindow; // Time to pay contribution
        uint256 commitWindow; // Time to commit seed
        uint256 revealWindow; // Time to reveal seed
    }
}
