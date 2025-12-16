# AuctionSave Smart Contract

Decentralized rotating savings auction protocol built on Lisk EVM with **pay-per-cycle contributions** and **commit-reveal auction mechanism** for fair winner selection.

## Overview

AuctionSave is a traditional rotating savings concept (ROSCA) brought on-chain with:

- **Fair randomness** via commit-reveal mechanism (no Chainlink VRF needed)
- **Pay-per-cycle** contributions (not prepaid)
- **Automatic penalty system** for defaulters
- **Transparent settlement** with dev fee support
- **Security-first design** using OpenZeppelin's SafeERC20 and ReentrancyGuard

## Architecture

```
src/
├── AuctionSaveFactory.sol      # Factory to deploy and track pools
├── AuctionSaveGroup.sol        # Core protocol logic per pool
└── libraries/
    └── AuctionSaveTypes.sol    # Shared structs, enums, constants

test/
├── AuctionSaveGroup.t.sol      # Comprehensive test suite (26 tests)
└── mocks/
    └── MockERC20.sol      # Test token

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
[COMMITTING] → commitSeed(hash)
     ↓
[REVEALING]  → revealSeed(seed, salt)
     ↓
[READY]      → settleCycle() → Winner gets pool!
     ↓
Next cycle or COMPLETED
```

### 4. Final Settlement

- Honest members withdraw security deposit
- Penalty escrow distributed to honest members
- Developer withdraws accumulated fees

## Key Features

### Commit-Reveal Randomness

No external oracle needed. Members contribute entropy:

```solidity
// Commit phase
commitment = keccak256(abi.encodePacked(seed, salt));
commitSeed(commitment);

// Reveal phase
revealSeed(seed, salt);

// Winner selected from combined entropy
finalEntropy = keccak256(abi.encodePacked(finalEntropy, seed));
winnerIndex = uint256(finalEntropy) % eligibleCount;
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

```bash
# Set environment variables
export PRIVATE_KEY=<your_private_key>
export DEVELOPER_ADDRESS=<fee_recipient>
export TOKEN_ADDRESS=<erc20_token>

# Deploy factory only
forge script script/DeployArisan.s.sol:DeployArisan --rpc-url <rpc_url> --broadcast

# Deploy with demo group
forge script script/DeployArisan.s.sol:DeployArisan --sig "runWithDemoGroup()" --rpc-url <rpc_url> --broadcast

# Deploy demo mode (short time windows)
forge script script/DeployArisan.s.sol:DeployArisan --sig "runDemoMode()" --rpc-url <rpc_url> --broadcast
```

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
