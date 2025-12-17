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
│  - Cycle 1 pool funding (5 × 50 USDT) = 250 USDT                   │
│  - Security (5 × 50 USDT)  = 250 USDT (returned at end)            │
│                                                                     │
│  Status: ACTIVE, Cycle 1 starts                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     PHASE 2: CYCLE 1 - BIDDING                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Pool per cycle = 250 USDT (GROUP_SIZE × COMMITMENT)                │
│  Funding rule: Every cycle, each member must pay 50 USDT via         │
│  payCommitment() before resolveCycle().                              │
│  (Cycle 1 commitment is included in join deposit.)                   │
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
│     Pool = 250 USDT                                                 │
│     80% = 200 USDT                                                  │
│     20% = 50 USDT                                                   │
│                                                                     │
│     Dev fee 80% = 200 × 1% = 2.0 USDT                               │
│     Dev fee 20% = 50 × 1% = 0.5 USDT                                │
│                                                                     │
│     Next cycle payment (commitment offset): 50 USDT                 │
│     - Deducted from winner's 80% payout to prepay next cycle        │
│     - Not applied for last cycle winner                             │
│                                                                     │
│     Charlie receives immediately: 200 - 2.0 - 50 = 148.0 USDT        │
│     Charlie withheld: 50 - 0.5 = 49.5 USDT (claimed after completion)│
│                                                                     │
│  CYCLE 1 RESULT:                                                    │
│  - Charlie: +148.0 USDT (immediate) + 49.5 USDT (withheld)          │
│  - Charlie: -15 USDT (bid payment)                                  │
│  - Charlie NET: +133.0 USDT immediate, +49.5 USDT later             │
│  - Alice, Bob, Dave, Eve: +3.7125 USDT each                         │
│  - Dev: +2.65 USDT (pool fees 2.5 + bid fee 0.15)                   │
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
│  - Each member pays commitment: 50 USDT via payCommitment()         │
│  - Pool = 250 USDT                                                  │
│  - Winner receives 80% = 200 USDT                                   │
│    - Dev fee: 2.0 USDT                                              │
│    - Next cycle payment: 50 USDT (except last winner)               │
│    - Immediate payout: 148.0 USDT (cycles 1-4), 198.0 USDT (cycle 5)│
│  - Winner withheld 20%: 49.5 USDT                                   │
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
│     Each winner → 49.5 USDT                                         │
│                                                                     │
│  3. withdrawDevFee() - Developer claims fees                        │
│     Developer → total = sum(pool fees + bid fees) across cycles      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Economic Summary per Member

Assumption: All members bid 10% (1000 BPS) and win in different cycles.

- **Deposit at join**
  - 100 USDT per member (50 commitment for cycle 1 + 50 security)
- **Per-cycle funding (cycles 2-5)**
  - Each cycle requires each member to pay 50 USDT via payCommitment()
  - After a member wins (cycles 1-4), their next-cycle commitment is prepaid by deducting 50 USDT from their 80% payout
  - Last winner (cycle 5) has no next cycle, so no deduction
- **Winner payout per cycle**
  - Pool per cycle = 250 USDT
  - Winner 80% gross = 200 USDT
  - Dev fee on 80% = 2 USDT
  - Next-cycle payment deduction = 50 USDT (cycles 1-4 only)
  - Immediate payout = 148 USDT (cycles 1-4) or 198 USDT (cycle 5)
  - Withheld 20% after fee = 49.5 USDT (claimable after completion)

**Note**: Bid share is calculated from bid payments distributed to non-winners.

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

- MockUSDT: [0x4540Bfb67da3555ACcC9c0C5DeA6eF74b25F7ffF](https://sepolia-blockscout.lisk.com/address/0x4540Bfb67da3555ACcC9c0C5DeA6eF74b25F7ffF)
- AuctionSaveFactory: [0x47B737a8d63602bF67bA4aA2E2511472d71bc54B](https://sepolia-blockscout.lisk.com/address/0x47B737a8d63602bF67bA4aA2E2511472d71bc54B)
- Demo Pool: [0x175886C47618625e47b579697c131B27D1f44a38](https://sepolia-blockscout.lisk.com/address/0x175886C47618625e47b579697c131B27D1f44a38)

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
