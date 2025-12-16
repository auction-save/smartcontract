# AuctionSave Smart Contract

Decentralized rotating savings auction protocol built on Lisk EVM with **pay-per-cycle contributions** and **commit-reveal auction mechanism** for fair winner selection.

## Overview

AuctionSave is a traditional rotating savings concept (ROSCA) brought on-chain with:

- **Highest bidder wins** via commit-reveal auction (no Chainlink VRF needed)
- **Pay-per-cycle** contributions (not prepaid)
- **Automatic penalty system** for defaulters
- **Transparent settlement** with dev fee support
- **Security-first design** using OpenZeppelin's SafeERC20 and ReentrancyGuard
- **Bid has economic meaning** - winner's bid is distributed to other contributors

## Architecture

```
src/
├── AuctionSaveFactory.sol      # Factory to deploy and track pools
├── AuctionSaveGroup.sol        # Core protocol logic per pool
├── MockUSDT.sol                # Test token with faucet for demo
└── libraries/
    └── AuctionSaveTypes.sol    # Shared structs, enums, constants

test/
├── AuctionSaveFactory.t.sol    # Factory tests (17 tests)
├── AuctionSaveGroup.t.sol      # Group tests (66 tests)
└── mocks/
    └── MockERC20.sol           # Test token for unit tests

script/
└── DeployAuctionSave.s.sol     # Deployment scripts
```

## User Flow

### 1. Create Group (Creator)

```
Factory.createGroup(token, groupSize, contribution, securityDeposit, cycles, ...)
```

### 2. Join Group (Members)

- Deposit security deposit
- Group activates when full

### 3. Per Cycle Flow

```
[COLLECTING] → payContribution()
     ↓
[COMMITTING] → commitBid(commitment)
     ↓
[REVEALING]  → revealBid(bidAmount, salt)
     ↓
[READY]      → settleCycle() → Highest bidder wins!
     ↓
Next cycle or COMPLETED
```

### 4. Final Settlement

- Honest members withdraw security deposit
- Penalty escrow distributed to honest members
- Developer withdraws accumulated fees

## Key Features

### Commit-Reveal Auction

Highest bidder wins. Bid amount = discount given to other contributors:

```solidity
// Commit phase - bid is sealed
commitment = keccak256(abi.encode(bidAmount, salt, msg.sender, cycleNum, address(this), block.chainid));
commitBid(commitment);

// Reveal phase - bid is verified
revealBid(bidAmount, salt);

// Settlement - highest bidder wins
// Winner payout = pool - devFee - winningBid
// winningBid is distributed to other contributors as discount
```

### Penalty System

- Members who don't pay by deadline are **automatically defaulted**
- Security deposit forfeited to `penaltyEscrow`
- Distributed to honest members at group completion

### Accounting (Bug-Free)

Unlike naive implementations, this contract:

- Collects contributions **each cycle** (not just at join)
- Tracks pool per cycle accurately
- Never runs out of funds mid-protocol

## Installation

```bash
# Clone and install dependencies
forge install

# Build
forge build

# Test
forge test -vv
```

## Deployment

### Quick Start (Lisk Sepolia Testnet)

```bash
# 1. Setup environment
cp .env.example .env
# Edit .env with your PRIVATE_KEY and DEVELOPER_ADDRESS

# 2. Get test ETH from faucet
# https://sepolia-faucet.lisk.com/

# 3. Deploy everything (MockUSDT + Factory + Demo Pool) - RECOMMENDED
source .env
forge script script/DeployAuctionSave.s.sol:DeployAuctionSave \
  --sig "runFullDemo()" \
  --rpc-url lisk_sepolia \
  --broadcast \
  -vvvv
```

### Other Deployment Options

```bash
# Deploy factory only
forge script script/DeployAuctionSave.s.sol:DeployAuctionSave \
  --rpc-url lisk_sepolia --broadcast

# Deploy with existing token
export TOKEN_ADDRESS=0x...
forge script script/DeployAuctionSave.s.sol:DeployAuctionSave \
  --sig "runWithDemoGroup()" \
  --rpc-url lisk_sepolia --broadcast

# Deploy only MockUSDT token
forge script script/DeployAuctionSave.s.sol:DeployAuctionSave \
  --sig "runDeployToken()" \
  --rpc-url lisk_sepolia --broadcast
```

### Network Configuration

| Network      | Chain ID | RPC URL                          | Explorer                            |
| ------------ | -------- | -------------------------------- | ----------------------------------- |
| Lisk Sepolia | 4202     | https://rpc.sepolia-api.lisk.com | https://sepolia-blockscout.lisk.com |
| Lisk Mainnet | 1135     | https://rpc.api.lisk.com         | https://blockscout.lisk.com         |

### MockUSDT Faucet

The MockUSDT contract includes a built-in faucet:

- **Amount**: 10,000 mUSDT per claim
- **Cooldown**: 1 hour between claims
- **Usage**: Call `faucet()` on the MockUSDT contract

## Configuration

### Group Parameters

| Parameter            | Description              | Example   |
| -------------------- | ------------------------ | --------- |
| `groupSize`          | Number of members        | 5         |
| `contributionAmount` | Amount per cycle         | 100 ether |
| `securityDeposit`    | Collateral to join       | 50 ether  |
| `totalCycles`        | Number of rounds         | 5         |
| `cycleDuration`      | Total cycle length       | 7 days    |
| `payWindow`          | Time to pay contribution | 2 days    |
| `commitWindow`       | Time to commit seed      | 1 day     |
| `revealWindow`       | Time to reveal seed      | 1 day     |

### Fees

- **Developer fee**: 1% of pool (configurable in `AuctionSaveTypes.sol`)

## Security Considerations

✅ **ReentrancyGuard** on all state-changing functions  
✅ **SafeERC20** for all token transfers  
✅ **Custom errors** for gas-efficient reverts  
✅ **Access control** via modifiers (`onlyMember`, `onlyActiveMember`, etc.)  
✅ **Penalty system** is rule-based (not arbitrary)  
✅ **No admin keys** that can rug users

## Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test test_SettleCycle_Success

# Gas report
forge test --gas-report
```

### Test Coverage

- Join flow (4 tests)
- Contribution flow (4 tests)
- Default/penalty flow (2 tests)
- Commit-reveal flow (4 tests)
- Settlement flow (4 tests)
- Final settlement (3 tests)
- Dev fee (2 tests)
- Accounting verification (2 tests)

## Design Decisions & Simplifications

This implementation is a **demo-optimized** version of the AuctionSave concept. Below are the key design decisions and how they differ from the original design document (`ref/design.md`).

### What We Implemented (Core Features) ✅

| Feature                   | Status | Description                               |
| ------------------------- | ------ | ----------------------------------------- |
| Two-Contract Architecture | ✅     | `AuctionSaveFactory` + `AuctionSaveGroup` |
| Commit-Reveal Auction     | ✅     | Sealed bids prevent front-running         |
| Pay-Per-Cycle             | ✅     | Members pay each cycle (not prepaid)      |
| Penalty System            | ✅     | Defaulters lose security deposit          |
| Dev Fee (1%)              | ✅     | Transparent fee accounting                |
| Security Deposit          | ✅     | Refundable after group completes          |
| Liveness Guarantee        | ✅     | `settleCycle()` auto-advances phases      |

### Simplifications from Original Design 📝

The original design document proposed a more complex economic model. We simplified it for demo clarity:

#### 1. Single Deposit vs Dual Deposit

**Original**: Join requires two deposits - `commitmentBalance` (50 LSK) + `fixedSecurityDeposit` (50 LSK)

**Implemented**: Single `securityDeposit` only. Contributions are paid per-cycle.

**Rationale**: Simpler UX, same security guarantee. The per-cycle payment model already ensures commitment.

#### 2. Bid Amount vs Bid Percent

**Original**: `submitBid(percent)` where `percent <= 30` (max 30% of contribution)

**Implemented**: `commitBid(bidAmount)` where `bidAmount <= totalContributions`

**Rationale**: Direct token amounts are more intuitive for demo. The economic effect is the same - higher bid = more sacrifice = wins auction.

#### 3. No Withheld 20% Payout

**Original**: Winner receives 80% immediately, 20% withheld until group completion

**Implemented**: Winner receives full payout (minus bid discount) immediately

**Rationale**: Simplifies accounting and improves demo flow. Withheld balance adds complexity without visible benefit in short demos.

#### 4. No Commitment Offset

**Original**: Winner gets `hasCommitmentOffset = true` to skip next cycle's contribution

**Implemented**: No offset - winner still pays contribution next cycle

**Rationale**: Edge case that rarely occurs in demo. Adds state complexity.

#### 5. Deterministic Tie-Break vs Pseudo-Random

**Original**: Tie → pseudo-random draw (block-based)

**Implemented**: Tie → first eligible member in list wins (deterministic)

**Rationale**: Deterministic is easier to test and reason about. In practice, ties are rare with real bids.

#### 6. Demo Mode Time Acceleration

**Original**: Special `advanceCycleForDemo()` function

**Implemented**: Configurable `cycleDuration`, `payWindow`, `commitWindow`, `revealWindow`

**Rationale**: Same effect achieved by setting short durations (e.g., 5 minutes per cycle). No special demo function needed.

### Economic Model Summary

```
┌─────────────────────────────────────────────────────────────┐
│                    CYCLE SETTLEMENT                         │
├─────────────────────────────────────────────────────────────┤
│  Pool = sum of all contributions this cycle                 │
│  DevFee = 1% of Pool                                        │
│  WinnerPayout = Pool - DevFee - WinningBid                  │
│  BidDiscount = WinningBid (distributed to other members)    │
├─────────────────────────────────────────────────────────────┤
│  Example (5 members, 100 USDT contribution each):           │
│  - Pool = 500 USDT                                          │
│  - DevFee = 5 USDT                                          │
│  - Winner bids 50 USDT                                      │
│  - Winner receives: 500 - 5 - 50 = 445 USDT                 │
│  - Other 4 members receive: 50 / 4 = 12.5 USDT each         │
└─────────────────────────────────────────────────────────────┘
```

### Why These Simplifications?

1. **Demo Clarity**: Judges can understand the flow in 5 minutes
2. **Reduced Attack Surface**: Fewer state variables = fewer bugs
3. **Gas Efficiency**: Simpler logic = lower gas costs
4. **Test Coverage**: 83 tests covering all core flows
5. **Same Core Value Proposition**: Commit-reveal auction + penalty system intact

### Future Enhancements (Post-Hackathon)

If deploying to production, consider adding:

- [ ] Bid percent with `maxBidPercent` cap
- [ ] Withheld 20% payout mechanism
- [ ] Commitment offset for winners
- [ ] Pseudo-random tie-breaking (using blockhash)
- [ ] Multi-token support per group
- [ ] Governance for parameter updates

## License

MIT
