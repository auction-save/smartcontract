// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/AuctionSaveTypes.sol";

/// @title AuctionSaveGroup - Core protocol for decentralized rotating savings auction
/// @notice One pool = one isolated state machine with pay-per-cycle + commit-reveal auction
/// @dev Implements secure fund handling, commit-reveal mechanism, and penalty system
contract AuctionSaveGroup is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AuctionSaveTypes for *;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable creator;
    address public immutable developer;
    IERC20 public immutable token;

    uint256 public immutable groupSize;
    uint256 public immutable contributionAmount;
    uint256 public immutable securityDeposit;
    uint256 public immutable totalCycles;
    uint256 public immutable cycleDuration;
    uint256 public immutable payWindow;
    uint256 public immutable commitWindow;
    uint256 public immutable revealWindow;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    AuctionSaveTypes.GroupStatus public groupStatus;
    uint256 public currentCycle;
    uint256 public devFeeBalance;
    uint256 public penaltyEscrow;

    address[] public memberList;
    mapping(address => AuctionSaveTypes.Member) public members;

    mapping(uint256 => AuctionSaveTypes.Cycle) public cycles;
    mapping(uint256 => mapping(address => AuctionSaveTypes.Contribution)) public contributions;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MemberJoined(address indexed member, uint256 memberCount);
    event GroupActivated(uint256 startTime);
    event ContributionPaid(uint256 indexed cycle, address indexed member, uint256 amount);
    event BidCommitted(uint256 indexed cycle, address indexed member);
    event BidRevealed(uint256 indexed cycle, address indexed member, uint256 bidAmount);
    event MemberDefaulted(uint256 indexed cycle, address indexed member, uint256 penaltyAmount);
    event AuctionSettled(uint256 indexed cycle, address indexed winner, uint256 winningBid, uint256 payout);
    event GroupCompleted();
    event SecurityRefunded(address indexed member, uint256 amount);
    event PenaltyDistributed(address indexed member, uint256 amount);
    event DevFeeWithdrawn(address indexed developer, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error GroupFull();
    error AlreadyJoined();
    error GroupNotFilling();
    error GroupNotActive();
    error NotMember();
    error MemberDefaultedError();
    error AlreadyWon();
    error InvalidCycle();
    error WrongCycleStatus();
    error AlreadyPaid();
    error PayWindowClosed();
    error NotPaid();
    error AlreadyCommitted();
    error CommitWindowClosed();
    error CommitDeadlineNotPassed();
    error AlreadyRevealed();
    error RevealWindowClosed();
    error RevealDeadlineNotPassed();
    error InvalidReveal();
    error NotReadyToSettle();
    error CycleNotSettled();
    error GroupNotCompleted();
    error NotDeveloper();
    error NoFeesToWithdraw();
    error NothingToRefund();
    error BidTooHigh();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyMember() {
        if (!members[msg.sender].joined) revert NotMember();
        _;
    }

    modifier onlyActiveMember() {
        if (!members[msg.sender].joined) revert NotMember();
        if (members[msg.sender].defaulted) revert MemberDefaultedError();
        _;
    }

    modifier onlyActiveGroup() {
        if (groupStatus != AuctionSaveTypes.GroupStatus.ACTIVE) revert GroupNotActive();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _creator,
        address _token,
        address _developer,
        uint256 _groupSize,
        uint256 _contributionAmount,
        uint256 _securityDeposit,
        uint256 _totalCycles,
        uint256 _cycleDuration,
        uint256 _payWindow,
        uint256 _commitWindow,
        uint256 _revealWindow
    ) {
        creator = _creator;
        token = IERC20(_token);
        developer = _developer;
        groupSize = _groupSize;
        contributionAmount = _contributionAmount;
        securityDeposit = _securityDeposit;
        totalCycles = _totalCycles;
        cycleDuration = _cycleDuration;
        payWindow = _payWindow;
        commitWindow = _commitWindow;
        revealWindow = _revealWindow;

        groupStatus = AuctionSaveTypes.GroupStatus.FILLING;
    }

    /*//////////////////////////////////////////////////////////////
                                JOIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Join the group by depositing security deposit
    function join() external nonReentrant {
        if (groupStatus != AuctionSaveTypes.GroupStatus.FILLING) revert GroupNotFilling();
        if (memberList.length >= groupSize) revert GroupFull();
        if (members[msg.sender].joined) revert AlreadyJoined();

        token.safeTransferFrom(msg.sender, address(this), securityDeposit);

        members[msg.sender] =
            AuctionSaveTypes.Member({joined: true, hasWon: false, defaulted: false, securityDeposit: securityDeposit});
        memberList.push(msg.sender);

        emit MemberJoined(msg.sender, memberList.length);

        if (memberList.length == groupSize) {
            _activateGroup();
        }
    }

    /// @dev Activate group and start cycle 1
    function _activateGroup() internal {
        groupStatus = AuctionSaveTypes.GroupStatus.ACTIVE;
        currentCycle = 1;
        _initCycle(1, block.timestamp);
        emit GroupActivated(block.timestamp);
    }

    /// @dev Initialize a new cycle
    function _initCycle(uint256 cycleNum, uint256 startTime) internal {
        cycles[cycleNum] = AuctionSaveTypes.Cycle({
            status: AuctionSaveTypes.CycleStatus.COLLECTING,
            startTime: startTime,
            payDeadline: startTime + payWindow,
            commitDeadline: startTime + payWindow + commitWindow,
            revealDeadline: startTime + payWindow + commitWindow + revealWindow,
            totalContributions: 0,
            contributorCount: 0,
            winner: address(0),
            winningBid: 0,
            revealCount: 0
        });
    }

    /*//////////////////////////////////////////////////////////////
                            PAY CONTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay contribution for current cycle
    function payContribution() external onlyActiveMember onlyActiveGroup nonReentrant {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];

        if (cycle.status != AuctionSaveTypes.CycleStatus.COLLECTING) revert WrongCycleStatus();
        if (block.timestamp > cycle.payDeadline) revert PayWindowClosed();
        if (contributions[currentCycle][msg.sender].paid) revert AlreadyPaid();

        token.safeTransferFrom(msg.sender, address(this), contributionAmount);

        contributions[currentCycle][msg.sender].paid = true;
        cycle.totalContributions += contributionAmount;
        cycle.contributorCount++;

        emit ContributionPaid(currentCycle, msg.sender, contributionAmount);

        // Auto-advance to commit phase if all eligible members paid
        if (cycle.contributorCount == _getEligibleCount()) {
            cycle.status = AuctionSaveTypes.CycleStatus.COMMITTING;
        }
    }

    /// @notice Process defaults after pay deadline (anyone can call)
    function processDefaults() external onlyActiveGroup {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];

        if (cycle.status != AuctionSaveTypes.CycleStatus.COLLECTING) revert WrongCycleStatus();
        if (block.timestamp <= cycle.payDeadline) revert PayWindowClosed();

        for (uint256 i = 0; i < memberList.length; i++) {
            address member = memberList[i];
            AuctionSaveTypes.Member storage m = members[member];

            if (m.joined && !m.defaulted && !contributions[currentCycle][member].paid) {
                _penalizeMember(member);
            }
        }

        cycle.status = AuctionSaveTypes.CycleStatus.COMMITTING;
    }

    /// @dev Penalize a member for defaulting
    function _penalizeMember(address member) internal {
        AuctionSaveTypes.Member storage m = members[member];
        uint256 penalty = m.securityDeposit;

        m.defaulted = true;
        m.securityDeposit = 0;
        penaltyEscrow += penalty;

        emit MemberDefaulted(currentCycle, member, penalty);
    }

    /*//////////////////////////////////////////////////////////////
                            COMMIT-REVEAL AUCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Commit a sealed bid for the auction
    /// @dev Demo: "Participant 1 commits a bid of 50 USDT" - bids are sealed
    /// @param commitment keccak256(abi.encodePacked(bidAmount, salt))
    /// @dev bidAmount is how much the participant is willing to "give up" from the pool
    ///      Higher bid = more willing to sacrifice = wins the auction
    function commitBid(bytes32 commitment) external onlyActiveMember onlyActiveGroup {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];
        AuctionSaveTypes.Contribution storage contrib = contributions[currentCycle][msg.sender];

        if (cycle.status != AuctionSaveTypes.CycleStatus.COMMITTING) revert WrongCycleStatus();
        if (block.timestamp > cycle.commitDeadline) revert CommitWindowClosed();
        if (!contrib.paid) revert NotPaid();
        if (contrib.commitment != bytes32(0)) revert AlreadyCommitted();
        if (members[msg.sender].hasWon) revert AlreadyWon();

        contrib.commitment = commitment;
        emit BidCommitted(currentCycle, msg.sender);
    }

    /// @notice Advance to reveal phase after commit deadline (anyone can call)
    function advanceToReveal() external onlyActiveGroup {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];

        if (cycle.status != AuctionSaveTypes.CycleStatus.COMMITTING) revert WrongCycleStatus();
        if (block.timestamp <= cycle.commitDeadline) revert CommitDeadlineNotPassed();

        cycle.status = AuctionSaveTypes.CycleStatus.REVEALING;
    }

    /// @notice Reveal the bid that was committed
    /// @dev Demo: "Bids are verified against commitments"
    /// @param bidAmount The bid amount (in token units, e.g., 50 USDT = 50e18)
    /// @param salt The salt used in commitment
    function revealBid(uint256 bidAmount, bytes32 salt) external onlyActiveMember onlyActiveGroup {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];
        AuctionSaveTypes.Contribution storage contrib = contributions[currentCycle][msg.sender];

        if (cycle.status != AuctionSaveTypes.CycleStatus.REVEALING) revert WrongCycleStatus();
        if (block.timestamp > cycle.revealDeadline) revert RevealWindowClosed();
        if (contrib.revealed) revert AlreadyRevealed();

        // Verify commitment
        bytes32 expectedCommitment = keccak256(abi.encodePacked(bidAmount, salt));
        if (contrib.commitment != expectedCommitment) revert InvalidReveal();

        // Bid cannot exceed pool size (sanity check)
        uint256 maxBid = contributionAmount * groupSize;
        if (bidAmount > maxBid) revert BidTooHigh();

        contrib.revealedBid = bidAmount;
        contrib.revealed = true;
        cycle.revealCount++;

        emit BidRevealed(currentCycle, msg.sender, bidAmount);
    }

    /// @notice Advance to ready-to-settle after reveal deadline (anyone can call)
    function advanceToSettle() external onlyActiveGroup {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];

        if (cycle.status != AuctionSaveTypes.CycleStatus.REVEALING) revert WrongCycleStatus();
        if (block.timestamp <= cycle.revealDeadline) revert RevealDeadlineNotPassed();

        cycle.status = AuctionSaveTypes.CycleStatus.READY_TO_SETTLE;
    }

    /*//////////////////////////////////////////////////////////////
                            SETTLE AUCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle the auction - HIGHEST BIDDER WINS
    /// @dev Demo: "Highest bidder wins the auction" -> "Winner receives the pool funds"
    function settleCycle() external onlyActiveGroup nonReentrant {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];

        if (cycle.status != AuctionSaveTypes.CycleStatus.READY_TO_SETTLE) revert NotReadyToSettle();

        // Find HIGHEST BIDDER among eligible members
        address winner = address(0);
        uint256 highestBid = 0;

        for (uint256 i = 0; i < memberList.length; i++) {
            address member = memberList[i];
            AuctionSaveTypes.Member storage m = members[member];
            AuctionSaveTypes.Contribution storage contrib = contributions[currentCycle][member];

            // Eligible: joined, not defaulted, not already won, paid, revealed
            if (m.joined && !m.defaulted && !m.hasWon && contrib.paid && contrib.revealed) {
                if (contrib.revealedBid > highestBid) {
                    highestBid = contrib.revealedBid;
                    winner = member;
                }
            }
        }

        require(winner != address(0), "No eligible winner");

        // Mark winner
        members[winner].hasWon = true;
        cycle.winner = winner;
        cycle.winningBid = highestBid;

        // Calculate payout: pool minus dev fee
        // The winning bid represents how much winner is willing to "sacrifice"
        // In this implementation, winner gets full pool minus dev fee
        // (bid is just for priority/auction mechanism)
        uint256 pool = cycle.totalContributions;
        uint256 devFee = (pool * AuctionSaveTypes.DEV_FEE_BPS) / AuctionSaveTypes.BPS;
        uint256 payout = pool - devFee;

        devFeeBalance += devFee;

        // Transfer to winner
        token.safeTransfer(winner, payout);

        cycle.status = AuctionSaveTypes.CycleStatus.SETTLED;
        emit AuctionSettled(currentCycle, winner, highestBid, payout);

        // Advance to next cycle or complete
        if (currentCycle >= totalCycles) {
            groupStatus = AuctionSaveTypes.GroupStatus.COMPLETED;
            emit GroupCompleted();
        } else {
            currentCycle++;
            uint256 nextStart = cycle.startTime + cycleDuration;
            if (nextStart < block.timestamp) {
                nextStart = block.timestamp;
            }
            _initCycle(currentCycle, nextStart);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FINAL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw security deposit after group completes (for non-defaulted members)
    function withdrawSecurity() external onlyMember nonReentrant {
        if (groupStatus != AuctionSaveTypes.GroupStatus.COMPLETED) revert GroupNotCompleted();

        AuctionSaveTypes.Member storage m = members[msg.sender];
        if (m.securityDeposit == 0) revert NothingToRefund();

        uint256 refund = m.securityDeposit;
        m.securityDeposit = 0;

        token.safeTransfer(msg.sender, refund);
        emit SecurityRefunded(msg.sender, refund);
    }

    /// @notice Distribute penalty escrow to honest members (anyone can call after completion)
    function distributePenaltyEscrow() external nonReentrant {
        if (groupStatus != AuctionSaveTypes.GroupStatus.COMPLETED) revert GroupNotCompleted();
        if (penaltyEscrow == 0) return;

        uint256 honestCount = 0;
        for (uint256 i = 0; i < memberList.length; i++) {
            if (!members[memberList[i]].defaulted) {
                honestCount++;
            }
        }

        if (honestCount == 0) return;

        uint256 sharePerMember = penaltyEscrow / honestCount;
        uint256 distributed = 0;

        for (uint256 i = 0; i < memberList.length; i++) {
            address member = memberList[i];
            if (!members[member].defaulted) {
                token.safeTransfer(member, sharePerMember);
                distributed += sharePerMember;
                emit PenaltyDistributed(member, sharePerMember);
            }
        }

        // Handle dust (remainder goes to last honest member or stays)
        penaltyEscrow -= distributed;
    }

    /*//////////////////////////////////////////////////////////////
                            DEV FEE WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw accumulated developer fees
    function withdrawDevFee() external nonReentrant {
        if (msg.sender != developer) revert NotDeveloper();
        if (devFeeBalance == 0) revert NoFeesToWithdraw();

        uint256 amount = devFeeBalance;
        devFeeBalance = 0;

        token.safeTransfer(developer, amount);
        emit DevFeeWithdrawn(developer, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get count of eligible (non-defaulted) members
    function _getEligibleCount() internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < memberList.length; i++) {
            if (!members[memberList[i]].defaulted) {
                count++;
            }
        }
        return count;
    }

    /// @notice Get all members
    function getMembers() external view returns (address[] memory) {
        return memberList;
    }

    /// @notice Get member count
    function getMemberCount() external view returns (uint256) {
        return memberList.length;
    }

    /// @notice Get cycle info
    function getCycleInfo(uint256 cycleNum)
        external
        view
        returns (
            AuctionSaveTypes.CycleStatus status,
            uint256 startTime,
            uint256 payDeadline,
            uint256 commitDeadline,
            uint256 revealDeadline,
            uint256 totalContributions,
            uint256 contributorCount,
            address winner,
            uint256 winningBid
        )
    {
        AuctionSaveTypes.Cycle storage c = cycles[cycleNum];
        return (
            c.status,
            c.startTime,
            c.payDeadline,
            c.commitDeadline,
            c.revealDeadline,
            c.totalContributions,
            c.contributorCount,
            c.winner,
            c.winningBid
        );
    }

    /// @notice Check if member has paid for a cycle
    function hasPaid(uint256 cycleNum, address member) external view returns (bool) {
        return contributions[cycleNum][member].paid;
    }

    /// @notice Check if member has committed for a cycle
    function hasCommitted(uint256 cycleNum, address member) external view returns (bool) {
        return contributions[cycleNum][member].commitment != bytes32(0);
    }

    /// @notice Check if member has revealed for a cycle
    function hasRevealed(uint256 cycleNum, address member) external view returns (bool) {
        return contributions[cycleNum][member].revealed;
    }

    /// @notice Get revealed bid for a member in a cycle
    function getRevealedBid(uint256 cycleNum, address member) external view returns (uint256) {
        return contributions[cycleNum][member].revealedBid;
    }
}
