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

## License

MIT
