// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/AuctionSaveTypes.sol";

/// @title AuctionSaveGroup - Core protocol for decentralized rotating savings auction
/// @notice Implements commit-reveal auction with 80/20 withheld payout mechanism
/// @dev Constants: GROUP_SIZE=5, COMMITMENT=50 ether, SECURITY_DEPOSIT=50 ether, MAX_BID_BPS=3000
contract AuctionSaveGroup is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable creator;
    address public immutable developer;
    IERC20 public immutable token;

    /*//////////////////////////////////////////////////////////////
                                TIME CONFIG
    //////////////////////////////////////////////////////////////*/

    uint256 public startTime;
    uint256 public cycleDuration;
    bool public immutable demoMode;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    AuctionSaveTypes.GroupStatus public groupStatus;
    uint256 public currentCycle; // 1..GROUP_SIZE
    uint256 public cycleStart;

    uint256 public devFeeBalance;
    uint256 public penaltyEscrow;

    address[] public memberList;
    mapping(address => AuctionSaveTypes.Member) public members;

    // Commit-reveal bidding state
    mapping(uint256 => mapping(address => bytes32)) public bidCommitments;
    mapping(uint256 => mapping(address => uint256)) public revealedBids; // in BPS
    mapping(uint256 => mapping(address => bool)) public hasRevealedBid;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Joined(address indexed user);
    event BidCommitted(uint256 indexed cycle, address indexed user);
    event BidRevealed(uint256 indexed cycle, address indexed user, uint256 bps);
    event CycleResolved(uint256 indexed cycle, address indexed winner);
    event Penalized(address indexed user, uint256 amount);
    event SpeedUp(uint256 newTimestamp);
    event GroupCompleted();
    event SecurityRefunded(address indexed member, uint256 amount);
    event WithheldReleased(address indexed member, uint256 amount);
    event DevFeeWithdrawn(address indexed developer, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error GroupFull();
    error AlreadyJoined();
    error GroupNotFilling();
    error GroupNotActive();
    error NotMember();
    error MemberPenalized();
    error AlreadyWon();
    error BidTooHigh();
    error CycleNotStarted();
    error AlreadyCommitted();
    error NotCommitted();
    error AlreadyRevealed();
    error InvalidReveal();
    error NotDemoMode();
    error NotDeveloper();
    error NoFeesToWithdraw();
    error GroupNotCompleted();
    error NothingToRefund();
    error NothingWithheld();
    error AlreadyPenalized();
    error InvalidCommitment();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyMember() {
        if (!members[msg.sender].joined) revert NotMember();
        _;
    }

    modifier activeGroup() {
        if (memberList.length != AuctionSaveTypes.GROUP_SIZE) revert GroupNotActive();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _creator,
        address _token,
        address _developer,
        uint256 _startTime,
        uint256 _cycleDuration,
        bool _demoMode
    ) {
        require(_token != address(0), "Invalid token");
        require(_developer != address(0), "Invalid developer");

        creator = _creator;
        token = IERC20(_token);
        developer = _developer;
        startTime = _startTime;
        cycleDuration = _cycleDuration;
        demoMode = _demoMode;

        groupStatus = AuctionSaveTypes.GroupStatus.FILLING;
    }

    /*//////////////////////////////////////////////////////////////
                                JOIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Join the group by depositing COMMITMENT + SECURITY_DEPOSIT
    function join() external nonReentrant {
        if (groupStatus != AuctionSaveTypes.GroupStatus.FILLING) revert GroupNotFilling();
        if (memberList.length >= AuctionSaveTypes.GROUP_SIZE) revert GroupFull();
        if (members[msg.sender].joined) revert AlreadyJoined();

        // Total deposit = COMMITMENT + SECURITY_DEPOSIT
        uint256 total = AuctionSaveTypes.COMMITMENT + AuctionSaveTypes.SECURITY_DEPOSIT;
        token.safeTransferFrom(msg.sender, address(this), total);

        members[msg.sender] = AuctionSaveTypes.Member({
            joined: true,
            hasWon: false,
            defaulted: false,
            hasOffset: false,
            securityDeposit: AuctionSaveTypes.SECURITY_DEPOSIT,
            withheld: 0
        });

        memberList.push(msg.sender);
        emit Joined(msg.sender);

        // Activate when full
        if (memberList.length == AuctionSaveTypes.GROUP_SIZE) {
            groupStatus = AuctionSaveTypes.GroupStatus.ACTIVE;
            currentCycle = 1;
            cycleStart = startTime;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        BIDDING (commit-reveal)
    //////////////////////////////////////////////////////////////*/

    /// @notice Commit a sealed bid
    /// @param commitment keccak256(abi.encode(bps, salt, msg.sender, currentCycle, address(this), block.chainid))
    function commitBid(bytes32 commitment) external onlyMember activeGroup {
        AuctionSaveTypes.Member storage m = members[msg.sender];
        if (m.defaulted) revert MemberPenalized();
        if (m.hasWon) revert AlreadyWon();
        if (bidCommitments[currentCycle][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        if (commitment == bytes32(0)) revert InvalidCommitment();

        bidCommitments[currentCycle][msg.sender] = commitment;
        emit BidCommitted(currentCycle, msg.sender);
    }

    /// @notice Reveal the bid (bps format, max 30%)
    /// @param bps Bid in basis points (max 3000 = 30%)
    /// @param salt Salt used in commitment
    function revealBid(uint256 bps, bytes32 salt) external onlyMember activeGroup {
        AuctionSaveTypes.Member storage m = members[msg.sender];
        if (m.defaulted) revert MemberPenalized();
        if (m.hasWon) revert AlreadyWon();
        if (bidCommitments[currentCycle][msg.sender] == bytes32(0)) revert NotCommitted();
        if (hasRevealedBid[currentCycle][msg.sender]) revert AlreadyRevealed();
        if (bps > AuctionSaveTypes.MAX_BID_BPS) revert BidTooHigh();

        // Verify commitment (security improvement)
        bytes32 expected = keccak256(abi.encode(bps, salt, msg.sender, currentCycle, address(this), block.chainid));
        if (bidCommitments[currentCycle][msg.sender] != expected) revert InvalidReveal();

        revealedBids[currentCycle][msg.sender] = bps;
        hasRevealedBid[currentCycle][msg.sender] = true;

        emit BidRevealed(currentCycle, msg.sender, bps);
    }

    /*//////////////////////////////////////////////////////////////
                        CYCLE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Resolve the current cycle and select winner
    function resolveCycle() external activeGroup nonReentrant {
        if (block.timestamp < cycleStart) revert CycleNotStarted();

        // Find highest bidder
        address winner;
        uint256 highest;

        for (uint256 i = 0; i < memberList.length; i++) {
            address u = memberList[i];
            AuctionSaveTypes.Member memory m = members[u];
            if (m.defaulted || m.hasWon) continue;

            uint256 b = revealedBids[currentCycle][u];
            if (b > highest) {
                highest = b;
                winner = u;
            }
        }

        // Fallback: pick first eligible if no bids
        if (winner == address(0)) {
            for (uint256 i = 0; i < memberList.length; i++) {
                address u = memberList[i];
                AuctionSaveTypes.Member memory m = members[u];
                if (!m.defaulted && !m.hasWon) {
                    winner = u;
                    break;
                }
            }
        }

        // If still no winner, complete early
        if (winner == address(0)) {
            groupStatus = AuctionSaveTypes.GroupStatus.COMPLETED;
            emit GroupCompleted();
            return;
        }

        _executeWinner(winner);
    }

    /// @notice Execute winner payout with 80/20 split
    function _executeWinner(address winner) internal {
        AuctionSaveTypes.Member storage m = members[winner];
        uint256 winnerBps = revealedBids[currentCycle][winner];

        /* ---------- BIDDING PAYMENT ---------- */
        uint256 bidAmount = (AuctionSaveTypes.COMMITMENT * winnerBps) / AuctionSaveTypes.BPS;
        if (bidAmount > 0) {
            // Winner pays bid amount
            token.safeTransferFrom(winner, address(this), bidAmount);

            // Dev fee from bid
            uint256 fee = (bidAmount * AuctionSaveTypes.DEV_FEE_BPS) / AuctionSaveTypes.BPS;
            devFeeBalance += fee;

            // Distribute to others
            uint256 distributable = bidAmount - fee;
            uint256 eligibleCount = 0;
            for (uint256 i = 0; i < memberList.length; i++) {
                address u = memberList[i];
                if (u != winner && !members[u].defaulted) {
                    eligibleCount++;
                }
            }

            if (eligibleCount > 0) {
                uint256 share = distributable / eligibleCount;
                for (uint256 i = 0; i < memberList.length; i++) {
                    address u = memberList[i];
                    if (u != winner && !members[u].defaulted) {
                        token.safeTransfer(u, share);
                    }
                }
            }
        }

        /* ---------- POOL PAYMENT (80/20 split) ---------- */
        // Note: Pool per cycle = total COMMITMENT collected at join / GROUP_SIZE cycles
        // This ensures contract has enough funds for all cycles
        uint256 totalPool = AuctionSaveTypes.COMMITMENT; // Per-cycle pool
        uint256 eighty = (totalPool * 80) / 100;
        uint256 twenty = totalPool - eighty;

        uint256 fee80 = (eighty * AuctionSaveTypes.DEV_FEE_BPS) / AuctionSaveTypes.BPS;
        uint256 fee20 = (twenty * AuctionSaveTypes.DEV_FEE_BPS) / AuctionSaveTypes.BPS;

        devFeeBalance += (fee80 + fee20);

        // Transfer 80% to winner
        token.safeTransfer(winner, eighty - fee80);

        // Store 20% as withheld
        m.withheld += (twenty - fee20);
        m.hasWon = true;
        m.hasOffset = true;

        emit CycleResolved(currentCycle, winner);

        _nextCycle();
    }

    function _nextCycle() internal {
        currentCycle++;
        if (currentCycle <= AuctionSaveTypes.GROUP_SIZE) {
            cycleStart += cycleDuration;
        } else {
            groupStatus = AuctionSaveTypes.GroupStatus.COMPLETED;
            emit GroupCompleted();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PENALTY
    //////////////////////////////////////////////////////////////*/

    /// @notice Penalize a member (security + withheld forfeited)
    function penalize(address user) external {
        AuctionSaveTypes.Member storage m = members[user];
        if (m.defaulted) revert AlreadyPenalized();

        m.defaulted = true;
        uint256 penalty = AuctionSaveTypes.SECURITY_DEPOSIT + m.withheld;
        m.securityDeposit = 0;
        m.withheld = 0;
        penaltyEscrow += penalty;

        emit Penalized(user, penalty);
    }

    /*//////////////////////////////////////////////////////////////
                        DEMO SPEED CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Speed up cycle for demo mode
    function speedUpCycle() external {
        if (!demoMode) revert NotDemoMode();
        cycleStart = block.timestamp;
        emit SpeedUp(cycleStart);
    }

    /*//////////////////////////////////////////////////////////////
                        FINAL SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw security deposit after group completes
    function withdrawSecurity() external onlyMember nonReentrant {
        if (groupStatus != AuctionSaveTypes.GroupStatus.COMPLETED) revert GroupNotCompleted();

        AuctionSaveTypes.Member storage m = members[msg.sender];
        if (m.securityDeposit == 0) revert NothingToRefund();

        uint256 refund = m.securityDeposit;
        m.securityDeposit = 0;

        token.safeTransfer(msg.sender, refund);
        emit SecurityRefunded(msg.sender, refund);
    }

    /// @notice Withdraw withheld 20% after group completes
    function withdrawWithheld() external onlyMember nonReentrant {
        if (groupStatus != AuctionSaveTypes.GroupStatus.COMPLETED) revert GroupNotCompleted();

        AuctionSaveTypes.Member storage m = members[msg.sender];
        if (m.withheld == 0) revert NothingWithheld();

        uint256 amount = m.withheld;
        m.withheld = 0;

        token.safeTransfer(msg.sender, amount);
        emit WithheldReleased(msg.sender, amount);
    }

    /// @notice Withdraw developer fees
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

    function getMembers() external view returns (address[] memory) {
        return memberList;
    }

    function getMemberCount() external view returns (uint256) {
        return memberList.length;
    }
}
