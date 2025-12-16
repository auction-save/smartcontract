# AuctionSave Smart Contract

Decentralized rotating savings auction protocol built on Lisk EVM with **commit-reveal auction mechanism** for fair winner selection.

## Overview

AuctionSave is a traditional rotating savings concept (ROSCA) brought on-chain with:

- **Highest bidder wins** via commit-reveal auction
- **80/20 withheld payout** - winner receives 80% immediately, 20% after completion
- **Automatic penalty system** for defaulters (security + withheld forfeited)
- **Demo mode** with `speedUpCycle()` for testing

## Constants

| Constant           | Value    | Description                 |
| ------------------ | -------- | --------------------------- |
| `GROUP_SIZE`       | 5        | Number of members per group |
| `COMMITMENT`       | 50 ether | Contribution amount         |
| `SECURITY_DEPOSIT` | 50 ether | Security deposit            |
| `MAX_BID_BPS`      | 3000     | Maximum bid (30%)           |
| `DEV_FEE_BPS`      | 100      | Developer fee (1%)          |

## Architecture

```
src/
├── AuctionSaveFactory.sol      # Factory to deploy pools
├── AuctionSaveGroup.sol        # Core protocol logic per pool
├── MockUSDT.sol                # Test token with faucet
└── libraries/
    └── AuctionSaveTypes.sol    # Shared structs, enums, constants

test/
├── AuctionSaveFactory.t.sol    # Factory tests
├── AuctionSaveGroup.t.sol      # Group tests
└── mocks/
    └── MockERC20.sol           # Test token

script/
└── DeployAuctionSave.s.sol     # Deployment scripts
```

---

## User Flow with Concrete Values

### Scenario: 5 Members (Alice, Bob, Charlie, Dave, Eve)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PHASE 1: JOIN                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Each member deposits: COMMITMENT + SECURITY = 50 + 50 = 100 USDT   │
│                                                                     │
│  Alice  → deposit 100 USDT → Contract                               │
│  Bob    → deposit 100 USDT → Contract                               │
│  Charlie→ deposit 100 USDT → Contract                               │
│  Dave   → deposit 100 USDT → Contract                               │
│  Eve    → deposit 100 USDT → Contract                               │
│                                                                     │
│  Total in Contract: 500 USDT                                        │
│  - Pool (5 × 50 USDT)      = 250 USDT (for 5 cycles)               │
│  - Security (5 × 50 USDT)  = 250 USDT (returned at end)            │
│                                                                     │
│  Status: ACTIVE, Cycle 1 starts                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     PHASE 2: CYCLE 1 - BIDDING                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Pool per cycle = 50 USDT (COMMITMENT)                              │
│                                                                     │
│  COMMIT PHASE:                                                      │
│  Alice   → commitBid(hash(1000 BPS, salt))  // 10%                  │
│  Bob     → commitBid(hash(2000 BPS, salt))  // 20%                  │
│  Charlie → commitBid(hash(3000 BPS, salt))  // 30% (MAX)            │
│  Dave    → commitBid(hash(500 BPS, salt))   // 5%                   │
│  Eve     → doesn't bid                                              │
│                                                                     │
│  REVEAL PHASE:                                                      │
│  Alice   → revealBid(1000, salt)                                    │
│  Bob     → revealBid(2000, salt)                                    │
│  Charlie → revealBid(3000, salt)  ← HIGHEST!                        │
│  Dave    → revealBid(500, salt)                                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   PHASE 3: CYCLE 1 - SETTLEMENT                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  WINNER: Charlie (highest bid 3000 BPS = 30%)                       │
│                                                                     │
│  1. BIDDING PAYMENT (Charlie pays bid amount):                      │
│     bidAmount = 50 USDT × 30% = 15 USDT                             │
│     Charlie → transfer 15 USDT → Contract                           │
│                                                                     │
│     Dev fee = 15 × 1% = 0.15 USDT                                   │
│     Distributable = 15 - 0.15 = 14.85 USDT                          │
│     Share per member = 14.85 / 4 = 3.7125 USDT                      │
│                                                                     │
│     Alice, Bob, Dave, Eve each receive 3.7125 USDT                  │
│                                                                     │
│  2. POOL PAYMENT (80/20 split):                                     │
│     Pool = 50 USDT                                                  │
│     80% = 40 USDT                                                   │
│     20% = 10 USDT                                                   │
│                                                                     │
│     Dev fee 80% = 40 × 1% = 0.4 USDT                                │
│     Dev fee 20% = 10 × 1% = 0.1 USDT                                │
│                                                                     │
│     Charlie receives immediately: 40 - 0.4 = 39.6 USDT              │
│     Charlie withheld: 10 - 0.1 = 9.9 USDT (claimed after completion)│
│                                                                     │
│  CYCLE 1 RESULT:                                                    │
│  - Charlie: +39.6 USDT (immediate) + 9.9 USDT (withheld)            │
│  - Charlie: -15 USDT (bid payment)                                  │
│  - Charlie NET: +34.5 USDT immediate, +9.9 USDT later               │
│  - Alice, Bob, Dave, Eve: +3.7125 USDT each                         │
│  - Dev: +0.65 USDT                                                  │
│                                                                     │
│  Charlie.hasWon = true (cannot win again)                           │
│  Cycle 2 starts                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   PHASE 4: CYCLE 2-5 (REPEAT)                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Cycle 2: Alice, Bob, Dave, Eve can bid (Charlie already won)       │
│  Cycle 3: 3 members remaining can bid                               │
│  Cycle 4: 2 members remaining can bid                               │
│  Cycle 5: 1 member remaining automatically wins                     │
│                                                                     │
│  Each cycle:                                                        │
│  - Pool = 50 USDT                                                   │
│  - Winner receives 80% = 39.6 USDT (after fees)                    │
│  - Winner withheld 20% = 9.9 USDT                                   │
│  - Winner pays bid amount (0-30% of 50 USDT)                        │
│  - Non-winners receive share from bid amount                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   PHASE 5: GROUP COMPLETED                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  After 5 cycles completed:                                          │
│                                                                     │
│  1. withdrawSecurity() - All members claim security deposit         │
│     Alice, Bob, Charlie, Dave, Eve → each 50 USDT                   │
│                                                                     │
│  2. withdrawWithheld() - Winners claim 20% withheld                 │
│     Each winner → 9.9 USDT                                          │
│                                                                     │
│  3. withdrawDevFee() - Developer claims fees                        │
│     Developer → total ~3.25 USDT (5 cycles × 0.65 USDT)             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Economic Summary per Member

Assumption: All members bid 10% (1000 BPS) and win in different cycles

| Member  | Deposit | Bid Payment | Pool 80% | Withheld 20% | Bid Share | Security | NET   |
| ------- | ------- | ----------- | -------- | ------------ | --------- | -------- | ----- |
| Alice   | -100    | -5          | +39.6    | +9.9         | +14.85    | +50      | +9.35 |
| Bob     | -100    | -5          | +39.6    | +9.9         | +14.85    | +50      | +9.35 |
| Charlie | -100    | -5          | +39.6    | +9.9         | +14.85    | +50      | +9.35 |
| Dave    | -100    | -5          | +39.6    | +9.9         | +14.85    | +50      | +9.35 |
| Eve     | -100    | -5          | +39.6    | +9.9         | +14.85    | +50      | +9.35 |

**Note**: Bid share is calculated from total bid payments from all winners distributed to non-winners.

---

## Installation

```bash
forge install
forge build
forge test -vv
```

## Deployment

```bash
# Setup environment
cp .env.example .env
# Edit .env with your PRIVATE_KEY and DEVELOPER_ADDRESS

# Deploy everything (MockUSDT + Factory + Demo Pool)
source .env
forge script script/DeployAuctionSave.s.sol:DeployAuctionSave \
  --sig "runFullDemo()" \
  --rpc-url lisk_sepolia \
  --broadcast \
  -vvvv
```

## Network Configuration

| Network      | Chain ID | RPC URL                          |
| ------------ | -------- | -------------------------------- |
| Lisk Sepolia | 4202     | https://rpc.sepolia-api.lisk.com |
| Lisk Mainnet | 1135     | https://rpc.api.lisk.com         |

## Security Features

| Feature              | Description                                          |
| -------------------- | ---------------------------------------------------- |
| **Commit-Reveal**    | Sealed bids prevent front-running                    |
| **SafeERC20**        | Safe token transfers                                 |
| **ReentrancyGuard**  | Prevents reentrancy attacks                          |
| **Bound Commitment** | Commitment includes bidder, cycle, contract, chainid |

## DEPLOYMENT SUMMARY

- MockUSDT: [0x3E55D7C74c633605ADEccCa68822853Bf3413512](https://sepolia-blockscout.lisk.com/address/0x3E55D7C74c633605ADEccCa68822853Bf3413512)
- AuctionSaveFactory: [0x05b629F81DB435EdAf751d6262ecC1Db551473f3](https://sepolia-blockscout.lisk.com/address/0x05b629F81DB435EdAf751d6262ecC1Db551473f3)
- Demo Pool: [0xe868Cafc0afBeCf1fdbA5bAcadF81A714fD0eF12](https://sepolia-blockscout.lisk.com/address/0xe868Cafc0afBeCf1fdbA5bAcadF81A714fD0eF12)

## Frontend Integration (Quick)

### Network (must match wallet)

- **Chain:** Lisk Sepolia
- **Chain ID:** `4202`
- **RPC:** https://rpc.sepolia-api.lisk.com
- **Explorer:** https://sepolia-blockscout.lisk.com

### What the frontend needs

- **Contract addresses**
  - Use the values in `## DEPLOYMENT SUMMARY`.
- **ABIs** (after `forge build`, use the `abi` field)
  - `out/AuctionSaveFactory.sol/AuctionSaveFactory.json`
  - `out/AuctionSaveGroup.sol/AuctionSaveGroup.json`
  - `out/MockUSDT.sol/MockUSDT.json`

### Frontend environment variables (Next.js)

Create/update `web/.env.local`:

- `NEXT_PUBLIC_CHAIN_ID=4202`
- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=<your_walletconnect_project_id>`
- `NEXT_PUBLIC_MOCK_USDT_ADDRESS=<MockUSDT_address>`
- `NEXT_PUBLIC_FACTORY_ADDRESS=<AuctionSaveFactory_address>`
- `NEXT_PUBLIC_DEMO_POOL_ADDRESS=<AuctionSaveGroup_address>` (optional)

### Checklist

- Restart the frontend dev server after changing `.env.local`.
- Ensure the wallet is connected to chain `4202`.
- Ensure ABI files match the deployed contracts.

## License

MIT
