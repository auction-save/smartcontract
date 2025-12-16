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
    event AuctionSettled(
        uint256 indexed cycle, address indexed winner, uint256 winningBid, uint256 payout, uint256 discountDistributed
    );
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
    error NoCommitment();
    error PayDeadlineNotPassed();
    error InvalidCommitment();

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
        require(_token != address(0), "Invalid token");
        require(_developer != address(0), "Invalid developer");
        require(_groupSize >= 2, "Group too small");
        require(_contributionAmount > 0, "Invalid contribution");
        require(_totalCycles > 0, "Invalid cycles");
        require(_cycleDuration > 0, "Invalid duration");
        require(_payWindow > 0 && _commitWindow > 0 && _revealWindow > 0, "Invalid windows");
        require(_payWindow + _commitWindow + _revealWindow <= _cycleDuration, "Windows exceed cycle duration");
        require(_totalCycles <= _groupSize, "totalCycles cannot exceed groupSize");

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
        if (block.timestamp <= cycle.payDeadline) revert PayDeadlineNotPassed();

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

    /// @dev Internal function to process defaults (used by auto-advance in settleCycle)
    function _processDefaultsInternal() internal {
        for (uint256 i = 0; i < memberList.length; i++) {
            address member = memberList[i];
            AuctionSaveTypes.Member storage m = members[member];

            if (m.joined && !m.defaulted && !contributions[currentCycle][member].paid) {
                _penalizeMember(member);
            }
        }
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
        if (commitment == bytes32(0)) revert InvalidCommitment();

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
        if (!contrib.paid) revert NotPaid(); // Defense-in-depth
        if (contrib.commitment == bytes32(0)) revert NoCommitment();
        if (contrib.revealed) revert AlreadyRevealed();

        // Verify commitment - MUST include bidder, cycle, contract, chainid to prevent commitment theft
        bytes32 expectedCommitment = _computeCommitment(bidAmount, salt, msg.sender, currentCycle);
        if (contrib.commitment != expectedCommitment) revert InvalidReveal();

        // Bid cannot exceed pool total contributions (sanity check)
        uint256 maxBid = cycle.totalContributions;
        if (bidAmount > maxBid) revert BidTooHigh();

        contrib.revealedBid = bidAmount;
        contrib.revealed = true;
        cycle.revealCount++;

        emit BidRevealed(currentCycle, msg.sender, bidAmount);
    }

    /// @dev Compute commitment hash bound to bidder, cycle, contract, and chainid
    /// @notice This prevents commitment theft where attacker copies commitment from mempool
    function _computeCommitment(uint256 bidAmount, bytes32 salt, address bidder, uint256 cycleNum)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(bidAmount, salt, bidder, cycleNum, address(this), block.chainid));
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
    /// @dev Liveness guarantee: auto-advances phases if deadlines passed, fallback to deterministic selection
    function settleCycle() external onlyActiveGroup nonReentrant {
        AuctionSaveTypes.Cycle storage cycle = cycles[currentCycle];

        // Auto-advance phases if deadlines have passed (liveness guarantee - single "poke" function)
        if (cycle.status == AuctionSaveTypes.CycleStatus.COLLECTING && block.timestamp > cycle.payDeadline) {
            _processDefaultsInternal();
            cycle.status = AuctionSaveTypes.CycleStatus.COMMITTING;
        }
        if (cycle.status == AuctionSaveTypes.CycleStatus.COMMITTING && block.timestamp > cycle.commitDeadline) {
            cycle.status = AuctionSaveTypes.CycleStatus.REVEALING;
        }
        if (cycle.status == AuctionSaveTypes.CycleStatus.REVEALING && block.timestamp > cycle.revealDeadline) {
            cycle.status = AuctionSaveTypes.CycleStatus.READY_TO_SETTLE;
        }

        if (cycle.status != AuctionSaveTypes.CycleStatus.READY_TO_SETTLE) revert NotReadyToSettle();

        // Fix #2: Handle deadlock when no eligible winner exists
        if (!_hasEligibleWinnerForCycle(currentCycle)) {
            cycle.status = AuctionSaveTypes.CycleStatus.SETTLED;
            groupStatus = AuctionSaveTypes.GroupStatus.COMPLETED;
            emit GroupCompleted();
            return;
        }

        // Select winner with liveness guarantee (no deadlock)
        (address winner, uint256 winningBid) = _selectWinner(currentCycle);

        // Mark winner
        members[winner].hasWon = true;
        cycle.winner = winner;
        cycle.winningBid = winningBid;

        // Calculate payout with bid as discount (bid has economic meaning)
        // Winner gets: pool - devFee - winningBid
        // winningBid is distributed to other contributors
        uint256 pool = cycle.totalContributions;
        uint256 devFee = (pool * AuctionSaveTypes.DEV_FEE_BPS) / AuctionSaveTypes.BPS;

        uint256 payoutToWinner = 0;
        uint256 discountToDistribute = 0;

        if (pool > devFee) {
            uint256 net = pool - devFee;
            // Clamp bid to net (safety)
            uint256 bidClamped = winningBid > net ? net : winningBid;
            payoutToWinner = net - bidClamped;
            discountToDistribute = bidClamped;
        }

        // Update state BEFORE transfers (CEI pattern)
        devFeeBalance += devFee;
        cycle.status = AuctionSaveTypes.CycleStatus.SETTLED;

        // Transfer to winner
        if (payoutToWinner > 0) {
            token.safeTransfer(winner, payoutToWinner);
        }

        // Distribute bid discount to other contributors
        uint256 distributed = _distributeDiscount(currentCycle, winner, discountToDistribute);

        emit AuctionSettled(currentCycle, winner, winningBid, payoutToWinner, distributed);

        // Advance to next cycle or complete
        _advanceOrComplete(cycle.startTime);
    }

    /// @dev Select winner with liveness guarantee - never deadlocks
    /// @dev Priority: 1) highest revealed bid, 2) deterministic fallback if no reveals
    function _selectWinner(uint256 cycleNum) internal view returns (address winner, uint256 winningBid) {
        // Count eligible winners and find last eligible (for fallback)
        uint256 eligibleCount = 0;
        address lastEligible;

        for (uint256 i = 0; i < memberList.length; i++) {
            address m = memberList[i];
            if (_isEligibleWinner(cycleNum, m)) {
                eligibleCount++;
                lastEligible = m;
            }
        }

        // If only one eligible winner remains -> deterministic (no deadlock)
        if (eligibleCount == 1) {
            return (lastEligible, 0);
        }

        // Find highest revealed bid among eligible winners
        winner = address(0);
        winningBid = 0;

        for (uint256 i = 0; i < memberList.length; i++) {
            address m = memberList[i];
            if (!_isEligibleWinner(cycleNum, m)) continue;

            AuctionSaveTypes.Contribution storage c = contributions[cycleNum][m];
            if (!c.revealed) continue;

            if (c.revealedBid > winningBid) {
                winningBid = c.revealedBid;
                winner = m;
            }
        }

        // Fallback: no reveals -> pick first eligible (deterministic, no deadlock)
        if (winner == address(0)) {
            for (uint256 i = 0; i < memberList.length; i++) {
                address m = memberList[i];
                if (_isEligibleWinner(cycleNum, m)) {
                    return (m, 0);
                }
            }
            // Should never reach here if eligibleCount >= 1
            revert("No eligible winner");
        }

        return (winner, winningBid);
    }

    /// @dev Check if member is eligible to win this cycle
    /// @dev Must have committed (commitment != 0) to be eligible - prevents "free ride" without bidding
    function _isEligibleWinner(uint256 cycleNum, address member) internal view returns (bool) {
        AuctionSaveTypes.Member storage m = members[member];
        AuctionSaveTypes.Contribution storage c = contributions[cycleNum][member];
        return (m.joined && !m.defaulted && !m.hasWon && c.paid && c.commitment != bytes32(0));
    }

    /// @dev Check if any eligible winner exists for this specific cycle
    function _hasEligibleWinnerForCycle(uint256 cycleNum) internal view returns (bool) {
        for (uint256 i = 0; i < memberList.length; i++) {
            if (_isEligibleWinner(cycleNum, memberList[i])) return true;
        }
        return false;
    }

    /// @dev Distribute bid discount to other contributors (bid has economic meaning)
    function _distributeDiscount(uint256 cycleNum, address winner, uint256 discount)
        internal
        returns (uint256 distributed)
    {
        if (discount == 0) return 0;

        // Recipients: paid & non-defaulted & not winner
        uint256 count = 0;
        for (uint256 i = 0; i < memberList.length; i++) {
            address m = memberList[i];
            if (m == winner) continue;
            if (members[m].defaulted) continue;
            if (!contributions[cycleNum][m].paid) continue;
            count++;
        }
        if (count == 0) return 0;

        uint256 share = discount / count;
        uint256 remainder = discount - (share * count);

        for (uint256 i = 0; i < memberList.length; i++) {
            address m = memberList[i];
            if (m == winner) continue;
            if (members[m].defaulted) continue;
            if (!contributions[cycleNum][m].paid) continue;

            uint256 amt = share;
            // Send dust to last recipient
            if (remainder > 0) {
                amt += remainder;
                remainder = 0;
            }

            if (amt > 0) {
                token.safeTransfer(m, amt);
                distributed += amt;
            }
        }

        return distributed;
    }

    /// @dev Advance to next cycle or complete the group
    function _advanceOrComplete(uint256 cycleStartTime) internal {
        // Complete if: reached totalCycles OR no eligible winners remaining
        if (currentCycle >= totalCycles || !_hasEligibleWinnerRemaining()) {
            groupStatus = AuctionSaveTypes.GroupStatus.COMPLETED;
            emit GroupCompleted();
            return;
        }

        currentCycle++;
        uint256 nextStart = cycleStartTime + cycleDuration;
        if (nextStart < block.timestamp) {
            nextStart = block.timestamp;
        }
        _initCycle(currentCycle, nextStart);
    }

    /// @dev Check if any eligible winner remains (for early completion)
    function _hasEligibleWinnerRemaining() internal view returns (bool) {
        for (uint256 i = 0; i < memberList.length; i++) {
            address m = memberList[i];
            if (members[m].joined && !members[m].defaulted && !members[m].hasWon) {
                return true;
            }
        }
        return false;
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
        uint256 escrow = penaltyEscrow;
        if (escrow == 0) return;

        uint256 honestCount = 0;
        for (uint256 i = 0; i < memberList.length; i++) {
            if (!members[memberList[i]].defaulted) {
                honestCount++;
            }
        }

        // If no honest members, send escrow to developer (prevents funds being stuck)
        if (honestCount == 0) {
            penaltyEscrow = 0;
            token.safeTransfer(developer, escrow);
            emit PenaltyDistributed(developer, escrow);
            return;
        }

        uint256 share = escrow / honestCount;
        uint256 remainder = escrow - (share * honestCount);

        // Clear escrow first (CEI pattern)
        penaltyEscrow = 0;

        for (uint256 i = 0; i < memberList.length; i++) {
            address member = memberList[i];
            if (!members[member].defaulted) {
                uint256 amt = share;
                // Send dust to last recipient
                if (remainder > 0) {
                    amt += remainder;
                    remainder = 0;
                }
                token.safeTransfer(member, amt);
                emit PenaltyDistributed(member, amt);
            }
        }
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
